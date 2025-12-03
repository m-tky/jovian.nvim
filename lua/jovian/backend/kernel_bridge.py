import sys
import json
import base64
import os
import queue
import threading
import time
import re
from jupyter_client.manager import KernelManager

# --- Protocol Utils (Copied/Adapted from protocol.py) ---
def send_json(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

# --- Kernel Bridge ---
class KernelBridge:
    def __init__(self):
        self.km = KernelManager(kernel_name="python3")
        self.kc = None
        self.running = False
        self.msg_queue = queue.Queue()
        self.execution_queue = queue.Queue()
        self.current_cell_id = None
        self.current_msg_id = None # Reset state
        self.var_msg_id = None
        self.output_counter = 0
        self.save_dir = None

    def start(self):
        self.km.start_kernel()
        self.kc = self.km.client()
        self.kc.start_channels()
        try:
            self.kc.wait_for_ready(timeout=10)
        except RuntimeError:
            send_json({"type": "error", "msg": "Failed to start kernel"})
            return

        self.running = True
        
        # Start a thread to poll IOPub messages
        self.iopub_thread = threading.Thread(target=self._poll_iopub, daemon=True)
        self.iopub_thread.start()

    def stop(self):
        self.running = False
        if self.kc:
            self.kc.stop_channels()
        if self.km:
            self.km.shutdown_kernel()

    def _poll_iopub(self):
        while self.running:
            try:
                msg = self.kc.get_iopub_msg(timeout=0.1)
                self._handle_iopub_msg(msg)
            except queue.Empty:
                continue
            except Exception as e:
                # send_json({"type": "stream", "text": f"DEBUG: IOPub Error: {str(e)}\n", "stream": "stderr"})
                pass

    def _handle_iopub_msg(self, msg):
        msg_type = msg['header']['msg_type']
        content = msg['content']
        parent_id = msg['parent_header'].get('msg_id')
        
        # Only process messages corresponding to the current execution
        if self.current_msg_id and parent_id == self.current_msg_id:
            if msg_type == 'stream':
                text = content['text']
                name = content['name'] # stdout or stderr
                # Forward to Neovim immediately for REPL
                send_json({"type": "stream", "text": text, "stream": name})
                # Queue for Markdown report
                self.msg_queue.put({"type": "text", "content": text})

            elif msg_type == 'execute_result':
                data = content['data']
                if 'text/plain' in data:
                    self.msg_queue.put({"type": "text", "content": data['text/plain'] + "\n"})

            elif msg_type == 'display_data':
                data = content['data']
                if 'application/vnd.jovian.variables+json' in data:
                    # Handle variables list
                    var_data = data['application/vnd.jovian.variables+json']
                    send_json({"type": "variable_list", "variables": var_data["variables"]})
                elif 'application/vnd.jovian.dataframe+json' in data:
                    # Handle dataframe data
                    df_data = data['application/vnd.jovian.dataframe+json']
                    send_json({
                        "type": "dataframe_data", 
                        "name": df_data.get("name"),
                        "columns": df_data.get("columns", []),
                        "index": df_data.get("index", []),
                        "data": df_data.get("data", [])
                    })
                elif 'application/vnd.jovian.peek+json' in data:
                    # Handle peek data
                    peek_data = data['application/vnd.jovian.peek+json']
                    send_json({"type": "peek_data", "data": peek_data})
                elif 'image/png' in data:
                    self.msg_queue.put({"type": "image", "data": data['image/png']})
                elif 'text/plain' in data:
                    self.msg_queue.put({"type": "text", "content": data['text/plain'] + "\n"})

            elif msg_type == 'error':
                # Forward error to REPL? Usually errors are shown in REPL too.
                # Construct a text representation of the error
                error_text = "\n".join(content['traceback'])
                send_json({"type": "stream", "text": error_text + "\n", "stream": "stderr"})
                
                self.msg_queue.put({
                    "type": "error", 
                    "ename": content['ename'], 
                    "evalue": content['evalue'], 
                    "traceback": content['traceback']
                })

            elif msg_type == 'status':
                # send_json({"type": "stream", "text": f"DEBUG: Status {content['execution_state']} for {parent_id}\n", "stream": "stderr"})
                if content['execution_state'] == 'idle':
                    self._finalize_execution()
        
        # Handle messages for get_variables (which has its own msg_id, or we track it?)
        # For now, get_variables uses silent=True and we might want to handle its output if it wasn't silent.
        # But we implemented it using display_data with a special mime type.
        # If get_variables runs, it has a DIFFERENT msg_id.
        # We need to handle that too if we want variables to work while code is running?
        # But we can't run two things at once in one kernel usually.
        # So we can just track "current_msg_id" for whatever we sent last?
        # Or we can have a separate "var_msg_id".
        elif self.var_msg_id and parent_id == self.var_msg_id:
             if msg_type == 'display_data':
                data = content['data']
                if 'application/vnd.jovian.variables+json' in data:
                    var_data = data['application/vnd.jovian.variables+json']
                    send_json({"type": "variable_list", "variables": var_data["variables"]})
                elif 'application/vnd.jovian.dataframe+json' in data:
                    df_data = content['data']['application/vnd.jovian.dataframe+json']
                    send_json({
                        "type": "dataframe_data", 
                        "name": df_data.get("name"),
                        "columns": df_data.get("columns", []),
                        "index": df_data.get("index", []),
                        "data": df_data.get("data", [])
                    })
                elif 'application/vnd.jovian.peek+json' in data:
                    peek_data = content['data']['application/vnd.jovian.peek+json']
                    send_json({"type": "peek_data", "data": peek_data})
             elif msg_type == 'status' and content['execution_state'] == 'idle':
                 self.var_msg_id = None

    def _finalize_execution(self):
        # send_json({"type": "stream", "text": f"DEBUG: Finalizing {self.current_cell_id}\n", "stream": "stderr"})
        if not self.current_cell_id:
            return

        # Process accumulated messages
        output_md_lines = []
        images = {}
        error_info = None
        
        try:
            # Prepare save directory
            save_dir = self.save_dir or os.getcwd()
            os.makedirs(save_dir, exist_ok=True)

            md_filename = f"{self.current_cell_id}.md"
            md_path = os.path.join(save_dir, md_filename)

            while not self.msg_queue.empty():
                item = self.msg_queue.get()
                
                if item["type"] == "text":
                    # Simple markdown wrapping
                    text = item["content"]
                    if text.strip():
                        output_md_lines.append("```text")
                        output_md_lines.append(text.rstrip())
                        output_md_lines.append("```")
                        output_md_lines.append("")
                
                elif item["type"] == "image":
                    # Save image
                    img_filename = f"{self.current_cell_id}_{self.output_counter:02d}.png"
                    img_path = os.path.join(save_dir, img_filename)
                    with open(img_path, "wb") as f:
                        f.write(base64.b64decode(item["data"]))
                    
                    images[img_filename] = item["data"] # Send back base64 for preview if needed (or just path)
                    output_md_lines.append(f"![Result]({img_filename})")
                    output_md_lines.append("")
                    self.output_counter += 1
                    
                    # Notify image saved (optional, for immediate update)
                    send_json({
                        "type": "image_saved",
                        "path": os.path.abspath(img_path),
                        "cell_id": self.current_cell_id
                    })

                elif item["type"] == "error":
                    error_info = {
                        "msg": f"{item['ename']}: {item['evalue']}",
                        "traceback": item['traceback']
                    }
                    # Also add to markdown
                    # Strip ANSI codes for Markdown readability
                    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
                    clean_traceback = [ansi_escape.sub('', line) for line in item['traceback']]
                    
                    output_md_lines.append("### Error")
                    output_md_lines.append("```")
                    output_md_lines.append("\n".join(clean_traceback))
                    output_md_lines.append("```")

            # Write Markdown file
            with open(md_path, "w", encoding="utf-8") as f:
                f.write(f"# Output: {self.current_cell_id}\n\n")
                if not output_md_lines:
                    f.write("*(No output)*\n")
                else:
                    f.write("\n".join(output_md_lines))

            # Send result_ready
            msg = {
                "type": "result_ready",
                "cell_id": self.current_cell_id,
                "file": os.path.abspath(md_path),
                "status": "error" if error_info else "ok",
                "images": images
            }
            if error_info:
                msg["error"] = error_info
                
            send_json(msg)
            # send_json({"type": "stream", "text": f"DEBUG: Sent result_ready for {self.current_cell_id}\n", "stream": "stderr"})
            
        except Exception as e:
            # send_json({"type": "stream", "text": f"DEBUG: Finalize Error: {str(e)}\n", "stream": "stderr"})
            pass
        
        # Reset state
        self.current_cell_id = None
        self.current_msg_id = None 
        self.output_counter = 0
        
        # Check for pending executions
        self._process_next_in_queue()

    def _process_next_in_queue(self):
        if not self.execution_queue.empty():
            next_cmd = self.execution_queue.get()
            # send_json({"type": "stream", "text": f"DEBUG: Dequeuing {next_cmd['cell_id']}\n", "stream": "stderr"})
            self._do_execute(
                next_cmd["code"], 
                next_cmd["cell_id"], 
                next_cmd.get("file_dir"),
                next_cmd.get("cwd")
            )

    def _do_execute(self, code, cell_id, file_dir=None, cwd=None):
        self.current_cell_id = cell_id
        self.save_dir = file_dir
        
        # Switch kernel CWD if provided
        if cwd:
            # Escape backslashes for Windows compatibility if needed, though we are on Linux
            safe_cwd = cwd.replace('\\', '\\\\').replace("'", "\\'")
            change_cwd_code = f"import os; os.chdir('{safe_cwd}')"
            self.kc.execute(change_cwd_code, silent=True)
        
        # Clear queue
        with self.msg_queue.mutex:
            self.msg_queue.queue.clear()
            
        self.current_msg_id = self.kc.execute(code)
        # send_json({"type": "stream", "text": f"DEBUG: Executing {cell_id} (MsgID: {self.current_msg_id})\n", "stream": "stderr"})

    def execute_code(self, code, cell_id, file_dir=None, cwd=None):
        if self.current_cell_id is not None:
            # Busy, queue it
            # send_json({"type": "stream", "text": f"DEBUG: Queuing {cell_id}\n", "stream": "stderr"})
            self.execution_queue.put({
                "code": code, 
                "cell_id": cell_id, 
                "file_dir": file_dir,
                "cwd": cwd
            })
        else:
            self._do_execute(code, cell_id, file_dir, cwd)

    def get_variables(self):
        script = """
import json
import types
from IPython.display import display

def _jovian_get_variables():
    var_list = []
    ns = globals()
    for name, value in list(ns.items()):
        if name.startswith("_") or isinstance(value, (types.ModuleType, types.FunctionType, type)): continue
        if name in ['In', 'Out', 'exit', 'quit', 'get_ipython', '_jovian_get_variables']: continue
        
        type_name = type(value).__name__
        info = str(value)
        info = info.replace("\\n", " ")
        if len(info) > 200: info = info[:197] + "..."

        if hasattr(value, 'shape'):
            shape_str = str(value.shape).replace(" ", "")
            if hasattr(value, 'dtype'):
                info = f"{shape_str} | {value.dtype}"
            else:
                info = f"{shape_str} | {type_name}"
        elif isinstance(value, (list, dict, set, tuple)):
            info = f"len: {len(value)}"
        var_list.append({"name": name, "type": type_name, "info": info})
        
    var_list.sort(key=lambda x: x['name'])
    display({"application/vnd.jovian.variables+json": {"variables": var_list}}, raw=True)

_jovian_get_variables()
"""
        self.var_msg_id = self.kc.execute(script, silent=True)

    def view_dataframe(self, name):
        script = f"""
import pandas as pd
import numpy as np
import json
from IPython.display import display

def _jovian_view_df(name):
    try:
        if name not in globals(): return
        val = globals()[name]
        df = None
        if isinstance(val, pd.DataFrame): df = val
        elif isinstance(val, pd.Series): df = val.to_frame()
        elif isinstance(val, np.ndarray):
            if val.ndim <= 2: df = pd.DataFrame(val)
        
        if df is not None:
            df_view = df.head(100)
            data_json = df_view.to_json(orient='split', date_format='iso')
            parsed = json.loads(data_json)
            # Inject name into the payload
            payload = {{
                "name": name,
                "columns": parsed.get('columns', []),
                "index": parsed.get('index', []),
                "data": parsed.get('data', [])
            }}
            display({{"application/vnd.jovian.dataframe+json": payload}}, raw=True)
    except:
        pass

_jovian_view_df("{name}")
"""
        self.kc.execute(script, silent=True)

    def peek(self, name):
        script = f"""
import sys
from IPython.display import display

def _jovian_peek(name):
    try:
        if name not in globals():
            # Error case
            return
            
        val = globals()[name]
        type_name = type(val).__name__
        
        size_str = "unknown"
        try:
            size = sys.getsizeof(val)
            if size < 1024: size_str = f"{{size}} B"
            elif size < 1024**2: size_str = f"{{size/1024:.1f}} KB"
            else: size_str = f"{{size/1024**2:.1f}} MB"
        except: pass
        
        val_repr = repr(val)
        if len(val_repr) > 500: val_repr = val_repr[:497] + "..."
        
        shape = ""
        if hasattr(val, 'shape'):
            shape = str(val.shape)
            
        result = {{
            "name": name,
            "type": type_name,
            "size": size_str,
            "repr": val_repr,
            "shape": shape
        }}
        display({{"application/vnd.jovian.peek+json": result}}, raw=True)
    except: pass

_jovian_peek("{name}")
"""
        self.kc.execute(script, silent=True)

    def inspect(self, name):
        # Use Jupyter's inspect
        msg_id = self.kc.inspect(name, cursor_pos=len(name))
        # We need to handle the reply. 
        # Since inspect is blocking/async, we can wait for it here in a separate thread or just poll?
        # But we are in the main loop.
        # Actually, kc.inspect returns msg_id. We need to wait for reply on shell_channel.
        # But we are polling iopub in a thread.
        # We can poll shell channel here?
        # WARNING: Blocking here might block the main loop if we are not careful.
        # But inspect is usually fast.
        try:
            reply = self.kc.get_shell_msg(timeout=1)
            if reply['parent_header']['msg_id'] == msg_id:
                 content = reply['content']
                 if content['status'] == 'ok' and content['found']:
                     data = content['data']
                     # Jupyter inspect returns text/plain usually.
                     docstring = data.get('text/plain', 'No info')
                     
                     result = {
                         "name": name,
                         "type": "unknown", 
                         "docstring": docstring,
                         "file": "",
                         "definition": ""
                     }
                     send_json({"type": "inspection_data", "data": result})
        except:
            pass

    def purge_cache(self, valid_ids, file_dir):
        if not file_dir or not os.path.exists(file_dir): return
        
        try:
            valid_set = set(valid_ids)
            for f in os.listdir(file_dir):
                # Files: {id}.md, {id}_{counter}.png
                parts = f.replace('.', '_').split('_')
                if parts[0] not in valid_set:
                    try: os.remove(os.path.join(file_dir, f))
                    except: pass
        except:
            pass

    def remove_cache(self, ids_to_remove, file_dir):
        if not file_dir or not os.path.exists(file_dir): return
        
        try:
            remove_set = set(ids_to_remove)
            for f in os.listdir(file_dir):
                parts = f.replace('.', '_').split('_')
                if parts[0] in remove_set:
                    try: os.remove(os.path.join(file_dir, f))
                    except: pass
        except:
            pass

def main():
    bridge = KernelBridge()
    bridge.start()
    
    send_json({"type": "debug", "msg": "Kernel Bridge Started"})

    while True:
        try:
            line = sys.stdin.readline()
            if not line:
                break
            cmd = json.loads(line)
            
            if cmd.get("command") == "execute":
                bridge.execute_code(
                    cmd["code"],
                    cmd["cell_id"],
                    cmd.get("file_dir"),
                    cmd.get("cwd")
                )
            elif cmd.get("command") == "get_variables":
                bridge.get_variables()
            elif cmd.get("command") == "view_dataframe":
                bridge.view_dataframe(cmd["name"])
            elif cmd.get("command") == "peek":
                bridge.peek(cmd["name"])
            elif cmd.get("command") == "inspect":
                bridge.inspect(cmd["name"])
            elif cmd.get("command") == "purge_cache":
                bridge.purge_cache(cmd["ids"], cmd.get("file_dir"))
            elif cmd.get("command") == "remove_cache":
                bridge.remove_cache(cmd["ids"], cmd.get("file_dir"))
            
        except (json.JSONDecodeError, KeyboardInterrupt):
            pass
            
    bridge.stop()

if __name__ == "__main__":
    main()
