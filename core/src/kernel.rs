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
    ClearOutput {
        parent_msg_id: Option<String>,
        wait: bool,
    },
    KernelInfo {
        parent_msg_id: Option<String>,
        info: Value,
    },
    /// The kernel process exited on its own (segfault, OOM, normal exit, …).
    /// Emitted exactly once, after which the kernel is unusable. The RPC
    /// layer translates this into a `kernel_event` notification with
    /// `kind: "kernel_died"` and tears the session down.
    KernelDied { exit_code: Option<i32> },
}

impl KernelEvent {
    /// The `parent_msg_id` field of the underlying Jupyter message, if the
    /// variant carries one. `None` for variants that are globally scoped
    /// (currently only `KernelDied`).
    pub fn parent_msg_id(&self) -> Option<&str> {
        match self {
            KernelEvent::Stream { parent_msg_id, .. }
            | KernelEvent::DisplayData { parent_msg_id, .. }
            | KernelEvent::ExecuteResult { parent_msg_id, .. }
            | KernelEvent::Error { parent_msg_id, .. }
            | KernelEvent::Status { parent_msg_id, .. }
            | KernelEvent::ExecuteInput { parent_msg_id, .. }
            | KernelEvent::ExecuteReply { parent_msg_id, .. }
            | KernelEvent::ClearOutput { parent_msg_id, .. }
            | KernelEvent::KernelInfo { parent_msg_id, .. } => parent_msg_id.as_deref(),
            KernelEvent::KernelDied { .. } => None,
        }
    }
}

pub struct Kernel {
    spec: KernelSpec,
    conn: ConnectionInfo,
    session: String,
    /// Send () to ask the child-watcher task to kill the child. The task
    /// owns the Child and awaits either this signal or `child.wait()` —
    /// whichever fires first. Replacing the previous `Mutex<Child>` lets
    /// the wait task hold the child indefinitely without serializing
    /// against explicit kills.
    kill_tx: Mutex<Option<oneshot::Sender<()>>>,
    shell_tx: mpsc::UnboundedSender<ZmqMessage>,
    control_tx: mpsc::UnboundedSender<ZmqMessage>,
    /// All long-running tasks tied to this kernel's lifetime (iopub
    /// loop + shell/control socket owners). Aborted en masse in `kill()`
    /// so a dropped Kernel doesn't leave a socket loop blocked on
    /// `sock.recv()` forever (with the pure-rust zeromq impl, recv on a
    /// dead socket can hang).
    task_handles: Mutex<Vec<tokio::task::JoinHandle<()>>>,
    events: Mutex<Option<mpsc::Receiver<KernelEvent>>>,
    pending: Arc<DashMap<String, oneshot::Sender<Value>>>,
    /// Path to the connection file on disk. Deleted in `kill()`; without
    /// this, `/tmp/jovian/kernel-<uuid>.json` accumulates over the life
    /// of a Neovim session.
    conn_file: Option<PathBuf>,
}

impl Kernel {
    pub async fn launch(
        spec: KernelSpec,
        cwd: Option<PathBuf>,
        mplbackend: Option<&str>,
    ) -> Result<Self> {
        let conn = ConnectionInfo::new_localhost(&spec.name)?;
        let conn_path = write_connection_file(&conn)?;
        let conn_file = Some(conn_path.clone());
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
        if let Some(backend) = mplbackend.filter(|b| !b.is_empty()) {
            cmd.env("MPLBACKEND", backend);
        }
        if let Some(d) = cwd {
            cmd.current_dir(d);
        }
        cmd.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);

