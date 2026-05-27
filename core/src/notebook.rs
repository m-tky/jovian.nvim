// jovian's source format: `.py` file with `# %%` cell markers.
//
// Example:
//   # %% id="abc123"
//   print("hello")
//
//   # %% [markdown] id="def456"
//   # Heading
//
// Outputs are NOT stored in the .py file. They live in a sidecar JSON next
// to the file:
//   .jovian_cache/<filename>/outputs.json
//
// The sidecar maps cell_id → { execution_count, outputs[] } using the
// nbformat v4 schema for individual output entries. This keeps the .py
// file source-controllable while preserving full output fidelity (images,
// HTML, errors, etc.) for the inline / preview / pin renderers.

use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CellType {
    Code,
    Markdown,
    Raw,
}

impl CellType {
    pub fn as_str(&self) -> &'static str {
        match self {
            CellType::Code => "code",
            CellType::Markdown => "markdown",
            CellType::Raw => "raw",
        }
    }
    pub fn from_str(s: &str) -> Self {
        match s {
            "markdown" | "md" => CellType::Markdown,
            "raw" => CellType::Raw,
            _ => CellType::Code,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Cell {
    pub id: String,
    pub cell_type: CellType,
    pub source: String,
    /// 0-based line index of the `# %%` header in the buffer.
    pub header_line: usize,
    /// 0-based exclusive line index of the cell's last source line + 1.
    pub end_line: usize,
}

#[derive(Debug, Clone)]
pub struct Source {
    pub path: PathBuf,
    pub cells: Vec<Cell>,
}

// Header line matchers.
//
// Patterns we accept:
//   # %%
//   # %% id="abc"
//   # %% [markdown]
//   # %% [markdown] id="abc"
//   # %% [md] id="abc"
//
// Anything after `# %%` that we don't recognize is preserved as trailing
// header text (for round-tripping arbitrary user comments on the header).
static HEADER_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^#\s*%%\s*(?:\[(?P<kind>[a-zA-Z]+)\])?\s*(?P<rest>.*)$").unwrap());
static ID_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r#"id="(?P<id>[A-Za-z0-9_\-]+)""#).unwrap());

impl Source {
    /// Parse a source buffer (as the user sees it in Neovim) into cells.
    pub fn parse(path: PathBuf, text: &str) -> Self {
        let lines: Vec<&str> = text.split('\n').collect();
        let mut headers: Vec<(usize, CellType, Option<String>)> = Vec::new();
        for (i, line) in lines.iter().enumerate() {
            if let Some(cap) = HEADER_RE.captures(line) {
                let kind = cap
                    .name("kind")
                    .map(|m| CellType::from_str(m.as_str()))
                    .unwrap_or(CellType::Code);
                let id = cap
                    .name("rest")
                    .and_then(|m| ID_RE.captures(m.as_str()))
                    .and_then(|c| c.name("id"))
                    .map(|m| m.as_str().to_string());
                headers.push((i, kind, id));
            }
        }

        let mut cells = Vec::new();
        // If the buffer doesn't open with a `# %%` header, prefix an implicit
        // "scratchpad" cell covering [0, first_header_line) — so leading
        // code at the top of the file is still addressable.
        let first_real = headers.first().map(|h| h.0).unwrap_or(lines.len());
        if first_real > 0 {
            let src = lines[..first_real].join("\n");
            // Trim only the trailing newline that came from `split('\n')`
            // creating an extra empty token; preserve internal blank lines.
            let src = src.trim_end_matches('\n').to_string();
            cells.push(Cell {
                id: "scratchpad".to_string(),
                cell_type: CellType::Code,
                source: src,
                header_line: 0,
                end_line: first_real,
            });
        }

        for (idx, (line, kind, id)) in headers.iter().enumerate() {
            let next_header = headers
                .get(idx + 1)
                .map(|h| h.0)
                .unwrap_or(lines.len());
            let src_start = line + 1;
            let src_end = next_header;
            let src = if src_start < src_end {
                lines[src_start..src_end].join("\n")
            } else {
                String::new()
            };
            cells.push(Cell {
                id: id.clone().unwrap_or_else(generate_cell_id),
                cell_type: *kind,
                source: src,
                header_line: *line,
                end_line: src_end,
            });
        }

        Source { path, cells }
    }

    pub fn read(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self {
                path: path.to_path_buf(),
                cells: vec![Cell {
                    id: "scratchpad".to_string(),
                    cell_type: CellType::Code,
                    source: String::new(),
                    header_line: 0,
                    end_line: 0,
                }],
            });
        }
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("read {}", path.display()))?;
        Ok(Self::parse(path.to_path_buf(), &raw))
    }

    pub fn cell(&self, id: &str) -> Option<&Cell> {
        self.cells.iter().find(|c| c.id == id)
    }
}

pub fn generate_cell_id() -> String {
    // 12-char base62-ish id matching jovian's existing Lua format
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEED: AtomicU64 = AtomicU64::new(0);
    let n = SEED.fetch_add(1, Ordering::Relaxed);
    let u = uuid::Uuid::new_v4();
    let s = u.simple().to_string();
    // Take 11 hex chars + a counter digit to disambiguate inside-process
    let last = std::char::from_digit((n % 36) as u32, 36).unwrap_or('0');
    let mut id: String = s.chars().take(11).collect();
    id.push(last);
    id
}

