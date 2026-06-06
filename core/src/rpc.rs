// msgpack-rpc over stdio.
// Frame layout (Neovim msgpack-rpc):
//   Request:      [0, msgid, method, params]
//   Response:     [1, msgid, error|nil, result|nil]
//   Notification: [2, method, params]

use anyhow::{anyhow, Result};
use dashmap::DashMap;
use rmpv::Value as Mp;
use serde_json::{json, Value as Json};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{Mutex, Notify};
use uuid::Uuid;

use crate::kernel::Kernel;
use crate::kernelspec;
use crate::kitty::KittyTty;
use crate::session::Session;

pub struct Server {
    sessions: DashMap<String, Arc<Session>>,
    out_tx: Mutex<Option<tokio::sync::mpsc::UnboundedSender<Mp>>>,
    shutdown: Arc<Notify>,
    kitty: Mutex<Option<KittyTty>>,
}

impl Server {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            sessions: DashMap::new(),
            out_tx: Mutex::new(None),
            shutdown: Arc::new(Notify::new()),
            kitty: Mutex::new(None),
        })
    }

    pub async fn run_stdio(self: Arc<Self>) -> Result<()> {
        let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<Mp>();
        *self.out_tx.lock().await = Some(out_tx);

        let writer = tokio::spawn(async move {
            let mut out = tokio::io::stdout();
            while let Some(msg) = out_rx.recv().await {
                let mut buf = Vec::with_capacity(256);
                if let Err(e) = rmpv::encode::write_value(&mut buf, &msg) {
                    tracing::error!("encode rpc: {e}");
                    continue;
                }
                let len = buf.len() as u32;
                let header = len.to_be_bytes();
                if let Err(e) = out.write_all(&header).await {
                    tracing::error!("stdout write hdr: {e}");
                    break;
                }
                if let Err(e) = out.write_all(&buf).await {
                    tracing::error!("stdout write: {e}");
                    break;
                }
                if let Err(e) = out.flush().await {
                    tracing::error!("stdout flush: {e}");
                    break;
                }
            }
        });

        let server = self.clone();
        let reader = tokio::spawn(async move {
            let mut stdin = tokio::io::stdin();
            let mut buf = vec![0u8; 64 * 1024];
            let mut acc: Vec<u8> = Vec::with_capacity(64 * 1024);
            loop {
                let n = match stdin.read(&mut buf).await {
                    Ok(0) => {
                        tracing::info!("stdin EOF");
                        break;
                    }
                    Ok(n) => n,
                    Err(e) => {
                        tracing::error!("stdin read: {e}");
                        break;
                    }
                };
                acc.extend_from_slice(&buf[..n]);
                loop {
                    if acc.len() < 4 {
                        break;
                    }
                    let len = u32::from_be_bytes([acc[0], acc[1], acc[2], acc[3]]) as usize;
                    if acc.len() < 4 + len {
                        break;
                    }
                    let payload = acc[4..4 + len].to_vec();
                    acc.drain(..4 + len);
                    let mut cursor = std::io::Cursor::new(&payload[..]);
                    match rmpv::decode::read_value(&mut cursor) {
                        Ok(val) => {
                            let server2 = server.clone();
                            tokio::spawn(async move {
                                if let Err(e) = server2.handle_message(val).await {
                                    tracing::warn!("handle_message: {e:?}");
                                }
                            });
                        }
                        Err(e) => {
                            tracing::warn!("decode rpc payload: {e}");
                        }
                    }
                }
            }
        });

        tokio::select! {
            _ = self.shutdown.notified() => {}
            _ = reader => {}
            _ = writer => {}
        }
        Ok(())
    }

    async fn send(&self, msg: Mp) {
        let g = self.out_tx.lock().await;
        if let Some(tx) = g.as_ref() {
            let _ = tx.send(msg);
        }
    }

    async fn handle_message(self: Arc<Self>, val: Mp) -> Result<()> {
        let arr = val.as_array().ok_or_else(|| anyhow!("rpc msg not array"))?;
        if arr.is_empty() {
            return Err(anyhow!("empty rpc msg"));
        }
        let kind = arr[0].as_u64().ok_or_else(|| anyhow!("bad kind"))?;
        match kind {
            0 => {
                if arr.len() < 4 {
                    return Err(anyhow!("bad request"));
                }
                let msgid = arr[1].as_u64().ok_or_else(|| anyhow!("bad msgid"))?;
                let method = arr[2]
                    .as_str()
                    .ok_or_else(|| anyhow!("bad method"))?
                    .to_string();
                let params = arr[3].clone();
                let server = self.clone();
                tokio::spawn(async move {
                    let server2 = server.clone();
                    let result = server.dispatch(&method, params).await;
                    let resp = match result {
                        Ok(v) => Mp::Array(vec![
                            Mp::from(1u32),
                            Mp::from(msgid),
                            Mp::Nil,
                            json_to_mp(&v),
                        ]),
                        Err(e) => Mp::Array(vec![
                            Mp::from(1u32),
                            Mp::from(msgid),
                            Mp::String(format!("{e:#}").into()),
                            Mp::Nil,
                        ]),
                    };
                    server2.send(resp).await;
                });
            }
            2 => {
                if arr.len() < 3 {
                    return Err(anyhow!("bad notification"));
                }
                let method = arr[1]
                    .as_str()
                    .ok_or_else(|| anyhow!("bad method"))?
                    .to_string();
                let params = arr[2].clone();
                let server = self.clone();
                tokio::spawn(async move {
                    if let Err(e) = server.dispatch(&method, params).await {
                        tracing::warn!("notify {} error: {e:?}", method);
                    }
                });
            }
            1 => { /* responses ignored — we don't make requests from core */ }
            _ => return Err(anyhow!("unknown rpc kind {kind}")),
        }
        Ok(())
    }

    async fn dispatch(self: Arc<Self>, method: &str, params: Mp) -> Result<Json> {
        let p = match &params {
            Mp::Array(arr) if arr.len() == 1 => mp_to_json(&arr[0]),
            _ => mp_to_json(&params),
        };
        match method {
            "ping" => Ok(json!("pong")),
            "version" => Ok(json!({
                "version": env!("CARGO_PKG_VERSION"),
                "name": env!("CARGO_PKG_NAME"),
            })),
            "list_kernels" => self.list_kernels(),
            "open" => self.open(p).await,
            "close" => self.close(p).await,
            "snapshot" => self.snapshot(p),
            "reparse" => self.reparse(p),
            "start_kernel" => self.start_kernel(p).await,
            "stop_kernel" => self.stop_kernel(p).await,
            "interrupt_kernel" => self.interrupt_kernel(p).await,
            "restart_kernel" => self.restart_kernel(p).await,
            "execute" => self.execute(p).await,
            "execute_silent" => self.execute_silent(p).await,
            "execute_collect" => self.execute_collect(p).await,
            "complete" => self.complete(p).await,
            "inspect" => self.inspect(p).await,
            "clear_outputs" => self.clear_outputs(p),
            "clear_cell_output" => self.clear_cell_output(p),
            "persist_outputs" => self.persist_outputs(p),
            "kitty_attach" => self.kitty_attach(p).await,
            "kitty_transmit" => self.kitty_transmit(p).await,
            "kitty_clear" => self.kitty_clear(p).await,
            other => Err(anyhow!("unknown method '{other}'")),
        }
    }

    // ---- handlers ----

    fn list_kernels(&self) -> Result<Json> {
        Ok(serde_json::to_value(kernelspec::discover_all())?)
    }

    async fn open(&self, p: Json) -> Result<Json> {
        let path = p
            .get("path")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("path required"))?;
        let id = Uuid::new_v4().to_string();
        let session = Session::open(id.clone(), PathBuf::from(path))?;
        self.sessions.insert(id.clone(), session.clone());
        Ok(json!({ "session_id": id, "snapshot": session.snapshot() }))
    }

    async fn close(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        if let Some((_, s)) = self.sessions.remove(sid) {
            let kernel = s.kernel.write().await.take();
            if let Some(k) = kernel {
                let _ = k.kill().await;
            }
        }
        Ok(json!({ "ok": true }))
    }

    fn snapshot(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let s = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("session not found"))?;
        Ok(serde_json::to_value(s.snapshot())?)
    }

    fn reparse(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let text = p
            .get("text")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("text required"))?;
        let s = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("session not found"))?;
        s.reparse(text);
        Ok(serde_json::to_value(s.snapshot())?)
    }

    async fn start_kernel(self: Arc<Self>, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?
            .to_string();
        let session = self
            .sessions
            .get(&sid)
            .ok_or_else(|| anyhow!("session not found"))?
            .clone();

        let kernel = if let Some(host) = p.get("host").and_then(|v| v.as_str()) {
            // Remote kernel over SSH. jovian-core owns the tunnel; the local
            // ZMQ sockets connect to forwarded localhost ports.
            let remote_python = p
                .get("remote_python")
                .and_then(|v| v.as_str())
                .unwrap_or("python3");
            let remote_cwd = p.get("remote_cwd").and_then(|v| v.as_str());
            Kernel::launch_remote(host, remote_python, remote_cwd).await?
        } else {
            let spec = if let Some(py) = p.get("python_path").and_then(|v| v.as_str()) {
                let py = py.to_string();
                let path_buf = PathBuf::from(&py);
                let parent = path_buf
                    .parent()
                    .and_then(|p| p.parent())
                    .map(|p| p.to_path_buf())
                    .unwrap_or_else(|| path_buf.clone());
                kernelspec::KernelSpec {
                    name: "venv-python".to_string(),
                    path: parent,
                    argv: vec![
                        py,
                        "-m".to_string(),
                        "ipykernel_launcher".to_string(),
                        "-f".to_string(),
                        "{connection_file}".to_string(),
                    ],
                    display_name: "venv python".to_string(),
                    language: "python".to_string(),
                    interrupt_mode: None,
                    env: std::collections::HashMap::new(),
                    metadata: Json::Null,
                }
            } else {
                let name = p
                    .get("kernel_name")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "python3".to_string());
                kernelspec::discover_with_fallback(&name, Some("python"))
                    .ok_or_else(|| anyhow!("no kernelspec found for '{name}'"))?
            };

            let cwd = session.path.parent().map(|p| p.to_path_buf());
            Kernel::launch(spec, cwd).await?
        };
        let kernel_name = kernel.spec().name.clone();
        let mut rx = kernel
            .take_events()
            .await
            .ok_or_else(|| anyhow!("kernel events already taken"))?;

        {
            let mut slot = session.kernel.write().await;
            if let Some(old) = slot.take() {
                let _ = old.kill().await;
            }
            *slot = Some(kernel);
        }

        let server = self.clone();
        let session_clone = session.clone();
        let sid_clone = sid.clone();
        tokio::spawn(async move {
            while let Some(ev) = rx.recv().await {
                // Hidden execute requests (Vars/View etc.) register a
                // collector keyed by msg_id; their events are diverted
                // there instead of going through cell_event routing.
                if session_clone.try_collect(&ev) {
                    continue;
                }
                if let Some((cell_id, payload)) = session_clone.apply_event(&ev) {
                    let note = json!({
                        "session_id": sid_clone,
                        "cell_id": cell_id,
                        "event": payload,
                    });
                    server.notify("cell_event", note).await;
                } else {
                    let note = json!({
                        "session_id": sid_clone,
                        "event": json!({ "kind": "global", "raw": format!("{ev:?}") }),
                    });
                    server.notify("kernel_event", note).await;
                }
            }
            tracing::info!("kernel events channel closed for session {sid_clone}");
        });

        Ok(json!({ "kernel_name": kernel_name }))
    }

    async fn stop_kernel(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let s = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        let k = s.kernel.write().await.take();
        if let Some(k) = k {
            k.kill().await?;
        }
        Ok(json!({ "ok": true }))
    }

    async fn interrupt_kernel(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let s = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        let guard = s.kernel.read().await;
        if let Some(k) = guard.as_ref() {
            k.interrupt().await?;
        }
        Ok(json!({ "ok": true }))
    }

    async fn restart_kernel(self: Arc<Self>, p: Json) -> Result<Json> {
        self.stop_kernel(p.clone()).await.ok();
        self.start_kernel(p).await
    }

    async fn execute(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let cell_id = p
            .get("cell_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("cell_id required"))?;
        let session = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        // Source resolution: explicit `code` param wins (used by direct
        // code-runs, tests, scratchpad). Otherwise look up the cell by id
        // in the most recent reparse.
        let source = if let Some(c) = p.get("code").and_then(|v| v.as_str()) {
            c.to_string()
        } else {
            let src = session.source.read();
            src.cell(cell_id)
                .map(|c| c.source.clone())
                .ok_or_else(|| anyhow!("cell not found"))?
        };
        let guard = session.kernel.read().await;
        let kernel = guard
            .as_ref()
            .ok_or_else(|| anyhow!("kernel not started"))?;
        let msg_id = Uuid::new_v4().to_string();
        session
            .msg_to_cell
            .insert(msg_id.clone(), cell_id.to_string());
        kernel.execute_with_id(&source, msg_id.clone()).await?;
        Ok(json!({ "msg_id": msg_id }))
    }

    /// Run a code snippet and collect its iopub output (stream, result,
    /// error) into one reply. Used by hidden-execute features (Vars,
    /// View). Doesn't increment the kernel's execution counter and isn't
    /// routed to any cell_event subscriber.
    async fn execute_collect(&self, p: Json) -> Result<Json> {
        use crate::kernel::KernelEvent;
        use serde_json::Value;
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id"))?;
        let code = p
            .get("code")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("code"))?;
        let timeout_ms = p.get("timeout_ms").and_then(|v| v.as_u64()).unwrap_or(5000);
        let session = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        let kernel_guard = session.kernel.read().await;
        let kernel = kernel_guard
            .as_ref()
            .ok_or_else(|| anyhow!("kernel not started"))?;

        let msg_id = uuid::Uuid::new_v4().to_string();
        let rx = session.start_collect(msg_id.clone());
        // store_history=false keeps Vars/View probes out of Out[N].
        kernel
            .execute_with_id_opts(code, msg_id.clone(), false, false)
            .await?;

        let events =
            match tokio::time::timeout(std::time::Duration::from_millis(timeout_ms), rx).await {
                Ok(Ok(evs)) => evs,
                Ok(Err(_)) => {
                    session.collect_pending.remove(&msg_id);
                    return Err(anyhow!("execute_collect: receiver dropped"));
                }
                Err(_) => {
                    session.collect_pending.remove(&msg_id);
                    return Err(anyhow!("execute_collect: timeout after {timeout_ms}ms"));
                }
            };

        // Aggregate into a single reply payload.
        let mut stdout = String::new();
        let mut stderr = String::new();
        let mut result: Option<Value> = None;
        let mut error: Option<Value> = None;
        for ev in events {
            match ev {
                KernelEvent::Stream { name, text, .. } => {
                    if name == "stderr" {
                        stderr.push_str(&text);
                    } else {
                        stdout.push_str(&text);
                    }
                }
                KernelEvent::ExecuteResult { data, .. } | KernelEvent::DisplayData { data, .. } => {
                    result = Some(data);
                }
                KernelEvent::Error {
                    ename,
                    evalue,
                    traceback,
                    ..
                } => {
                    error = Some(json!({
                        "ename": ename,
                        "evalue": evalue,
                        "traceback": traceback,
                    }));
                }
                _ => {}
            }
        }
        Ok(json!({
            "stdout": stdout,
            "stderr": stderr,
            "result": result,
            "error": error,
        }))
    }

    async fn execute_silent(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id"))?;
        let code = p
            .get("code")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("code"))?;
        let session = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        let guard = session.kernel.read().await;
        let kernel = guard
            .as_ref()
            .ok_or_else(|| anyhow!("kernel not started"))?;
        let msg_id = Uuid::new_v4().to_string();
        kernel
            .execute_with_id_opts(code, msg_id.clone(), true, false)
            .await?;
        Ok(json!({ "msg_id": msg_id }))
    }

    async fn complete(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id"))?;
        let code = p
            .get("code")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("code"))?;
        let cursor_pos = p
            .get("cursor_pos")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("cursor_pos"))? as usize;
        let session = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        let guard = session.kernel.read().await;
        let kernel = guard
            .as_ref()
            .ok_or_else(|| anyhow!("kernel not started"))?;
        kernel.complete(code, cursor_pos).await
    }

    async fn inspect(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id"))?;
        let code = p
            .get("code")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("code"))?;
        let cursor_pos = p
            .get("cursor_pos")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("cursor_pos"))? as usize;
        let detail_level = p.get("detail_level").and_then(|v| v.as_u64()).unwrap_or(0) as u8;
        let session = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        let guard = session.kernel.read().await;
        let kernel = guard
            .as_ref()
            .ok_or_else(|| anyhow!("kernel not started"))?;
        kernel.inspect(code, cursor_pos, detail_level).await
    }

    fn clear_outputs(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id"))?;
        let s = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        s.clear_all_outputs();
        let _ = s.persist_outputs();
        Ok(json!({ "ok": true }))
    }

    fn clear_cell_output(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id"))?;
        let cell_id = p
            .get("cell_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("cell_id"))?;
        let s = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        s.clear_cell_outputs(cell_id);
        let _ = s.persist_outputs();
        Ok(json!({ "ok": true }))
    }

    fn persist_outputs(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id"))?;
        let s = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        s.persist_outputs()?;
        Ok(json!({ "ok": true }))
    }

    async fn kitty_attach(&self, p: Json) -> Result<Json> {
        let path = p.get("tty").and_then(|v| v.as_str()).map(PathBuf::from);
        let kitty = KittyTty::open(path)?;
        *self.kitty.lock().await = Some(kitty);
        Ok(json!({ "ok": true }))
    }

    async fn kitty_transmit(&self, p: Json) -> Result<Json> {
        let b64 = p
            .get("png_b64")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("png_b64 required"))?;
        let id_hint = p.get("image_id").and_then(|v| v.as_u64()).map(|n| n as u32);
        // The Unicode-placeholder protocol needs the placement grid up
        // front so Kitty knows how to scale the image when placeholders
        // reference it. Defaults pick the same shape jupynvim uses; the
        // caller (Lua) typically passes its render dimensions.
        let cols = p.get("cols").and_then(|v| v.as_u64()).unwrap_or(56) as u32;
        let rows = p.get("rows").and_then(|v| v.as_u64()).unwrap_or(14) as u32;
        let kitty_lock = self.kitty.lock().await;
        let kitty = kitty_lock
            .as_ref()
            .ok_or_else(|| anyhow!("kitty_attach not called"))?;
        let png = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, b64)
            .map_err(|e| anyhow!("base64 decode: {e}"))?;
        let id = match id_hint {
            Some(i) => {
                kitty.transmit_png_with_id(i, &png, cols, rows)?;
                i
            }
            None => kitty.transmit_png(&png, cols, rows)?,
        };
        Ok(json!({ "image_id": id }))
    }

    async fn kitty_clear(&self, p: Json) -> Result<Json> {
        let kitty_lock = self.kitty.lock().await;
        let kitty = kitty_lock
            .as_ref()
            .ok_or_else(|| anyhow!("kitty not attached"))?;
        if let Some(id) = p.get("image_id").and_then(|v| v.as_u64()) {
            kitty.delete_image(id as u32)?;
        } else {
            kitty.delete_all()?;
        }
        Ok(json!({ "ok": true }))
    }

    async fn notify(&self, method: &str, params: Json) {
        let msg = Mp::Array(vec![
            Mp::from(2u32),
            Mp::String(method.to_string().into()),
            Mp::Array(vec![json_to_mp(&params)]),
        ]);
        self.send(msg).await;
    }
}