        let child = cmd
            .spawn()
            .with_context(|| format!("spawning {:?}", argv))?;
        Self::from_child_and_conn(spec, conn, child, conn_file).await
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
    pub async fn launch_remote(
        host: &str,
        python: &str,
        cwd: Option<&str>,
        mplbackend: Option<&str>,
    ) -> Result<Self> {
        use tokio::io::AsyncWriteExt;

        // Reject a destination that ssh would parse as an option flag
        // (argument injection, e.g. host = "-oProxyCommand=..."). ssh has no
        // portable `--` end-of-options before the destination, so guard here.
        if host.starts_with('-') {
            return Err(anyhow!(
                "invalid ssh host '{host}': must not start with '-'"
            ));
        }

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
        let (conn_path, remote_ports) =
            stdout
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

        let backend_env = mplbackend
            .filter(|b| !b.is_empty())
            .map(|b| format!("MPLBACKEND={} ", shell_quote(b)))
            .unwrap_or_default();
        let exec_prefix = format!("{}exec ", backend_env);
        let remote_cmd = match cwd {
            Some(d) if !d.is_empty() => format!(
                "cd {} && {}{} -m ipykernel_launcher -f {}",
                shell_quote(d),
                exec_prefix,
                shell_quote(python),
                shell_quote(&conn_path)
            ),
            _ => format!(
                "{}{} -m ipykernel_launcher -f {}",
                exec_prefix,
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
        // No local conn file to clean up: the remote wrote its own
        // tempfile via the bootstrap script, which we can't delete from
        // here without another ssh round-trip. The OS will reap it.
        Self::from_child_and_conn(remote_spec(host), conn, child, None).await
    }

    /// Wire up ZMQ sockets, channels, and the iopub loop around an
    /// already-spawned child process and a *local* connection. For remote
    /// kernels the connection points at SSH-forwarded localhost ports, so this
    /// tail is identical for local and remote.
    async fn from_child_and_conn(
        spec: KernelSpec,
        conn: ConnectionInfo,
        mut child: Child,
        conn_file: Option<PathBuf>,
    ) -> Result<Self> {
        let session = Uuid::new_v4().to_string();

        let (shell, control, iopub) = connect_sockets(&conn).await?;

        // Bounded events channel: a chatty cell (10 k-line print loop) used
        // to push events at unlimited rate; if Lua was slow to drain (e.g.
        // mid-redraw), they piled up unboundedly in memory. 1024 is enough
        // to absorb realistic bursts while still applying backpressure
        // upstream — when full, iopub_loop awaits on send(), which in turn
        // backpressures the ZMQ socket recv buffer back to the kernel.
        let (tx, rx) = mpsc::channel::<KernelEvent>(1024);
        let key = conn.key.as_bytes().to_vec();
        let iopub_handle: tokio::task::JoinHandle<()> =
            tokio::spawn(iopub_loop(iopub, key.clone(), tx.clone()));

        // shell_tx/control_tx stay unbounded: traffic is bounded by user
        // input rate (one execute per :JovianRun), not the kernel.
        let (shell_tx, shell_rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let (control_tx, control_rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let pending: Arc<DashMap<String, oneshot::Sender<Value>>> = Arc::new(DashMap::new());
        let shell_handle = tokio::spawn(socket_owner(
            shell,
            shell_rx,
            key.clone(),
            tx.clone(),
            "shell",
            Some(pending.clone()),
        ));
        let control_handle = tokio::spawn(socket_owner(
            control,
            control_rx,
            key.clone(),
            tx.clone(),
            "control",
            None,
        ));

        // Drain stdout/stderr to tracing so a chatty kernel doesn't fill the
        // 64 KB pipe buffer and block its own writes. We saw this in practice
        // with ipykernel deprecation warnings on stderr.
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(drain_to_log(stderr, "stderr"));
        }
        if let Some(stdout) = child.stdout.take() {
            tokio::spawn(drain_to_log(stdout, "stdout"));
        }

        // Child-watcher: owns the Child, awaits either an explicit kill or
        // the child exiting on its own. The latter emits KernelDied so the
        // Lua side can react ("kernel crashed — restart?").
        let (kill_tx, kill_rx) = oneshot::channel::<()>();
        let died_tx = tx.clone();
        tokio::spawn(async move {
            tokio::select! {
                biased;
                _ = kill_rx => {
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                }
                result = child.wait() => {
                    let code = result.ok().and_then(|s| s.code());
                    let _ = died_tx.send(KernelEvent::KernelDied { exit_code: code }).await;
                }
            }
        });

        // Handshake: send kernel_info_request and wait for the reply before
        // returning. This proves the kernel is bound to the ZMQ sockets and
        // speaks our wire-protocol version before any execute can race the
        // bind. 5 s is enough for a cold-start interpreter + ipykernel.
        handshake_kernel_info(&shell_tx, &pending, &session, &key).await?;

        Ok(Self {
            spec,
            conn,
            session,
            kill_tx: Mutex::new(Some(kill_tx)),
            shell_tx,
            control_tx,
            task_handles: Mutex::new(vec![iopub_handle, shell_handle, control_handle]),
            events: Mutex::new(Some(rx)),
            pending,
            conn_file,
        })
    }

    pub fn spec(&self) -> &KernelSpec {
        &self.spec
    }

    pub async fn take_events(&self) -> Option<mpsc::Receiver<KernelEvent>> {
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
        // 2s is plenty for complete/inspect against an idle kernel. A busy
        // kernel processes shell messages in order, so the request queues
        // behind the running cell and times out — expected, not a dead
        // kernel, which the error wording makes explicit.
        let timeout = Duration::from_millis(2000);
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

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(_)) => {
                self.pending.remove(&msg_id);
                Err(anyhow!("{msg_type} reply dropped"))
            }
            Err(_) => {
                self.pending.remove(&msg_id);
                Err(anyhow!(
                    "{msg_type} timed out after {}ms (kernel may be busy)",
                    timeout.as_millis()
                ))
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
        // Abort every long-running task. Without aborting the shell /
        // control owners, recv() on a dead socket can hang indefinitely
        // with the pure-rust zeromq impl, leaking tasks across kernel
        // restarts.
        for h in self.task_handles.lock().await.drain(..) {
            h.abort();
        }
        if let Some(s) = self.kill_tx.lock().await.take() {
            // Send error is fine: the child-watcher may have already
            // exited because the kernel died first.
            let _ = s.send(());
        }
        // Drop the on-disk connection file. /tmp/jovian/kernel-*.json
        // would otherwise accumulate one per kernel start.
        if let Some(p) = &self.conn_file {
            let _ = std::fs::remove_file(p);
        }
        Ok(())
    }
}

async fn drain_to_log<R>(reader: R, label: &'static str)
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    use tokio::io::{AsyncBufReadExt, BufReader};
    let mut lines = BufReader::new(reader).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => tracing::warn!(kernel = label, "{line}"),
            Ok(None) => return,
            Err(e) => {
                tracing::warn!(kernel = label, "read error: {e}");
                return;
            }
        }
    }
}

async fn handshake_kernel_info(
    shell_tx: &mpsc::UnboundedSender<ZmqMessage>,
    pending: &DashMap<String, oneshot::Sender<Value>>,
    session_id: &str,
    key: &[u8],
) -> Result<()> {
    let msg_id = Uuid::new_v4().to_string();
    let (tx, rx) = oneshot::channel();
    pending.insert(msg_id.clone(), tx);

    let mut msg = Message::new("kernel_info_request", session_id.to_string(), json!({}));
    msg.header.msg_id = msg_id.clone();
    let frames = msg.to_frames(key)?;
    if shell_tx.send(frames_to_zmq(frames)).is_err() {
        pending.remove(&msg_id);
        return Err(anyhow!("shell channel closed during handshake"));
    }

    match tokio::time::timeout(Duration::from_millis(5000), rx).await {
        Ok(Ok(reply)) => {
            // Surface the kernel's protocol version into the log; later we
            // can refuse to start if it doesn't match our 5.4 expectations.
            if let Some(v) = reply.get("protocol_version").and_then(|v| v.as_str()) {
                tracing::info!(protocol_version = v, "kernel handshake OK");
            }
            Ok(())
        }
        Ok(Err(_)) => {
            pending.remove(&msg_id);
            Err(anyhow!("kernel_info_reply dropped"))
        }
        Err(_) => {
            pending.remove(&msg_id);
            Err(anyhow!(
                "kernel_info_request timed out after 5 s — kernel did not bind"
            ))
        }
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

async fn connect_sockets(conn: &ConnectionInfo) -> Result<(DealerSocket, DealerSocket, SubSocket)> {
    let mut shell = DealerSocket::new();
    let mut control = DealerSocket::new();
    let mut iopub = SubSocket::new();
    iopub
        .subscribe("")
        .await
        .map_err(|e| anyhow!("iopub subscribe: {e}"))?;

    let attempts = 50;
    let delay = Duration::from_millis(100);
    // Track per-socket success so a partial connect (e.g. shell up, iopub
    // not yet) doesn't re-issue connect() on already-connected sockets —
    // the pure-rust zeromq impl doesn't dedupe endpoints, so a duplicate
    // SUB connect can double up iopub delivery (outputs shown twice).
    let (mut ok_shell, mut ok_control, mut ok_iopub) = (false, false, false);
    let (mut e1, mut e2, mut e3) = (None, None, None);
    for i in 0..attempts {
        if !ok_shell {
            match shell.connect(&conn.endpoint(conn.shell_port)).await {
                Ok(()) => ok_shell = true,
                Err(e) => e1 = Some(e),
            }
        }
        if !ok_control {
            match control.connect(&conn.endpoint(conn.control_port)).await {
                Ok(()) => ok_control = true,
                Err(e) => e2 = Some(e),
            }
        }
        if !ok_iopub {
            match iopub.connect(&conn.endpoint(conn.iopub_port)).await {
                Ok(()) => ok_iopub = true,
                Err(e) => e3 = Some(e),
            }
        }
        if ok_shell && ok_control && ok_iopub {
            return Ok((shell, control, iopub));
        }
        if i + 1 == attempts {
            return Err(anyhow!(
                "could not connect kernel sockets: shell={:?} control={:?} iopub={:?}",
                e1,
                e2,
                e3
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
    tx: mpsc::Sender<KernelEvent>,
    label: &'static str,
    pending: Option<Arc<DashMap<String, oneshot::Sender<Value>>>>,
) {
    // Exponential backoff for socket recv errors. Without a cap we used
    // to retry every 50 ms forever — fine for transient hiccups, but a
    // dead socket spammed warn! at 20 lines/s.
    let mut recv_backoff_ms: u64 = 50;
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
                        recv_backoff_ms = 50;
                        match Message::from_frames(zmsg.into_vec(), &key) {
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
                                let ev = if reply.header.msg_type == "kernel_info_reply" {
                                    KernelEvent::KernelInfo {
                                        parent_msg_id: parent,
                                        info: reply.content,
                                    }
                                } else {
                                    KernelEvent::ExecuteReply {
                                        parent_msg_id: parent,
                                        status,
                                        execution_count: exec_count,
                                    }
                                };
                                if tx.send(ev).await.is_err() {
                                    tracing::info!("{label} event channel closed; owner exit");
                                    return;
                                }
                            }
                            Err(e) => tracing::warn!("{label} reply parse: {e}"),
                        }
                    }
                    Err(e) => {
                        tracing::warn!("{label} recv error: {e} (backoff {recv_backoff_ms} ms)");
                        tokio::time::sleep(Duration::from_millis(recv_backoff_ms)).await;
                        // Exponential up to 5 s cap; if errors persist past
                        // ~10 retries (~10 s cumulative), assume the socket
                        // is unrecoverable and exit.
                        recv_backoff_ms = (recv_backoff_ms * 2).min(5000);
                        if recv_backoff_ms >= 5000 {
                            tracing::error!("{label} recv keeps failing; owner exit");
                            return;
                        }
                    }
                }
            }
        }
    }
}

async fn iopub_loop(mut sock: SubSocket, key: Vec<u8>, tx: mpsc::Sender<KernelEvent>) {
    let mut backoff_ms: u64 = 50;
    loop {
        match sock.recv().await {
            Ok(zmsg) => {
                backoff_ms = 50;
                match Message::from_frames(zmsg.into_vec(), &key) {
                    Ok(msg) => {
                        if let Some(ev) = iopub_to_event(&msg) {
                            if tx.send(ev).await.is_err() {
                                tracing::info!("iopub event channel closed; loop exit");
                                return;
                            }
                        }
                    }
                    Err(e) => tracing::warn!("iopub parse: {e}"),
                }
            }
            Err(e) => {
                tracing::warn!("iopub recv: {e} (backoff {backoff_ms} ms)");
                tokio::time::sleep(Duration::from_millis(backoff_ms)).await;
                backoff_ms = (backoff_ms * 2).min(5000);
                if backoff_ms >= 5000 {
                    tracing::error!("iopub recv keeps failing; loop exit");
                    // The events channel won't close on its own (the shell/
                    // control owners hold tx clones), so cells would hang in
                    // "Running..." forever. Signal the frontend explicitly.
                    let _ = tx.send(KernelEvent::KernelDied { exit_code: None }).await;
                    return;
                }
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
        }),
        // update_display_data is intentionally not routed: no Lua renderer
        // handles it (the inline / preview surfaces re-read the sidecar on
        // every cell_event, so an update_display_data is observable as a
        // display_data replacement during the next render). Dropping it
        // here avoids a no-op event payload + KernelEvent variant.
        "update_display_data" => None,
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
