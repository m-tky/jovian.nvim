import argparse
import json
import os
import queue
import re
import signal
import sys
import threading

_ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

try:
    from jupyter_client.blocking.client import BlockingKernelClient
    from jupyter_client.manager import KernelManager
except ImportError as e:
    sys.stderr.write(f"[Jovian] Critical Import Error: {e}\n")
    sys.exit(1)

_send_lock = threading.Lock()

def send_json(msg):
    with _send_lock:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()

class KernelBridge:
    def __init__(self, connection_file=None):
        self.connection_file = connection_file
        self.km = None
        self.kc = None
        self.running = False
        self.msg_id_map = {}

    def start(self):
        signal.signal(signal.SIGINT, lambda s, f: self.km.interrupt_kernel() if self.km else self.kc.interrupt())

        if self.connection_file:
            self.kc = BlockingKernelClient(connection_file=self.connection_file)
            self.kc.load_connection_file()
            self.kc.start_channels()
        else:
            self.km = KernelManager(kernel_cmd=[sys.executable, "-m", "ipykernel_launcher", "-f", "{connection_file}"])
            self.km.start_kernel()
            self.kc = self.km.client()
            self.kc.start_channels()

        self.kc.wait_for_ready(timeout=10)
        self.running = True
        threading.Thread(target=self._poll_iopub, daemon=True).start()
        send_json({"type": "ready"})

    def execute_code(self, code, cell_id, cwd=None):
        if cwd:
            try:
                os.chdir(cwd)
            except Exception:
                pass
        msg_id = self.kc.execute(code)
        self.msg_id_map[msg_id] = {"type": "execute", "cell_id": cell_id, "outputs": []}
        send_json({"type": "execution_started", "cell_id": cell_id, "code": code, "msg_id": msg_id})

    def run_command(self, cmd):
        cmd_type = cmd.get("command")
        name = cmd.get("name")
        script = ""
        if cmd_type == "get_variables":
            offset = cmd.get("offset", 0)
            limit = cmd.get("limit", 100)
            script = f"""
import json, types
from IPython import get_ipython
from IPython.display import display
def _jovian_vars():
    try:
        shell = get_ipython()
        ns = shell.user_ns if shell else globals()
        keys = [k for k in ns.keys() if not k.startswith("_")]
        keys.sort()

        filtered_keys = []
        for k in keys:
            val = ns[k]
            if isinstance(val, (types.ModuleType, types.FunctionType, type)): continue
            filtered_keys.append(k)

        total_vars = len(filtered_keys)
        page_keys = filtered_keys[{offset}:{offset} + {limit}]

        var_list = []
        for name in page_keys:
            val = ns[name]
            type_name = type(val).__name__
            val_repr = repr(val).replace("\\n", " ")
            info = (val_repr[:97] + "...") if len(val_repr) > 100 else val_repr
            var_list.append({{"name": name, "type": type_name, "info": info}})
        display({{"application/vnd.jovian.variables+json": {{"variables": var_list, "total_vars": total_vars, "offset": {offset}, "limit": {limit}}}}}, raw=True)
    except Exception: pass
_jovian_vars()
"""
        elif cmd_type == "view_dataframe":
            offset = cmd.get("offset", 0)
            limit = cmd.get("limit", 50)
            script = f"""
from IPython import get_ipython; from IPython.display import display
shell = get_ipython(); ns = shell.user_ns if shell else globals()
if "{name}" in ns:
    df = ns["{name}"]
    if hasattr(df, "columns"):
        total_rows = len(df)
        data = {{
            "name": "{name}",
            "columns": list(df.columns),
            "index": [str(i) for i in df.index[{offset}:{offset} + {limit}]],
            "data": df.iloc[{offset}:{offset} + {limit}].values.tolist(),
            "total_rows": total_rows,
            "offset": {offset},
            "limit": {limit}
        }}
        display({{"application/vnd.jovian.dataframe+json": data}}, raw=True)
"""
        if cmd_type == "complete":
            code = cmd.get("code", "")
            cursor_pos = cmd.get("cursor_pos", 0)
            script = f"""
from IPython import get_ipython
from IPython.display import display
shell = get_ipython()
if shell:
    matches = shell.Completer.complete(line_buffer='''{code}''', cursor_pos={cursor_pos})[1]
    display({{"application/vnd.jovian.complete+json": {{"matches": matches}}}}, raw=True)
"""
        if script:
            # For execute commands, we must ensure the mapping is ready before IOPUB messages arrive.
            # While execute() returns the msg_id, the kernel might be so fast that IOPUB
            # messages arrive before the next line of Python is executed here.
            msg_id = self.kc.execute(script, silent=False, store_history=False)
            self.msg_id_map[msg_id] = {"type": cmd_type}

    def _poll_iopub(self):
        while self.running:
            try:
                msg = self.kc.get_iopub_msg(timeout=0.1)
                self._handle_iopub_msg(msg)
            except queue.Empty:
                continue
            except Exception:
                pass

    def _handle_iopub_msg(self, msg):
        msg_type, content = msg["header"]["msg_type"], msg["content"]
        parent_id = msg["parent_header"].get("msg_id")

        if not parent_id or parent_id not in self.msg_id_map:
            if msg_type == "status":
                send_json({"type": "status", "execution_state": content.get("execution_state")})
            return

        ctx = self.msg_id_map[parent_id]
        cid = ctx.get("cell_id")

        if msg_type == "stream":
            send_json({
                "type": "stream",
                "text": content["text"],
                "stream": content["name"],
                "cell_id": cid
            })
            if cid:
                ctx["outputs"].append(content["text"])
        elif msg_type in ("display_data", "execute_result"):
            data = content.get("data", {})
            if "application/vnd.jovian.variables+json" in data:
                send_json({**data["application/vnd.jovian.variables+json"], "type": "variable_list"})
            elif "application/vnd.jovian.dataframe+json" in data:
                send_json({**data["application/vnd.jovian.dataframe+json"], "type": "dataframe_data"})
            elif "application/vnd.jovian.complete+json" in data:
                send_json({"type": "complete_data", "matches": data["application/vnd.jovian.complete+json"]["matches"]})
            elif "image/png" in data:
                send_json({"type": "image", "data": data["image/png"], "cell_id": cid})
            elif "text/plain" in data:
                send_json({"type": "stream", "text": data["text/plain"] + "\\n", "stream": "stdout", "cell_id": cid})
                if cid:
                    ctx["outputs"].append(data["text/plain"])
        elif msg_type == "error":
            if "traceback" in content:
                error_text = "".join(content["traceback"])
                send_json({
                    "type": "stream", "text": error_text, "stream": "stderr", "cell_id": cid
                })
                if cid:
                    plain = _ANSI_ESCAPE.sub("", error_text)
                    ctx["outputs"].append("\n### Error\n```\n" + plain + "\n```")
            send_json({
                "type": "result_ready", "cell_id": cid, "status": "error", "error": content
            })
        elif msg_type == "status" and content.get("execution_state") == "idle":
            if ctx.get("type") == "execute":
                md = "".join(ctx["outputs"]) if ctx["outputs"] else "*No output*"
                send_json({
                    "type": "result_ready",
                    "cell_id": cid,
                    "status": "ok",
                    "content_md": md
                })
            del self.msg_id_map[parent_id]

    def stop(self):
        self.running = False
        if self.kc:
            self.kc.stop_channels()
        if self.km and self.km.is_alive():
            self.km.shutdown_kernel(now=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--connection-file", help="Path to Jupyter connection file")
    args = parser.parse_args()
    bridge = KernelBridge(connection_file=args.connection_file)
    bridge.start()
    while True:
        try:
            line = sys.stdin.readline()
            if not line:
                break
            cmd = json.loads(line)
            c = cmd.get("command")
            if c == "execute":
                bridge.execute_code(cmd["code"], cmd["cell_id"], cmd.get("cwd"))
            elif c in ("get_variables", "view_dataframe"):
                bridge.run_command(cmd)
        except (KeyboardInterrupt, Exception):
            continue
    bridge.stop()

if __name__ == "__main__":
    main()
