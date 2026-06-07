// Conversion between jovian's `.py + # %%` format (plus sidecar JSON for
// outputs) and Jupyter's `.ipynb` (nbformat v4).
//
// Design choice: import writes both the .py source AND the sidecar JSON
// so the imported notebook opens with its outputs already cached — the
// user gets the familiar "Out[N]" prompts inline without having to
// re-execute. Export reads both and bundles them into nbformat.
//
// Markdown cells: jovian's .py format uses `# `-prefixed source after a
// `# %% [markdown]` header (jupytext-compatible). Round-tripping
// adds/strips that prefix.

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::path::Path;

use crate::notebook::{self, CellType, OutputStoreFile};

/// Pure in-memory decode of nbformat JSON into a `(py_source, sidecar)`
/// pair. The py_source is what the Lua side renders into the buffer;
/// the sidecar is what `output_render` reads to draw outputs. Used by
/// both `import_ipynb` (file→file) and the native `*.ipynb` autocmd
/// integration on the Lua side.
pub fn decode(ipynb_json: &str) -> Result<(String, OutputStoreFile)> {
    let nb: Value = serde_json::from_str(ipynb_json).context("parse ipynb JSON")?;

    let cells = nb
        .get("cells")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("ipynb has no .cells array"))?;

    let mut py_source = String::new();
    let mut sidecar = OutputStoreFile::default();

    for (idx, cell) in cells.iter().enumerate() {
        let cell_type = cell
            .get("cell_type")
            .and_then(|v| v.as_str())
            .unwrap_or("code");
        // Jupyter writes ids since nbformat 4.5; older notebooks may not.
        // Fall back to a stable index-based id so the sidecar lookup
        // still works deterministically.
        let id = cell
            .get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| format!("imported{idx}"));
        let tags: Vec<String> = cell
            .get("metadata")
            .and_then(|m| m.get("tags"))
            .and_then(|t| t.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|t| t.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();

        // Header
        let mut header = String::from("# %%");
        if cell_type == "markdown" {
            header.push_str(" [markdown]");
        } else if cell_type == "raw" {
            // We don't render raw cells specially, but preserve the tag so
            // round-trips don't downgrade them silently.
            header.push_str(" [raw]");
        }
        header.push_str(&format!(" id=\"{id}\""));
        if !tags.is_empty() {
            let inner = tags
                .iter()
                .map(|t| format!("\"{}\"", t.replace('"', "\\\"")))
                .collect::<Vec<_>>()
                .join(",");
            header.push_str(&format!(" tags=[{inner}]"));
        }
        py_source.push_str(&header);
        py_source.push('\n');

        // Source: nbformat stores it as either a string or a list of
        // strings (each typically ending in `\n` except possibly the last).
        let source_text = cell_source_to_string(cell.get("source"));
        match cell_type {
            "markdown" | "raw" => {
                for line in source_text.split('\n') {
                    if line.is_empty() {
                        py_source.push_str("#\n");
                    } else {
                        py_source.push_str("# ");
                        py_source.push_str(line);
                        py_source.push('\n');
                    }
                }
            }
            _ => {
                py_source.push_str(&source_text);
                if !source_text.ends_with('\n') {
                    py_source.push('\n');
                }
            }
        }
        py_source.push('\n');

        // Outputs go into the sidecar (only for code cells).
        if cell_type == "code" {
            let execution_count = cell.get("execution_count").and_then(|v| v.as_u64());
            let outputs: Vec<Value> = cell
                .get("outputs")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            if execution_count.is_some() || !outputs.is_empty() {
                sidecar.cells.insert(
                    id.clone(),
                    notebook::CellOutputs {
                        execution_count,
                        outputs,
                    },
                );
            }
        }
    }

    Ok((py_source, sidecar))
}

