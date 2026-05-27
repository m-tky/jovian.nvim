// Session = one open `.py` source + its kernel + its cell↔msg_id state.
//
// Outputs live in the sidecar JSON at `.jovian_cache/<filename>/outputs.json`;
// we keep an in-memory copy mirrored to that file and persist eagerly so
// that other Neovim instances or external tools see fresh state.

use anyhow::Result;
use dashmap::DashMap;
use parking_lot::RwLock;
use serde::Serialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock as AsyncRwLock;

use crate::kernel::{Kernel, KernelEvent};
use crate::notebook::{self, CellOutputs, OutputStoreFile, Source};

#[derive(Debug, Clone, Serialize)]
pub struct CellSnapshot {
    pub id: String,
    pub cell_type: String,
    pub source: String,
    pub header_line: usize,
    pub end_line: usize,
    pub execution_count: Option<u64>,
    pub outputs: Vec<Value>,
}

pub struct Session {
    pub id: String,
    pub path: PathBuf,
    pub source: RwLock<Source>,
    pub outputs: RwLock<OutputStoreFile>,
    pub kernel: AsyncRwLock<Option<Kernel>>,
    /// msg_id → cell_id, for routing iopub events back to the originating cell.
    pub msg_to_cell: DashMap<String, String>,
}

impl Session {
    pub fn open(id: String, path: PathBuf) -> Result<Arc<Self>> {
        let source = Source::read(&path)?;
        let outputs = notebook::read_sidecar(&path)?;
        Ok(Arc::new(Self {
            id,
            path,
            source: RwLock::new(source),
            outputs: RwLock::new(outputs),
            kernel: AsyncRwLock::new(None),
            msg_to_cell: DashMap::new(),
        }))
    }

    pub fn snapshot(&self) -> SessionSnapshot {
        let src = self.source.read();
        let outs = self.outputs.read();
        let cells = src
            .cells
            .iter()
            .map(|c| {
                let co = outs.cells.get(&c.id).cloned().unwrap_or_default();
                CellSnapshot {
                    id: c.id.clone(),
                    cell_type: c.cell_type.as_str().to_string(),
                    source: c.source.clone(),
                    header_line: c.header_line,
                    end_line: c.end_line,
                    execution_count: co.execution_count,
                    outputs: co.outputs,
                }
            })
            .collect();
        SessionSnapshot {
            id: self.id.clone(),
            path: self.path.to_string_lossy().to_string(),
            cells,
        }
    }

    /// Re-parse the source buffer text (driven from Neovim) without touching outputs.
    /// Sidecar outputs whose cell_id is gone are kept around — re-adding the cell
    /// later restores them.
    pub fn reparse(&self, text: &str) {
        let mut src = self.source.write();
        *src = Source::parse(self.path.clone(), text);
    }

    pub fn persist_outputs(&self) -> Result<()> {
        let outs = self.outputs.read();
        notebook::write_sidecar(&self.path, &outs)?;
        Ok(())
    }

    pub fn clear_cell_outputs(&self, cell_id: &str) {
        let mut outs = self.outputs.write();
        outs.cells.remove(cell_id);
    }

    pub fn clear_all_outputs(&self) {
        let mut outs = self.outputs.write();
        outs.cells.clear();
    }

    /// Apply a kernel event to in-memory output state. Returns the (cell_id,
    /// frontend-shaped event payload) tuple so the RPC layer can notify Lua.
    pub fn apply_event(&self, ev: &KernelEvent) -> Option<(String, Value)> {
        let parent = match ev {
            KernelEvent::Stream { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::DisplayData { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::ExecuteResult { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::Error { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::Status { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::ExecuteInput { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::ExecuteReply { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::UpdateDisplayData { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::ClearOutput { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::KernelInfo { parent_msg_id, .. } => parent_msg_id.clone(),
        }?;
        let cell_id = self.msg_to_cell.get(&parent)?.clone();

        let mut outs = self.outputs.write();
        let cell = outs.cells.entry(cell_id.clone()).or_insert_with(CellOutputs::default);

        let payload = match ev {
            KernelEvent::Stream { name, text, .. } => {
                notebook::append_stream(&mut cell.outputs, name, text);
                json!({ "kind": "stream", "name": name, "text": text })
            }
            KernelEvent::DisplayData { data, metadata, .. } => {
                notebook::append_display(&mut cell.outputs, data.clone(), metadata.clone());
                json!({ "kind": "display_data", "data": data, "metadata": metadata })
            }
            KernelEvent::UpdateDisplayData { data, metadata, .. } => {
                json!({ "kind": "update_display_data", "data": data, "metadata": metadata })
            }
            KernelEvent::ExecuteResult {
                execution_count,
                data,
                metadata,
                ..
            } => {
                cell.execution_count = Some(*execution_count);
                notebook::append_execute_result(
                    &mut cell.outputs,
                    *execution_count,
                    data.clone(),
                    metadata.clone(),
                );
                json!({ "kind": "execute_result", "execution_count": execution_count, "data": data })
            }
            KernelEvent::Error {
                ename,
                evalue,
                traceback,
                ..
            } => {
                notebook::append_error(&mut cell.outputs, ename, evalue, traceback.clone());
                json!({ "kind": "error", "ename": ename, "evalue": evalue, "traceback": traceback })
            }
            KernelEvent::ExecuteInput {
                execution_count, ..
            } => {
                cell.execution_count = Some(*execution_count);
                cell.outputs.clear();
                json!({ "kind": "execute_input", "execution_count": execution_count })
            }
            KernelEvent::Status {
                execution_state, ..
            } => {
                json!({ "kind": "status", "state": execution_state })
            }
            KernelEvent::ExecuteReply {
                status,
                execution_count,
                ..
            } => {
                json!({ "kind": "execute_reply", "status": status, "execution_count": execution_count })
            }
            KernelEvent::ClearOutput { wait, .. } => {
                if !wait {
                    cell.outputs.clear();
                }
                json!({ "kind": "clear_output", "wait": wait })
            }
            KernelEvent::KernelInfo { info, .. } => {
                json!({ "kind": "kernel_info", "info": info })
            }
        };
        // Persist eagerly so external readers and a future :checkhealth jovian see
        // current state without us needing an explicit save RPC. The write is
        // synchronous but small (one cell's worth of JSON).
        drop(outs);
        if let Err(e) = self.persist_outputs() {
            tracing::warn!("persist sidecar: {e:?}");
        }
        Some((cell_id, payload))
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionSnapshot {
    pub id: String,
    pub path: String,
    pub cells: Vec<CellSnapshot>,
}