// ----- Sidecar output store -----

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CellOutputs {
    #[serde(default)]
    pub execution_count: Option<u64>,
    #[serde(default)]
    pub outputs: Vec<Value>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OutputStoreFile {
    #[serde(default = "default_version")]
    pub version: u32,
    #[serde(default)]
    pub cells: HashMap<String, CellOutputs>,
}

fn default_version() -> u32 {
    1
}

/// Resolve the sidecar JSON path for a given source file path.
/// `.../foo.py` → `.../.jovian_cache/foo.py/outputs.json`
pub fn sidecar_path_for(source_path: &Path) -> PathBuf {
    let dir = source_path.parent().unwrap_or_else(|| Path::new("."));
    let fname = source_path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("scratchpad");
    dir.join(".jovian_cache").join(fname).join("outputs.json")
}

pub fn read_sidecar(source_path: &Path) -> Result<OutputStoreFile> {
    let p = sidecar_path_for(source_path);
    if !p.exists() {
        return Ok(OutputStoreFile::default());
    }
    let raw = std::fs::read_to_string(&p)
        .with_context(|| format!("read sidecar {}", p.display()))?;
    if raw.trim().is_empty() {
        return Ok(OutputStoreFile::default());
    }
    let f: OutputStoreFile = serde_json::from_str(&raw)
        .with_context(|| format!("parse sidecar {}", p.display()))?;
    Ok(f)
}

pub fn write_sidecar(source_path: &Path, store: &OutputStoreFile) -> Result<()> {
    let p = sidecar_path_for(source_path);
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("mkdir {}", parent.display()))?;
    }
    let s = serde_json::to_string_pretty(store)?;
    std::fs::write(&p, s + "\n").with_context(|| format!("write {}", p.display()))?;
    Ok(())
}

/// Convenience: load just a single cell's outputs.
pub fn read_cell_outputs(source_path: &Path, cell_id: &str) -> Result<CellOutputs> {
    let store = read_sidecar(source_path)?;
    Ok(store.cells.get(cell_id).cloned().unwrap_or_default())
}

// ----- Mime / output helpers (kept here so all output mutations stay in one place) -----

/// Append a stream output, coalescing with the previous entry if it's the
/// same stream name. Matches jupyter's iopub stream coalescing semantics so
/// the inline renderer doesn't see thousands of tiny "stdout" chunks.
pub fn append_stream(outputs: &mut Vec<Value>, name: &str, text: &str) {
    if let Some(last) = outputs.last_mut() {
        if last.get("output_type").and_then(|v| v.as_str()) == Some("stream")
            && last.get("name").and_then(|v| v.as_str()) == Some(name)
        {
            let prev = last
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            last["text"] = Value::String(prev + text);
            return;
        }
    }
    outputs.push(json!({
        "output_type": "stream",
        "name": name,
        "text": text,
    }));
}

pub fn append_display(outputs: &mut Vec<Value>, data: Value, metadata: Value) {
    outputs.push(json!({
        "output_type": "display_data",
        "data": data,
        "metadata": metadata,
    }));
}

pub fn append_execute_result(
    outputs: &mut Vec<Value>,
    execution_count: u64,
    data: Value,
    metadata: Value,
) {
    outputs.push(json!({
        "output_type": "execute_result",
        "execution_count": execution_count,
        "data": data,
        "metadata": metadata,
    }));
}

pub fn append_error(outputs: &mut Vec<Value>, ename: &str, evalue: &str, traceback: Vec<String>) {
    outputs.push(json!({
        "output_type": "error",
        "ename": ename,
        "evalue": evalue,
        "traceback": traceback,
    }));
}

// Re-export so callers can construct empty maps without depending on serde_json directly
pub fn empty_metadata() -> Value {
    Value::Object(Map::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple_cells() {
        let src = "# %% id=\"a1\"\nprint(1)\n\n# %% id=\"a2\"\nprint(2)\n";
        let s = Source::parse(PathBuf::from("test.py"), src);
        assert_eq!(s.cells.len(), 2);
        assert_eq!(s.cells[0].id, "a1");
        assert!(s.cells[0].source.contains("print(1)"));
        assert_eq!(s.cells[1].id, "a2");
        assert!(s.cells[1].source.contains("print(2)"));
    }

    #[test]
    fn implicit_scratchpad_for_leading_code() {
        let src = "import os\n\n# %% id=\"a1\"\nprint(1)\n";
        let s = Source::parse(PathBuf::from("test.py"), src);
        assert_eq!(s.cells.len(), 2);
        assert_eq!(s.cells[0].id, "scratchpad");
        assert!(s.cells[0].source.starts_with("import os"));
    }

    #[test]
    fn markdown_cell_type() {
        let src = "# %% [markdown] id=\"m1\"\n# heading\n";
        let s = Source::parse(PathBuf::from("test.py"), src);
        assert_eq!(s.cells.len(), 1);
        assert_eq!(s.cells[0].cell_type, CellType::Markdown);
    }

    #[test]
    fn missing_id_gets_generated() {
        let src = "# %%\nprint(1)\n";
        let s = Source::parse(PathBuf::from("test.py"), src);
        assert_eq!(s.cells.len(), 1);
        assert!(!s.cells[0].id.is_empty());
        assert_ne!(s.cells[0].id, "scratchpad");
    }

    #[test]
    fn sidecar_path_layout() {
        let p = sidecar_path_for(Path::new("/work/notes.py"));
        assert_eq!(
            p,
            PathBuf::from("/work/.jovian_cache/notes.py/outputs.json")
        );
    }

    #[test]
    fn append_stream_coalesces() {
        let mut v = Vec::new();
        append_stream(&mut v, "stdout", "hello ");
        append_stream(&mut v, "stdout", "world");
        assert_eq!(v.len(), 1);
        assert_eq!(v[0]["text"], "hello world");
    }

    #[test]
    fn append_stream_splits_on_name_change() {
        let mut v = Vec::new();
        append_stream(&mut v, "stdout", "hi");
        append_stream(&mut v, "stderr", "warn");
        assert_eq!(v.len(), 2);
    }
}