/// Convert a `.ipynb` file at `ipynb_path` into a `.py + sidecar` pair.
/// The `.py` is written next to the source (same basename, `.py` ext)
/// and the sidecar JSON next to *that*. Returns the destination `.py`.
pub fn import_ipynb(ipynb_path: &Path) -> Result<std::path::PathBuf> {
    let raw = std::fs::read_to_string(ipynb_path)
        .with_context(|| format!("read {}", ipynb_path.display()))?;
    let (py_source, sidecar) = decode(&raw)?;

    let stem = ipynb_path
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or_else(|| anyhow!("ipynb path has no stem"))?;
    let dir = ipynb_path.parent().unwrap_or_else(|| Path::new("."));
    let py_path = dir.join(format!("{stem}.py"));
    std::fs::write(&py_path, py_source).with_context(|| format!("write {}", py_path.display()))?;
    notebook::write_sidecar(&py_path, &sidecar)?;
    Ok(py_path)
}

/// Pure in-memory encode: given a `# %%`-style py_source and the
/// current sidecar outputs, return a fully-formed nbformat v4 JSON
/// string. Counterpart to `decode`.
pub fn encode(py_source: &str, outputs: &OutputStoreFile) -> Result<String> {
    let source = notebook::Source::parse(py_source);
    let mut cells = Vec::with_capacity(source.cells.len());
    for cell in &source.cells {
        // Skip the synthetic "scratchpad" preamble unless it has content
        // — it represents leading lines before any `# %%`, which is
        // rare and typically just imports. Keep it when it does have
        // content so we don't drop user code.
        if cell.id == "scratchpad" && cell.source.trim().is_empty() {
            continue;
        }
        let co = outputs.cells.get(&cell.id).cloned().unwrap_or_default();
        let mut metadata = serde_json::Map::new();
        if !cell.tags.is_empty() {
            metadata.insert("tags".to_string(), json!(cell.tags));
        }
        let cell_type_str = cell.cell_type.as_str();
        let source_value = match cell.cell_type {
            CellType::Markdown => json!(strip_markdown_prefix(&cell.source)),
            CellType::Code => json!(cell.source),
        };
        let mut nb_cell = serde_json::Map::new();
        nb_cell.insert("cell_type".to_string(), json!(cell_type_str));
        nb_cell.insert("id".to_string(), json!(cell.id));
        nb_cell.insert("metadata".to_string(), Value::Object(metadata));
        nb_cell.insert("source".to_string(), source_value);
        if cell.cell_type == CellType::Code {
            nb_cell.insert(
                "execution_count".to_string(),
                co.execution_count.map(|n| json!(n)).unwrap_or(Value::Null),
            );
            nb_cell.insert("outputs".to_string(), json!(co.outputs));
        }
        cells.push(Value::Object(nb_cell));
    }

    let nb = json!({
        "metadata": {
            "kernelspec": {
                "display_name": "Python 3",
                "language": "python",
                "name": "python3"
            },
            "language_info": { "name": "python" }
        },
        "nbformat": 4,
        "nbformat_minor": 5,
        "cells": cells
    });
    Ok(serde_json::to_string_pretty(&nb)? + "\n")
}

/// Convert a `.py + sidecar` pair into a `.ipynb` at `out_path`. Reads
/// the current sidecar for outputs.
pub fn export_ipynb(py_path: &Path, out_path: &Path) -> Result<()> {
    let source_text =
        std::fs::read_to_string(py_path).with_context(|| format!("read {}", py_path.display()))?;
    let outputs = notebook::read_sidecar(py_path)?;
    let json = encode(&source_text, &outputs)?;
    std::fs::write(out_path, json).with_context(|| format!("write {}", out_path.display()))?;
    Ok(())
}

fn cell_source_to_string(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|p| p.as_str())
            .collect::<Vec<_>>()
            .join(""),
        _ => String::new(),
    }
}

