// Session = one open `.py` source + its kernel + its cell↔msg_id state.
//
// Outputs live in the sidecar JSON at `.jovian_cache/<filename>/outputs.json`;
// we keep an in-memory copy mirrored to that file and persist eagerly so
// that other Neovim instances or external tools see fresh state.

use anyhow::Result;
use dashmap::DashMap;
use parking_lot::{Mutex, RwLock};
use serde::Serialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{oneshot, Notify, RwLock as AsyncRwLock};

use crate::kernel::{Kernel, KernelEvent};
use crate::notebook::{self, OutputStoreFile, Source};

// Window during which apply_event() calls coalesce into a single sidecar
// write. A chatty cell (e.g. a print-in-a-loop with 10k iterations) used to
// re-serialize and overwrite the entire JSON file once per iopub event —
// O(N²) work and 10k crash-windows where readers saw partial JSON. Now we
// write at most once per PERSIST_DEBOUNCE_MS regardless of event rate.
const PERSIST_DEBOUNCE_MS: u64 = 100;

/// A collector for execute_collect: accumulates kernel events for one
/// msg_id and fires `done` with the collected list when the kernel goes
/// idle. The Option wrapper lets `try_collect` atomically extract the
/// sender on the terminating event without holding a mutable borrow.
pub struct Collector {
    pub events: Vec<KernelEvent>,
    pub done: Option<oneshot::Sender<Vec<KernelEvent>>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CellSnapshot {
    pub id: String,
    pub cell_type: String,
    pub source: String,
    pub header_line: usize,
    pub end_line: usize,
    pub execution_count: Option<u64>,
    pub outputs: Vec<Value>,
    pub tags: Vec<String>,
}

pub struct Session {
    pub id: String,
    pub path: PathBuf,
    pub source: RwLock<Source>,
    pub outputs: RwLock<OutputStoreFile>,
    pub kernel: AsyncRwLock<Option<Kernel>>,
    /// msg_id → cell_id, for routing iopub events back to the originating cell.
    /// Entries are GC'd by `try_complete_msg` once both `status: idle` and
    /// `execute_reply` have been seen for the msg_id — the standard Jupyter
    /// "request done" signal pair.
    pub msg_to_cell: DashMap<String, String>,
    /// Tracks (saw_idle, saw_reply) per in-flight msg_id so we can clean up
    /// `msg_to_cell` after the request completes. Without this the map grows
    /// unboundedly across a long session.
    msg_completion: DashMap<String, (bool, bool)>,
    /// msg_id → output collector, for hidden execute requests (Vars/View).
    /// Events with a matching parent_msg_id are diverted into the collector
    /// instead of going through apply_event / cell_event notifications.
    pub collect_pending: DashMap<String, Mutex<Collector>>,
    /// cell_id set with a pending `clear_output(wait=true)`. The clear is
    /// deferred to the moment the next output arrives (progress widgets
    /// like tqdm emit clear-then-redraw); without honoring it, every redraw
    /// appended a fresh copy and the sidecar grew without bound.
    clear_pending: DashMap<String, ()>,
    /// Wake signal for the debounced sidecar persister task. apply_event
    /// calls request_persist() instead of writing synchronously; the task
    /// sleeps PERSIST_DEBOUNCE_MS after each wake, coalescing bursts.
    persist_signal: Arc<Notify>,
    /// Fires when the session is dropped, so the debounced persister task
    /// (which parks on `persist_signal.notified()`) is woken and can exit
    /// instead of leaking for the lifetime of the process.
    shutdown: Arc<Notify>,
}

impl Drop for Session {
    fn drop(&mut self) {
        self.shutdown.notify_waiters();
    }
}

impl Session {
    pub fn open(id: String, path: PathBuf) -> Result<Arc<Self>> {
        let source = Source::read(&path)?;
        let outputs = notebook::read_sidecar(&path)?;
        let persist_signal = Arc::new(Notify::new());
        let shutdown = Arc::new(Notify::new());
        let session = Arc::new(Self {
            id,
            path,
            source: RwLock::new(source),
            outputs: RwLock::new(outputs),
            kernel: AsyncRwLock::new(None),
            msg_to_cell: DashMap::new(),
            msg_completion: DashMap::new(),
            collect_pending: DashMap::new(),
            clear_pending: DashMap::new(),
            persist_signal: persist_signal.clone(),
            shutdown: shutdown.clone(),
        });
        // Debounced flush task. Holds a Weak<Session> so it doesn't keep
        // the session alive; when the session is dropped Drop fires
        // `shutdown`, waking the parked task so it can exit instead of
        // blocking forever on `persist_signal.notified()` (no further
        // notifications come once the session is gone).
        let weak = Arc::downgrade(&session);
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = persist_signal.notified() => {}
                    _ = shutdown.notified() => return,
                }
                tokio::time::sleep(Duration::from_millis(PERSIST_DEBOUNCE_MS)).await;
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if let Err(e) = s.persist_outputs() {
                    tracing::warn!("persist sidecar (debounced): {e:?}");
                }
            }
        });
        Ok(session)
    }

    /// Wake the debounced persister. Cheap (a single `notify_one`) so it's
    /// safe to call from every apply_event without rate-limiting at the
    /// call site.
    pub fn request_persist(&self) {
        self.persist_signal.notify_one();
    }

    /// Register a collector for a hidden execute. Returns the receiver
    /// that fires when the kernel goes idle for this msg_id.
    pub fn start_collect(&self, msg_id: String) -> oneshot::Receiver<Vec<KernelEvent>> {
        let (tx, rx) = oneshot::channel();
        let c = Collector {
            events: Vec::new(),
            done: Some(tx),
        };
        self.collect_pending.insert(msg_id, Mutex::new(c));
        rx
    }

    /// If the event's parent_msg_id has a pending collector, accumulate
    /// the event into it and (on status=idle) fire the receiver. Returns
    /// true if the event was consumed (skip normal routing).
    pub fn try_collect(&self, ev: &KernelEvent) -> bool {
        let parent = match ev.parent_msg_id() {
            Some(p) => p,
            None => return false,
        };
        let entry = match self.collect_pending.get(parent) {
            Some(e) => e,
            None => return false,
        };
        let mut c = entry.lock();
        c.events.push(ev.clone());
        // status=idle marks the end of a request's iopub stream.
        let is_idle = matches!(
            ev,
            KernelEvent::Status { execution_state, .. } if execution_state == "idle"
        );
        if is_idle {
            if let Some(tx) = c.done.take() {
                let events = std::mem::take(&mut c.events);
                let _ = tx.send(events);
            }
            drop(c);
            drop(entry);
            self.collect_pending.remove(parent);
        }
        true
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
                    tags: c.tags.clone(),
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
        *src = Source::parse(text);
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

    /// Mark one half of a request's completion signal (`status: idle` on
    /// iopub, or `execute_reply` on shell). When both have been observed
    /// for the same msg_id, the routing entry in `msg_to_cell` is removed
    /// — this is what keeps the map from growing without bound across a
    /// long session.
    fn mark_msg_progress(&self, msg_id: &str, saw_idle: bool, saw_reply: bool) {
        let mut entry = self
            .msg_completion
            .entry(msg_id.to_string())
            .or_insert((false, false));
        if saw_idle {
            entry.0 = true;
        }
        if saw_reply {
            entry.1 = true;
        }
        let done = entry.0 && entry.1;
        drop(entry);
        if done {
            self.msg_completion.remove(msg_id);
            self.msg_to_cell.remove(msg_id);
        }
    }

    /// Apply a kernel event to in-memory output state. Returns the (cell_id,
    /// frontend-shaped event payload) tuple so the RPC layer can notify Lua.
    pub fn apply_event(&self, ev: &KernelEvent) -> Option<(String, Value)> {
        let parent = ev.parent_msg_id()?;
        let cell_id = self.msg_to_cell.get(parent)?.clone();

        let mut outs = self.outputs.write();
        let cell = outs.cells.entry(cell_id.clone()).or_default();

        // Honor a deferred clear_output(wait=true): the wipe was postponed
        // to the moment real output next arrives for this cell.
        let is_output = matches!(
            ev,
            KernelEvent::Stream { .. }
                | KernelEvent::DisplayData { .. }
                | KernelEvent::ExecuteResult { .. }
                | KernelEvent::Error { .. }
        );
        if is_output && self.clear_pending.remove(&cell_id).is_some() {
            cell.outputs.clear();
        }

        let payload = match ev {
            KernelEvent::Stream { name, text, .. } => {
                notebook::append_stream(&mut cell.outputs, name, text);
                json!({ "kind": "stream", "name": name, "text": text })
            }
            KernelEvent::DisplayData { data, metadata, .. } => {
                notebook::append_display(&mut cell.outputs, data.clone(), metadata.clone());
                json!({ "kind": "display_data", "data": data, "metadata": metadata })
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
                // A new execution supersedes any deferred clear.
                self.clear_pending.remove(&cell_id);
                json!({ "kind": "execute_input", "execution_count": execution_count })
            }
            KernelEvent::Status {
                execution_state, ..
            } => {
                if execution_state == "idle" {
                    self.mark_msg_progress(parent, true, false);
                }
                json!({ "kind": "status", "state": execution_state })
            }
            KernelEvent::ExecuteReply {
                status,
                execution_count,
                ..
            } => {
                self.mark_msg_progress(parent, false, true);
                json!({ "kind": "execute_reply", "status": status, "execution_count": execution_count })
            }
            KernelEvent::ClearOutput { wait, .. } => {
                if !wait {
                    cell.outputs.clear();
                } else {
                    // Defer the clear until the next output arrives.
                    self.clear_pending.insert(cell_id.clone(), ());
                }
                json!({ "kind": "clear_output", "wait": wait })
            }
            KernelEvent::KernelInfo { info, .. } => {
                json!({ "kind": "kernel_info", "info": info })
            }
            // KernelDied is filtered out at the parent_msg_id() check above
            // (it has no parent), so it never reaches this match.
            KernelEvent::KernelDied { .. } => unreachable!(),
        };
        // Persist stream bursts via the debounced flusher, but make the
        // completed cell's sidecar durable before forwarding its `idle`
        // notification.  The Lua inline renderer deliberately reads the
        // sidecar as its single source of truth; without this final flush it
        // can render between apply_event() and the 100 ms debounce write,
        // then receive no later event to trigger another render.  That made
        // a cell's first execution appear blank until it was run again.
        drop(outs);
        let is_idle = matches!(
            ev,
            KernelEvent::Status {
                execution_state,
                ..
            } if execution_state == "idle"
        );
        if is_idle {
            if let Err(e) = self.persist_outputs() {
                tracing::warn!("persist sidecar on cell completion: {e:?}");
            }
        } else {
            self.request_persist();
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