// rmpv <-> serde_json conversion
pub fn mp_to_json(v: &Mp) -> Json {
    match v {
        Mp::Nil => Json::Null,
        Mp::Boolean(b) => Json::Bool(*b),
        Mp::Integer(i) => i
            .as_i64()
            .map(Json::from)
            .or_else(|| i.as_u64().map(Json::from))
            .or_else(|| {
                i.as_f64()
                    .and_then(serde_json::Number::from_f64)
                    .map(Json::Number)
            })
            .unwrap_or(Json::Null),
        Mp::F32(f) => serde_json::Number::from_f64(*f as f64)
            .map(Json::Number)
            .unwrap_or(Json::Null),
        Mp::F64(f) => serde_json::Number::from_f64(*f)
            .map(Json::Number)
            .unwrap_or(Json::Null),
        Mp::String(s) => Json::String(s.as_str().unwrap_or("").to_string()),
        Mp::Binary(b) => Json::String(base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            b,
        )),
        Mp::Array(a) => Json::Array(a.iter().map(mp_to_json).collect()),
        Mp::Map(m) => {
            let mut out = serde_json::Map::with_capacity(m.len());
            for (k, v) in m {
                let key = match k {
                    Mp::String(s) => s.as_str().unwrap_or("").to_string(),
                    other => format!("{other:?}"),
                };
                out.insert(key, mp_to_json(v));
            }
            Json::Object(out)
        }
        Mp::Ext(_, _) => Json::Null,
    }
}

pub fn json_to_mp(v: &Json) -> Mp {
    match v {
        Json::Null => Mp::Nil,
        Json::Bool(b) => Mp::Boolean(*b),
        Json::Number(n) => {
            if let Some(i) = n.as_i64() {
                Mp::from(i)
            } else if let Some(u) = n.as_u64() {
                Mp::from(u)
            } else if let Some(f) = n.as_f64() {
                Mp::F64(f)
            } else {
                Mp::Nil
            }
        }
        Json::String(s) => Mp::String(s.clone().into()),
        Json::Array(a) => Mp::Array(a.iter().map(json_to_mp).collect()),
        Json::Object(o) => Mp::Map(
            o.iter()
                .map(|(k, v)| (Mp::String(k.clone().into()), json_to_mp(v)))
                .collect(),
        ),
    }
}