/// Strip the leading `# ` (or `#` alone for empty lines) that jovian's
/// markdown cells carry in their `.py` representation. The inverse of
/// the prefixing done in `import_ipynb`.
fn strip_markdown_prefix(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for (i, line) in s.split('\n').enumerate() {
        if i > 0 {
            out.push('\n');
        }
        if let Some(rest) = line.strip_prefix("# ") {
            out.push_str(rest);
        } else if line == "#" {
            // Was an empty markdown line written as `#\n`.
        } else {
            out.push_str(line);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    // Build an ipynb document as a serde_json::Value so we don't have to
    // hand-write JSON-with-escapes inside Rust string literals — raw strings
    // and `\n` mixed inside test fixtures gets confusing fast.
    fn make_ipynb(cells: Vec<Value>) -> String {
        let v = json!({
            "nbformat": 4,
            "nbformat_minor": 5,
            "metadata": {},
            "cells": cells,
        });
        serde_json::to_string(&v).unwrap()
    }

    #[test]
    fn export_roundtrips_a_simple_notebook() {
        let tmp = TempDir::new().unwrap();
        let py = tmp.path().join("nb.py");
        let ipynb = tmp.path().join("nb.ipynb");

        std::fs::write(
            &py,
            "# %% id=\"a1\" tags=[\"slow\"]\nprint(1)\n\n# %% [markdown] id=\"m1\"\n# heading\n",
        )
        .unwrap();
        let sidecar_dir = tmp.path().join(".jovian_cache/nb.py");
        std::fs::create_dir_all(&sidecar_dir).unwrap();
        let sidecar = json!({
            "version": 1,
            "cells": {
                "a1": {
                    "execution_count": 1,
                    "outputs": [{"output_type":"stream","name":"stdout","text":"1\n"}]
                }
            }
        });
        std::fs::write(
            sidecar_dir.join("outputs.json"),
            serde_json::to_string(&sidecar).unwrap(),
        )
        .unwrap();

        export_ipynb(&py, &ipynb).unwrap();
        let nb: Value = serde_json::from_str(&std::fs::read_to_string(&ipynb).unwrap()).unwrap();
        assert_eq!(nb["nbformat"], 4);
        assert_eq!(nb["cells"].as_array().unwrap().len(), 2);
        let code = &nb["cells"][0];
        assert_eq!(code["cell_type"], "code");
        assert_eq!(code["id"], "a1");
        assert_eq!(code["metadata"]["tags"], json!(["slow"]));
        assert_eq!(code["execution_count"], 1);
        assert_eq!(code["outputs"][0]["text"], "1\n");
        let md = &nb["cells"][1];
        assert_eq!(md["cell_type"], "markdown");
        // strip_markdown_prefix keeps the trailing newline that the .py
        // source carried; nbformat readers tolerate a trailing \n.
        assert_eq!(md["source"], "heading\n");
    }

    #[test]
    fn import_writes_py_and_sidecar() {
        let tmp = TempDir::new().unwrap();
        let ipynb = tmp.path().join("nb.ipynb");
        let body = make_ipynb(vec![
            json!({
                "cell_type": "code",
                "id": "a1",
                "metadata": { "tags": ["slow"] },
                "source": ["x = 1\n", "y = 2"],
                "execution_count": 3,
                "outputs": [{"output_type":"stream","name":"stdout","text":"hi\n"}]
            }),
            json!({
                "cell_type": "markdown",
                "id": "m1",
                "metadata": {},
                "source": ["# Title\n", "\n", "body"]
            }),
        ]);
        std::fs::write(&ipynb, body).unwrap();
        let py = import_ipynb(&ipynb).unwrap();
        assert_eq!(py, tmp.path().join("nb.py"));
        let py_text = std::fs::read_to_string(&py).unwrap();
        assert!(py_text.contains("# %% id=\"a1\""));
        assert!(py_text.contains("tags=[\"slow\"]"));
        assert!(py_text.contains("x = 1"));
        assert!(py_text.contains("# %% [markdown] id=\"m1\""));
        assert!(py_text.contains("# # Title"));

        let sidecar = notebook::read_sidecar(&py).unwrap();
        let a1 = sidecar.cells.get("a1").unwrap();
        assert_eq!(a1.execution_count, Some(3));
        assert_eq!(a1.outputs[0]["text"], "hi\n");
    }

    #[test]
    fn import_handles_missing_id() {
        let tmp = TempDir::new().unwrap();
        let ipynb = tmp.path().join("nb.ipynb");
        let body = make_ipynb(vec![json!({
            "cell_type": "code",
            "metadata": {},
            "source": ["pass\n"]
        })]);
        std::fs::write(&ipynb, body).unwrap();
        let py = import_ipynb(&ipynb).unwrap();
        let py_text = std::fs::read_to_string(&py).unwrap();
        assert!(py_text.contains("id=\"imported0\""));
    }
}
