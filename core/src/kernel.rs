// Spawn a Jupyter kernel and own its ZMQ sockets (shell, iopub, control).
//
// Connection-file based handshake: write JSON with random ports + HMAC key,
// kernel reads it via {connection_file} substitution in argv, then we
// connect via ZMQ. Adapted from jupynvim-core.

use anyhow::{anyhow, Context, Result};
use bytes::Bytes;
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot, Mutex};
use uuid::Uuid;
use zeromq::{DealerSocket, Socket, SocketRecv, SocketSend, SubSocket, ZmqMessage};

use crate::kernelspec::KernelSpec;
use crate::protocol::{self, Message};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionInfo {
    pub ip: String,
    pub transport: String,
    pub shell_port: u16,
    pub iopub_port: u16,
    pub stdin_port: u16,
    pub control_port: u16,
    pub hb_port: u16,
    pub key: String,
    pub signature_scheme: String,
    pub kernel_name: String,
}

impl ConnectionInfo {
    pub fn new_localhost(kernel_name: &str) -> Result<Self> {
        let ports = pick_ports(5)?;
        let key = Uuid::new_v4().to_string();
        Ok(Self {
            ip: "127.0.0.1".to_string(),
            transport: "tcp".to_string(),
            shell_port: ports[0],
            iopub_port: ports[1],
            stdin_port: ports[2],
            control_port: ports[3],
            hb_port: ports[4],
            key,
            signature_scheme: "hmac-sha256".to_string(),
            kernel_name: kernel_name.to_string(),
        })
    }

    pub fn endpoint(&self, port: u16) -> String {
        format!("{}://{}:{}", self.transport, self.ip, port)
    }
}

fn pick_ports(n: usize) -> Result<Vec<u16>> {
    use std::net::TcpListener;
    let mut ports = Vec::with_capacity(n);
    let mut listeners = Vec::with_capacity(n);
    for _ in 0..n {
        let l = TcpListener::bind("127.0.0.1:0")?;
        let p = l.local_addr()?.port();
        ports.push(p);
        listeners.push(l);
    }
    drop(listeners);
    Ok(ports)
}

// --- remote (SSH) kernel helpers ---

/// The python program run on the remote during bootstrap: pick 5 free ports,
/// write the kernel connection file (sharing our HMAC `key`), and print a
/// `JOVIAN_CONN <path> p0 p1 p2 p3 p4` sentinel line. `key` is a UUID, so it
/// embeds safely inside the double-quoted python string literal.
fn bootstrap_script(key: &str) -> String {
    format!(
        r#"import socket, json, os, tempfile
def free():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p
ports = [free() for _ in range(5)]
conn = {{"ip": "127.0.0.1", "transport": "tcp",
        "shell_port": ports[0], "iopub_port": ports[1], "stdin_port": ports[2],
        "control_port": ports[3], "hb_port": ports[4],
        "key": "{key}", "signature_scheme": "hmac-sha256", "kernel_name": "python3"}}
fd, path = tempfile.mkstemp(prefix="jovian-kernel-", suffix=".json")
with os.fdopen(fd, "w") as f:
    json.dump(conn, f)
print("JOVIAN_CONN %s %s" % (path, " ".join(str(p) for p in ports)), flush=True)
"#
    )
}

/// Parse the bootstrap sentinel `JOVIAN_CONN <remote_conn_path> p0 p1 p2 p3 p4`.
fn parse_bootstrap_line(line: &str) -> Option<(String, [u16; 5])> {
    let mut it = line.split_whitespace();
    if it.next()? != "JOVIAN_CONN" {
        return None;
    }
    let path = it.next()?.to_string();
    let mut ports = [0u16; 5];
    for slot in ports.iter_mut() {
        *slot = it.next()?.parse().ok()?;
    }
    Some((path, ports))
}

/// Build the `ssh -L 127.0.0.1:<local>:127.0.0.1:<remote>` argument list for
/// all five ZMQ ports (10 tokens: `-L`, spec, `-L`, spec, …).
fn forward_args(local: &[u16; 5], remote: &[u16; 5]) -> Vec<String> {
    let mut v = Vec::with_capacity(10);
    for i in 0..5 {
        v.push("-L".to_string());
        v.push(format!("127.0.0.1:{}:127.0.0.1:{}", local[i], remote[i]));
    }
    v
}

