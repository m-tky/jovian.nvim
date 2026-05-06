import argparse
import atexit
import base64
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time

try:
    from jupyter_client.blocking.client import BlockingKernelClient
    from jupyter_client.manager import KernelManager
    from jupyter_client.session import Session
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
        self.msg_queue = queue.Queue()
        self.msg_id_map = {}  # Map msg_id to cell_id
        self.save_dir = None

    def start(self):
        if self.connection_file:
            self.kc = BlockingKernelClient(connection_file=self.connection_file)
            self.kc.load_connection_file()
            self.kc.start_channels()
        else:
            self.km = KernelManager(kernel_cmd=[sys.executable, "-m", "ipykernel_launcher", "-f", "{connection_file}"])
            self.km.start_kernel()
            self.kc = self.km.client()
            self.kc.start_channels()

        try:
            self.kc.wait_for_ready(timeout=10)
        except RuntimeError:
            send_json({"type": "error", "msg": "Failed to connect to kernel"})
            return

        self.running = True
        self.iopub_thread = threading.Thread(target=self._poll_iopub, daemon=True)
        self.iopub_thread.start()
        send_json({"type": "ready"})

    def execute_code(self, code, cell_id, file_dir=None, cwd=None):
        if cwd:
            try: os.chdir(cwd)
            except Exception: pass
        
        send_json({"type": "execution_started", "cell_id": cell_id, "code": code})
        msg_id = self.kc.execute(code)
        self.msg_id_map[msg_id] = cell_id

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
        msg_type = msg["header"]["msg_type"]
        content = msg["content"]
        parent_id = msg["parent_header"].get("msg_id")

        if not parent_id or parent_id not in self.msg_id_map:
            if msg_type == "status":
                send_json({"type": "status", "execution_state": content.get("execution_state")})
            return

        cell_id = self.msg_id_map[parent_id]

        if msg_type == "stream":
            send_json({"type": "stream", "text": content["text"], "stream": content["name"], "cell_id": cell_id})
        elif msg_type == "execute_result":
            data = content["data"]
            if "text/plain" in data:
                send_json({"type": "stream", "text": data["text/plain"] + "\n", "stream": "stdout", "cell_id": cell_id})
        elif msg_type == "error":
            error_text = "\n".join(content["traceback"])
            send_json({
                "type": "result_ready",
                "cell_id": cell_id,
                "status": "error",
                "error": {"ename": content["ename"], "evalue": content["evalue"], "traceback": content["traceback"]}
            })
        elif msg_type == "status":
            if content.get("execution_state") == "idle":
                send_json({"type": "result_ready", "cell_id": cell_id, "status": "ok"})
                if parent_id in self.msg_id_map:
                    del self.msg_id_map[parent_id]

    def stop(self):
        self.running = False
        if self.kc: self.kc.stop_channels()
        if self.km and self.km.is_alive(): self.km.shutdown_kernel(now=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--connection-file", help="Path to Jupyter connection file")
    args = parser.parse_args()
    bridge = KernelBridge(connection_file=args.connection_file)
    bridge.start()

    while True:
        try:
            line = sys.stdin.readline()
            if not line: break
            for l in line.split("\n"):
                if not l.strip(): continue
                cmd = json.loads(l)
                if cmd.get("command") == "execute":
                    bridge.execute_code(cmd["code"], cmd["cell_id"], cmd.get("file_dir"), cmd.get("cwd"))
        except Exception:
            break
    bridge.stop()

if __name__ == "__main__":
    main()