/// Single-quote a string for safe interpolation into the remote shell command.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// A synthetic KernelSpec for a remote kernel (no local kernelspec discovery).
fn remote_spec(host: &str) -> KernelSpec {
    KernelSpec {
        name: format!("remote:{host}"),
        path: PathBuf::from("."),
        argv: Vec::new(),
        display_name: format!("remote python ({host})"),
        language: "python".to_string(),
        interrupt_mode: None,
        env: std::collections::HashMap::new(),
        metadata: Value::Null,
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum KernelEvent {
    Stream {
        msg_id: String,
        parent_msg_id: Option<String>,
        name: String,
        text: String,
    },
    DisplayData {
        msg_id: String,
        parent_msg_id: Option<String>,
        data: Value,
        metadata: Value,
        transient: Value,
    },
    ExecuteResult {
        msg_id: String,
        parent_msg_id: Option<String>,
        execution_count: u64,
        data: Value,
        metadata: Value,
    },
    Error {
        msg_id: String,
        parent_msg_id: Option<String>,
        ename: String,
        evalue: String,
        traceback: Vec<String>,
    },
    Status {
        execution_state: String,
        parent_msg_id: Option<String>,
    },
    ExecuteInput {
        parent_msg_id: Option<String>,
        execution_count: u64,
        code: String,
    },
    ExecuteReply {
        parent_msg_id: Option<String>,
        status: String,
        execution_count: u64,
    },
    UpdateDisplayData {
        msg_id: String,
        parent_msg_id: Option<String>,
        data: Value,
        metadata: Value,
        transient: Value,
    },
    ClearOutput {
        parent_msg_id: Option<String>,
        wait: bool,
    },
    KernelInfo {
        parent_msg_id: Option<String>,
        info: Value,
    },
}

pub struct Kernel {
    spec: KernelSpec,
    conn: ConnectionInfo,
    session: String,
    child: Mutex<Child>,
    shell_tx: mpsc::UnboundedSender<ZmqMessage>,
    control_tx: mpsc::UnboundedSender<ZmqMessage>,
    iopub_handle: tokio::task::JoinHandle<()>,
    events: Mutex<Option<mpsc::UnboundedReceiver<KernelEvent>>>,
    pending: Arc<DashMap<String, oneshot::Sender<Value>>>,
}

impl Kernel {
    pub async fn launch(spec: KernelSpec, cwd: Option<PathBuf>) -> Result<Self> {
        let conn = ConnectionInfo::new_localhost(&spec.name)?;
        let conn_path = write_connection_file(&conn)?;
        tracing::info!(?conn_path, kernel = %spec.name, "launching kernel");

        let argv: Vec<String> = spec
            .argv
            .iter()
            .map(|a| {
                a.replace("{connection_file}", conn_path.to_string_lossy().as_ref())
                    .replace("{resource_dir}", spec.path.to_string_lossy().as_ref())
            })
            .collect();

        if argv.is_empty() {
            return Err(anyhow!("kernel '{}' has empty argv", spec.name));
        }

        let mut cmd = Command::new(&argv[0]);
        cmd.args(&argv[1..]);
        for (k, v) in &spec.env {
            cmd.env(k, v);
        }
        if let Some(d) = cwd {
            cmd.current_dir(d);
        }
        cmd.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);

        let child = cmd.spawn().with_context(|| format!("spawning {:?}", argv))?;
        Self::from_child_and_conn(spec, conn, child).await
    }

    /// Launch a kernel on a remote host over SSH and tunnel its ZMQ ports back
    /// to localhost. Two ssh calls: a short *bootstrap* where the remote picks
    /// its own free ports and writes the connection file, then a long-lived
    /// *launch* that sets up `-L` forwards (now that the remote ports are known)
    /// and execs the kernel. The launch ssh becomes `child`; killing it closes
    /// the forwards and EOFs the remote channel so the kernel dies with us.
    ///
    /// Auth is key/agent-based only (`BatchMode=yes`); there is no interactive
    /// password prompt.
    pub async fn launch_remote(host: &str, python: &str, cwd: Option<&str>) -> Result<Self> {
        use tokio::io::AsyncWriteExt;

        let key = Uuid::new_v4().to_string();

        // --- bootstrap: remote picks ports + writes the connection file ---
        let script = bootstrap_script(&key);
        let mut boot = Command::new("ssh");
        boot.arg("-o")
            .arg("BatchMode=yes")
            .arg(host)
            .arg(python)
            .arg("-") // python reads its program from stdin
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let mut boot_child = boot.spawn().context("spawning bootstrap ssh")?;
        {
            let mut stdin = boot_child
                .stdin
                .take()
                .ok_or_else(|| anyhow!("bootstrap ssh has no stdin"))?;
            stdin.write_all(script.as_bytes()).await?;
            stdin.shutdown().await?;
        }
        let out = boot_child
            .wait_with_output()
            .await
            .context("bootstrap ssh failed")?;
        if !out.status.success() {
            return Err(anyhow!(
                "remote kernel bootstrap failed ({}): {}",
                out.status,
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        let stdout = String::from_utf8_lossy(&out.stdout);
        let (conn_path, remote_ports) = stdout
            .lines()
            .find_map(parse_bootstrap_line)
            .ok_or_else(|| {
                anyhow!(
                    "no JOVIAN_CONN line from remote bootstrap; stderr: {}",
                    String::from_utf8_lossy(&out.stderr).trim()
                )
            })?;
        tracing::info!(%host, ?remote_ports, %conn_path, "remote kernel bootstrapped");

        // --- launch: -L forwards (local→remote) + exec the kernel ---
        let local = pick_ports(5)?;
        let local_ports: [u16; 5] = [local[0], local[1], local[2], local[3], local[4]];

        let remote_cmd = match cwd {
            Some(d) if !d.is_empty() => format!(
                "cd {} && exec {} -m ipykernel_launcher -f {}",
                shell_quote(d),
                shell_quote(python),
                shell_quote(&conn_path)
            ),
            _ => format!(
                "exec {} -m ipykernel_launcher -f {}",
                shell_quote(python),
                shell_quote(&conn_path)
            ),
        };

        let mut cmd = Command::new("ssh");
        cmd.arg("-o")
            .arg("BatchMode=yes")
            .arg("-o")
            .arg("ExitOnForwardFailure=yes")
            // Force a PTY (-tt) so that when we kill the local ssh, the remote
            // session receives SIGHUP and the kernel dies with us. Without a
            // PTY the kernel orphans: it never writes to real stdout (output
            // goes over ZMQ) so a closed channel yields neither SIGHUP nor
            // SIGPIPE, leaving the remote process running.
            .arg("-tt")
            .args(forward_args(&local_ports, &remote_ports))
            .arg(host)
            .arg(remote_cmd)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let child = cmd.spawn().context("spawning launch ssh")?;

        // Local connection points at the forwarded localhost ports; the key is
        // shared with the connection file the remote wrote.
        let conn = ConnectionInfo {
            ip: "127.0.0.1".to_string(),
            transport: "tcp".to_string(),
            shell_port: local_ports[0],
            iopub_port: local_ports[1],
            stdin_port: local_ports[2],
            control_port: local_ports[3],
            hb_port: local_ports[4],
            key,
            signature_scheme: "hmac-sha256".to_string(),
            kernel_name: "python3".to_string(),
        };
        Self::from_child_and_conn(remote_spec(host), conn, child).await
    }

    /// Wire up ZMQ sockets, channels, and the iopub loop around an
    /// already-spawned child process and a *local* connection. For remote
    /// kernels the connection points at SSH-forwarded localhost ports, so this
    /// tail is identical for local and remote.
    async fn from_child_and_conn(
        spec: KernelSpec,
        conn: ConnectionInfo,
        child: Child,
    ) -> Result<Self> {
        let session = Uuid::new_v4().to_string();

        let (shell, control, iopub) = connect_sockets(&conn).await?;

        let (tx, rx) = mpsc::unbounded_channel::<KernelEvent>();
        let tx_iopub = tx.clone();
        let tx_shell = tx.clone();
        let key = conn.key.as_bytes().to_vec();
        let iopub_handle = tokio::spawn(iopub_loop(iopub, key.clone(), tx_iopub));

        let (shell_tx, shell_rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let (control_tx, control_rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let pending: Arc<DashMap<String, oneshot::Sender<Value>>> = Arc::new(DashMap::new());
        tokio::spawn(socket_owner(
            shell,
            shell_rx,
            key.clone(),
            tx_shell,
            "shell",
            Some(pending.clone()),
        ));
        tokio::spawn(socket_owner(control, control_rx, key, tx, "control", None));

        Ok(Self {
            spec,
            conn,
            session,
            child: Mutex::new(child),
            shell_tx,
            control_tx,
            iopub_handle,
            events: Mutex::new(Some(rx)),
            pending,
        })
    }

    pub fn spec(&self) -> &KernelSpec {
        &self.spec
    }

    pub async fn take_events(&self) -> Option<mpsc::UnboundedReceiver<KernelEvent>> {
        self.events.lock().await.take()
    }

    pub async fn execute_with_id(&self, code: &str, msg_id: String) -> Result<String> {
        self.execute_with_id_opts(code, msg_id, false, true).await
    }

    pub async fn execute_with_id_opts(
        &self,
        code: &str,
        msg_id: String,
        silent: bool,
        store_history: bool,
    ) -> Result<String> {
        let mut msg = Message::new(
            "execute_request",
            self.session.clone(),
            protocol::execute_request(code, silent, store_history),
        );
        msg.header.msg_id = msg_id.clone();
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        let zmsg = frames_to_zmq(frames);
        self.shell_tx
            .send(zmsg)
            .map_err(|_| anyhow!("shell channel closed"))?;
        Ok(msg_id)
    }

    pub async fn complete(&self, code: &str, cursor_pos: usize) -> Result<Value> {
        self.shell_request(
            "complete_request",
            json!({ "code": code, "cursor_pos": cursor_pos }),
        )
        .await
    }

    pub async fn inspect(&self, code: &str, cursor_pos: usize, detail_level: u8) -> Result<Value> {
        self.shell_request(
            "inspect_request",
            json!({ "code": code, "cursor_pos": cursor_pos, "detail_level": detail_level }),
        )
        .await
    }

    async fn shell_request(&self, msg_type: &'static str, content: Value) -> Result<Value> {
        let msg_id = Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        self.pending.insert(msg_id.clone(), tx);

        let mut msg = Message::new(msg_type, self.session.clone(), content);
        msg.header.msg_id = msg_id.clone();
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        let zmsg = frames_to_zmq(frames);
        if self.shell_tx.send(zmsg).is_err() {
            self.pending.remove(&msg_id);
            return Err(anyhow!("shell channel closed"));
        }

        match tokio::time::timeout(Duration::from_millis(2000), rx).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(_)) => {
                self.pending.remove(&msg_id);
                Err(anyhow!("{msg_type} reply dropped"))
            }
            Err(_) => {
                self.pending.remove(&msg_id);
                Err(anyhow!("{msg_type} timed out"))
            }
        }
    }

    pub async fn interrupt(&self) -> Result<()> {
        let msg = Message::new(
            "interrupt_request",
            self.session.clone(),
            protocol::interrupt_request(),
        );
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        self.control_tx
            .send(frames_to_zmq(frames))
            .map_err(|_| anyhow!("control closed"))?;
        Ok(())
    }

    pub async fn kill(&self) -> Result<()> {
        self.iopub_handle.abort();
        let mut child = self.child.lock().await;
        let _ = child.start_kill();
        let _ = child.wait().await;
        Ok(())
    }
}

fn write_connection_file(conn: &ConnectionInfo) -> Result<PathBuf> {
    let dir = std::env::temp_dir().join("jovian");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("kernel-{}.json", Uuid::new_v4()));
    let val = json!({
        "ip": conn.ip,
        "transport": conn.transport,
        "shell_port": conn.shell_port,
        "iopub_port": conn.iopub_port,
        "stdin_port": conn.stdin_port,
        "control_port": conn.control_port,
        "hb_port": conn.hb_port,
        "key": conn.key,
        "signature_scheme": conn.signature_scheme,
        "kernel_name": conn.kernel_name,
    });
    std::fs::write(&path, serde_json::to_vec_pretty(&val)?)?;
    Ok(path)
}

async fn connect_sockets(
    conn: &ConnectionInfo,
) -> Result<(DealerSocket, DealerSocket, SubSocket)> {
    let mut shell = DealerSocket::new();
    let mut control = DealerSocket::new();
    let mut iopub = SubSocket::new();
    iopub
        .subscribe("")
        .await
        .map_err(|e| anyhow!("iopub subscribe: {e}"))?;

    let attempts = 50;
    let delay = Duration::from_millis(100);
    for i in 0..attempts {
        let r1 = shell.connect(&conn.endpoint(conn.shell_port)).await;
        let r2 = control.connect(&conn.endpoint(conn.control_port)).await;
        let r3 = iopub.connect(&conn.endpoint(conn.iopub_port)).await;
        if r1.is_ok() && r2.is_ok() && r3.is_ok() {
            return Ok((shell, control, iopub));
        }
        if i + 1 == attempts {
            return Err(anyhow!(
                "could not connect kernel sockets: shell={:?} control={:?} iopub={:?}",
                r1.err(),
                r2.err(),
                r3.err()
            ));
        }
        tokio::time::sleep(delay).await;
    }
    unreachable!()
}

async fn socket_owner(
    mut sock: DealerSocket,
    mut out_rx: mpsc::UnboundedReceiver<ZmqMessage>,
    key: Vec<u8>,
    tx: mpsc::UnboundedSender<KernelEvent>,
    label: &'static str,
    pending: Option<Arc<DashMap<String, oneshot::Sender<Value>>>>,
) {
    loop {
        tokio::select! {
            biased;
            out = out_rx.recv() => {
                match out {
                    Some(zmsg) => {
                        if let Err(e) = sock.send(zmsg).await {
                            tracing::warn!("{label} send: {e}");
                        }
                    }
                    None => {
                        tracing::info!("{label} outgoing channel closed; owner exit");
                        return;
                    }
                }
            }
            recv = sock.recv() => {
                match recv {
                    Ok(zmsg) => {
                        let frames = zmq_to_frames(zmsg);
                        match Message::from_frames(frames, &key) {
                            Ok(reply) => {
                                let parent = reply
                                    .parent_header
                                    .get("msg_id")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s.to_string());
                                if let (Some(map), Some(pid)) = (pending.as_ref(), parent.as_ref()) {
                                    if let Some((_, sender)) = map.remove(pid) {
                                        let _ = sender.send(reply.content);
                                        continue;
                                    }
                                }
                                let status = reply
                                    .content
                                    .get("status")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("unknown")
                                    .to_string();
                                let exec_count = reply
                                    .content
                                    .get("execution_count")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(0);
                                if reply.header.msg_type == "kernel_info_reply" {
                                    let _ = tx.send(KernelEvent::KernelInfo {
                                        parent_msg_id: parent,
                                        info: reply.content,
                                    });
                                } else {
                                    let _ = tx.send(KernelEvent::ExecuteReply {
                                        parent_msg_id: parent,
                                        status,
                                        execution_count: exec_count,
                                    });
                                }
                            }
                            Err(e) => tracing::warn!("{label} reply parse: {e}"),
                        }
                    }
                    Err(e) => {
                        tracing::warn!("{label} recv error: {e}");
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                }
            }
        }
    }
}

async fn iopub_loop(mut sock: SubSocket, key: Vec<u8>, tx: mpsc::UnboundedSender<KernelEvent>) {
    loop {
        match sock.recv().await {
            Ok(zmsg) => {
                let frames = zmq_to_frames(zmsg);
                match Message::from_frames(frames, &key) {
                    Ok(msg) => {
                        if let Some(ev) = iopub_to_event(&msg) {
                            if tx.send(ev).is_err() {
                                tracing::info!("iopub event channel closed; loop exit");
                                return;
                            }
                        }
                    }
                    Err(e) => tracing::warn!("iopub parse: {e}"),
                }
            }
            Err(e) => {
                tracing::warn!("iopub recv: {e}");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}

fn iopub_to_event(msg: &Message) -> Option<KernelEvent> {
    let parent = msg
        .parent_header
        .get("msg_id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let msg_id = msg.header.msg_id.clone();
    let c = &msg.content;
    match msg.header.msg_type.as_str() {
        "stream" => Some(KernelEvent::Stream {
            msg_id,
            parent_msg_id: parent,
            name: c
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("stdout")
                .to_string(),
            text: c
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
        }),
        "display_data" => Some(KernelEvent::DisplayData {
            msg_id,
            parent_msg_id: parent,
            data: c.get("data").cloned().unwrap_or(json!({})),
            metadata: c.get("metadata").cloned().unwrap_or(json!({})),
            transient: c.get("transient").cloned().unwrap_or(json!({})),
        }),
        "update_display_data" => Some(KernelEvent::UpdateDisplayData {
            msg_id,
            parent_msg_id: parent,
            data: c.get("data").cloned().unwrap_or(json!({})),
            metadata: c.get("metadata").cloned().unwrap_or(json!({})),
            transient: c.get("transient").cloned().unwrap_or(json!({})),
        }),
        "execute_result" => Some(KernelEvent::ExecuteResult {
            msg_id,
            parent_msg_id: parent,
            execution_count: c
                .get("execution_count")
                .and_then(|v| v.as_u64())
                .unwrap_or(0),
            data: c.get("data").cloned().unwrap_or(json!({})),
            metadata: c.get("metadata").cloned().unwrap_or(json!({})),
        }),
        "error" => Some(KernelEvent::Error {
            msg_id,
            parent_msg_id: parent,
            ename: c
                .get("ename")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            evalue: c
                .get("evalue")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            traceback: c
                .get("traceback")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|t| t.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default(),
        }),
        "status" => Some(KernelEvent::Status {
            execution_state: c
                .get("execution_state")
                .and_then(|v| v.as_str())
                .unwrap_or("idle")
                .to_string(),
            parent_msg_id: parent,
        }),
        "execute_input" => Some(KernelEvent::ExecuteInput {
            parent_msg_id: parent,
            execution_count: c
                .get("execution_count")
                .and_then(|v| v.as_u64())
                .unwrap_or(0),
            code: c
                .get("code")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
        }),
        "clear_output" => Some(KernelEvent::ClearOutput {
            parent_msg_id: parent,
            wait: c.get("wait").and_then(|v| v.as_bool()).unwrap_or(false),
        }),
        _ => None,
    }
}

fn frames_to_zmq(frames: Vec<Bytes>) -> ZmqMessage {
    let mut iter = frames.into_iter();
    let first = iter.next().unwrap_or_default();
    let mut zmsg = ZmqMessage::from(first);
    for f in iter {
        zmsg.push_back(f);
    }
    zmsg
}

fn zmq_to_frames(zmsg: ZmqMessage) -> Vec<Bytes> {
    zmsg.into_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_bootstrap_line_valid() {
        let line = "JOVIAN_CONN /tmp/jovian-kernel-abc.json 51001 51002 51003 51004 51005";
        let (path, ports) = parse_bootstrap_line(line).expect("should parse");
        assert_eq!(path, "/tmp/jovian-kernel-abc.json");
        assert_eq!(ports, [51001, 51002, 51003, 51004, 51005]);
    }

    #[test]
    fn parse_bootstrap_line_ignores_other_lines_and_rejects_malformed() {
        assert!(parse_bootstrap_line("some unrelated stdout").is_none());
        assert!(parse_bootstrap_line("JOVIAN_CONN /tmp/x.json 1 2 3").is_none()); // too few ports
        assert!(parse_bootstrap_line("JOVIAN_CONN /tmp/x.json a b c d e").is_none()); // non-numeric
        assert!(parse_bootstrap_line("").is_none());
    }

    #[test]
    fn forward_args_maps_all_five_ports() {
        let local = [10001u16, 10002, 10003, 10004, 10005];
        let remote = [20001u16, 20002, 20003, 20004, 20005];
        let args = forward_args(&local, &remote);
        assert_eq!(args.len(), 10);
        for i in 0..5 {
            assert_eq!(args[i * 2], "-L");
            assert_eq!(
                args[i * 2 + 1],
                format!("127.0.0.1:{}:127.0.0.1:{}", local[i], remote[i])
            );
        }
    }

    #[test]
    fn shell_quote_escapes_single_quotes() {
        assert_eq!(shell_quote("/home/u/proj"), "'/home/u/proj'");
        assert_eq!(shell_quote("a'b"), r"'a'\''b'");
    }

    #[test]
    fn bootstrap_script_embeds_key_and_sentinel() {
        let s = bootstrap_script("KEY-123");
        assert!(s.contains("\"key\": \"KEY-123\""));
        assert!(s.contains("JOVIAN_CONN"));
        assert!(s.contains("tempfile.mkstemp"));
    }
}
