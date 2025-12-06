import sys
import json
import base64
import os
import queue
import threading
import time
import re
import argparse

try:
    from jupyter_client.manager import KernelManager
    from jupyter_client.blocking.client import BlockingKernelClient
except ImportError as e:
    # Handle environment issues (common on NixOS/Linux with missing libs)
    sys.stderr.write(f"[Jovian] Critical Import Error: {e}\n")
    if "libstdc++.so.6" in str(e):
        sys.stderr.write("[Jovian] Tip: You are missing 'libstdc++.so.6'. If on NixOS, use 'nix-shell' or set LD_LIBRARY_PATH.\n")
    sys.exit(1)

# --- Protocol Utils ---
def send_json(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

def process_console_output(text):
    # Simple terminal emulator for \r and \n to handle progress bars (tqdm)
    lines = [[]]
    row = 0
    col = 0
    
    for char in text:
        if char == '\n':
            row += 1
            col = 0
            if len(lines) <= row:
                lines.append([])
        elif char == '\r':
            col = 0
        elif char == '\b':
            col = max(0, col - 1)
        else:
            # Ensure line exists (handled by \n logic, but first line is pre-created)
            current_line = lines[row]
            # Pad if needed
            while len(current_line) < col:
                current_line.append(' ')
            
            if len(current_line) == col:
                current_line.append(char)
            else:
                current_line[col] = char
            col += 1
    
    # Join lines
    return "\n".join(["".join(line) for line in lines])

# --- Kernel Bridge ---
class KernelBridge:
    def __init__(self, connection_file=None):
        self.connection_file = connection_file
        self.km = None
        self.kc = None
        self.running = False
        self.msg_queue = queue.Queue()
        self.execution_queue = queue.Queue()
        self.current_cell_id = None
        self.current_msg_id = None 
        self.var_msg_id = None
        self.output_counter = 0
        self.save_dir = None

    def start(self):
        if self.connection_file:
            # Connect to existing kernel
            self.kc = BlockingKernelClient(connection_file=self.connection_file)
            self.kc.load_connection_file()
            self.kc.start_channels()
        else:
            # Start new local kernel
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
        
        self._inject_runtime()
        
        # Start a thread to poll IOPub messages
        self.iopub_thread = threading.Thread(target=self._poll_iopub, daemon=True)
        self.iopub_thread.start()

    def _inject_runtime(self):
        script = """
import sys
import io
from IPython.display import display, Image

# Global state
_jovian_plot_mode = 'inline'
_jovian_original_show = None

def _jovian_show(*args, **kwargs):
    global _jovian_plot_mode
    global _jovian_original_show
    
    # Always capture and display the image for the preview pane
    try:
        import matplotlib.pyplot as plt
        fig = plt.gcf()
        # Only show if there's something to show
        if fig.get_axes() or fig.lines or fig.patches or fig.texts:
            buf = io.BytesIO()
            fig.savefig(buf, format='png', bbox_inches='tight')
            buf.seek(0)
            display(Image(data=buf.getvalue(), format='png'))
    except Exception:
        pass

    # Handle window mode
    if _jovian_plot_mode == 'window':
        if _jovian_original_show:
            try:
                # Call the original show function if it exists
                return _jovian_original_show(*args, **kwargs)
            except Exception:
                # Fallback to default matplotlib show if original fails
                try:
                    import matplotlib.pyplot as plt
                    # Avoid recursion if plt.show is self
                    if plt.show != _jovian_show:
                         return plt.show(*args, **kwargs)
                except: pass
        else:
            # If no original show, try default matplotlib show
            try:
                import matplotlib.pyplot as plt
                if plt.show != _jovian_show:
                    return plt.show(*args, **kwargs)
            except: pass
        return
    
    # Inline mode cleanup
    try:
        import matplotlib.pyplot as plt
        plt.close(fig)
    except Exception:
        pass

def _jovian_patch_matplotlib(*args):
    global _jovian_original_show
    try:
        import matplotlib.pyplot as plt
        # Only patch if not already patched
        if plt.show.__name__ != '_jovian_show':
            _jovian_original_show = plt.show
            plt.show = _jovian_show
    except ImportError:
        pass

# Register hook to ensure patch is applied after imports
try:
    ip = get_ipython()
    ip.events.register('post_run_cell', _jovian_patch_matplotlib)
    del ip
except:
    pass

# Try to patch immediately
_jovian_patch_matplotlib()

# Ensure we are using a GUI backend (not inline) to support window mode
try:
    get_ipython().run_line_magic('matplotlib', 'auto')
except:
    pass
"""
        self.kc.execute(script, silent=True)

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
            except Exception:
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
                elif 'application/vnd.jovian.clipboard+json' in data:
                    # Handle clipboard data
                    clip_data = data['application/vnd.jovian.clipboard+json']
                    send_json({"type": "clipboard_data", "content": clip_data["content"]})
                elif 'image/png' in data:
                    img_data = data['image/png']
                    send_json({"type": "debug", "msg": f"Received image data, length: {len(img_data)}"})
                    self.msg_queue.put({"type": "image", "data": img_data})
                elif 'text/plain' in data:
                    self.msg_queue.put({"type": "text", "content": data['text/plain'] + "\n"})

            elif msg_type == 'error':
                # Forward error to REPL
                error_text = "\n".join(content['traceback'])
                send_json({"type": "stream", "text": error_text + "\n", "stream": "stderr"})
                
                self.msg_queue.put({
                    "type": "error", 
                    "ename": content['ename'], 
                    "evalue": content['evalue'], 
                    "traceback": content['traceback']
                })
                
            elif msg_type == 'status':
                if content['execution_state'] == 'idle':
                    self._finalize_execution()

        elif self.var_msg_id and parent_id == self.var_msg_id:
            if msg_type == 'display_data':
                data = content['data']
                if 'application/vnd.jovian.variables+json' in data:
                    var_data = data['application/vnd.jovian.variables+json']
                    send_json({"type": "variable_list", "variables": var_data["variables"]})
                elif 'application/vnd.jovian.dataframe+json' in data:
                    df_data = data['application/vnd.jovian.dataframe+json']
                    send_json({
                        "type": "dataframe_data", 
                        "name": df_data.get("name"),
                        "columns": df_data.get("columns", []),
                        "index": df_data.get("index", []),
                        "data": df_data.get("data", [])
                    })
                elif 'application/vnd.jovian.peek+json' in data:
                    peek_data = data['application/vnd.jovian.peek+json']
                    send_json({"type": "peek_data", "data": peek_data})
                elif 'application/vnd.jovian.clipboard+json' in data:
                    clip_data = data['application/vnd.jovian.clipboard+json']
                    send_json({"type": "clipboard_data", "content": clip_data["content"]})
            
            elif msg_type == 'stream':
                # For variables, we might not want to forward stdout/stderr to REPL to avoid noise,
                # but if there's an error it's good to know.
                pass
                
            elif msg_type == 'error':
                # If variable retrieval fails, we might want to know
                pass

    def _finalize_execution(self):
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

            pending_text = []

            while not self.msg_queue.empty():
                item = self.msg_queue.get()
                
                if item["type"] == "text":
                    pending_text.append(item["content"])
                    continue
                
                # Flush pending text before processing other items
                if pending_text:
                    full_text = "".join(pending_text)
                    processed_text = process_console_output(full_text)
                    if processed_text.strip():
                        output_md_lines.append("```text")
                        output_md_lines.append(processed_text.rstrip())
                        output_md_lines.append("```")
                        output_md_lines.append("")
                    pending_text = []
                
                if item["type"] == "image":
                    img_data_b64 = item["data"]
                    if not img_data_b64:
                        send_json({"type": "debug", "msg": "Skipping empty image data"})
                        continue
                        
                    img_filename = f"{self.current_cell_id}_{self.output_counter:02d}.png"
                    img_path = os.path.join(save_dir, img_filename)
                    
                    try:
                        decoded_data = base64.b64decode(img_data_b64)
                        if len(decoded_data) == 0:
                             send_json({"type": "debug", "msg": "Image data decoded to empty bytes"})
                             continue
                             
                        with open(img_path, "wb") as f:
                            f.write(decoded_data)
                        
                        images[img_filename] = img_data_b64
                        output_md_lines.append(f"![Result]({img_filename})")
                        output_md_lines.append("")
                        self.output_counter += 1
                        
                        send_json({
                            "type": "image_saved",
                            "path": os.path.abspath(img_path),
                            "cell_id": self.current_cell_id
                        })
                    except Exception as e:
                        send_json({"type": "error", "msg": f"Failed to save image: {e}"})

                elif item["type"] == "error":
                    error_info = {
                        "msg": f"{item['ename']}: {item['evalue']}",
                        "traceback": item['traceback']
                    }
                    
                    # Extract line number from traceback
                    # Look for the last occurrence of a line referring to an ipython input
                    line_num = 1
                    for line in item['traceback']:
                        # Remove ANSI codes for regex matching
                        clean_line = re.sub(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])', '', line)
                        match = re.search(r'File "<ipython-input-[^>]+>", line (\d+)', clean_line)
                        if match:
                            line_num = int(match.group(1))
                            send_json({"type": "debug", "msg": f"Matched line {line_num} in: {clean_line.strip()}"})
                    
                    send_json({"type": "debug", "msg": f"Final extracted line: {line_num}"})
                    error_info["line"] = line_num
                    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
                    clean_traceback = [ansi_escape.sub('', line) for line in item['traceback']]
                    
                    output_md_lines.append("### Error")
                    output_md_lines.append("```")
                    output_md_lines.append("\n".join(clean_traceback))
                    output_md_lines.append("```")

            # Flush remaining text
            if pending_text:
                full_text = "".join(pending_text)
                processed_text = process_console_output(full_text)
                if processed_text.strip():
                    output_md_lines.append("```text")
                    output_md_lines.append(processed_text.rstrip())
                    output_md_lines.append("```")
                    output_md_lines.append("")

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
            
        except Exception:
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
            self._do_execute(
                next_cmd["code"], 
                next_cmd["cell_id"], 
                next_cmd.get("file_dir"),
                next_cmd.get("cwd")
            )

    def _do_execute(self, code, cell_id, file_dir=None, cwd=None):
        self.current_cell_id = cell_id
        self.save_dir = file_dir
        
        # Notify execution started
        send_json({"type": "execution_started", "cell_id": cell_id, "code": code})
        
        # Switch kernel CWD if provided
        if cwd:
            safe_cwd = cwd.replace('\\', '\\\\').replace("'", "\\'")
            change_cwd_code = f"import os; import sys; os.chdir('{safe_cwd}'); sys.path.insert(0, '{safe_cwd}') if '{safe_cwd}' not in sys.path else None"
            self.kc.execute(change_cwd_code, silent=True)
        
        # Clear queue
        with self.msg_queue.mutex:
            self.msg_queue.queue.clear()
            
        self.current_msg_id = self.kc.execute(code)

    def execute_code(self, code, cell_id, file_dir=None, cwd=None):
        if self.current_cell_id is not None:
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
import sys
from IPython.display import display

def _jovian_get_variables():
    try:
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
    except Exception as e:
        error_var = {"name": "Error", "type": "Exception", "info": str(e)}
        display({"application/vnd.jovian.variables+json": {"variables": [error_var]}}, raw=True)

_jovian_get_variables()
"""
        self.var_msg_id = self.kc.execute(script, silent=False, store_history=True)

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
            payload = {{
                "name": name,
                "columns": parsed.get('columns', []),
                "index": parsed.get('index', []),
                "data": parsed.get('data', [])
            }}
            display({{"application/vnd.jovian.dataframe+json": payload}}, raw=True)
    except Exception as e:
        pass

_jovian_view_df("{name}")
"""
        self.var_msg_id = self.kc.execute(script, silent=False, store_history=True)

    def peek(self, name):
        script = f"""
import sys
from IPython.display import display

def _jovian_peek(name):
    try:
        if name not in globals(): return
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
        self.var_msg_id = self.kc.execute(script, silent=False, store_history=True)

    def inspect(self, name):
        msg_id = self.kc.inspect(name, cursor_pos=len(name))
        start_time = time.time()
        while time.time() - start_time < 2:
            try:
                reply = self.kc.get_shell_msg(timeout=0.1)
                if reply['parent_header']['msg_id'] == msg_id:
                     content = reply['content']
                     if content['status'] == 'ok' and content['found']:
                         data = content['data']
                         docstring = data.get('text/plain', 'No info')
                         
                         # Strip ANSI codes
                         ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
                         docstring = ansi_escape.sub('', docstring)
                         
                         result = {
                             "name": name,
                             "type": "unknown", 
                             "docstring": docstring,
                             "file": "",
                             "definition": ""
                         }
                         send_json({"type": "inspection_data", "data": result})
                     return
            except queue.Empty:
                continue
            except Exception:
                break

    def copy_to_clipboard(self, name):
        script = f"""
from IPython.display import display
try:
    if "{name}" in globals():
        val = globals()["{name}"]
        display({{"application/vnd.jovian.clipboard+json": {{"content": str(val)}}}}, raw=True)
except Exception:
    pass
"""
        self.var_msg_id = self.kc.execute(script, silent=False, store_history=True)

    def set_plot_mode(self, mode):
        send_json({"type": "debug", "msg": f"Setting plot mode to: {mode}"})
        
        # Update variable FIRST
        cmd = f"_jovian_plot_mode = '{mode}'\n"
        
        # Explicitly switch backend based on mode
        if mode == "window":
             cmd += "try: get_ipython().run_line_magic('matplotlib', 'tk'); print('[Jovian] Switched to tk backend')\nexcept: pass"
        else:
             cmd += "try: get_ipython().run_line_magic('matplotlib', 'inline'); print('[Jovian] Switched to inline backend')\nexcept: pass"

        self.kc.execute(cmd, silent=False, store_history=True)

    def purge_cache(self, ids, file_dir):
        if not file_dir or not os.path.exists(file_dir): return
        
        try:
            valid_set = set(ids)
            send_json({"type": "debug", "msg": f"Purging cache in {file_dir}, valid ids: {len(valid_set)}"})
            
            for f in os.listdir(file_dir):
                # Files: {id}.md, {id}_{counter}.png
                # We need to extract the ID from the filename.
                # Filename format: ID.md or ID_XX.png
                
                file_id = None
                if f.endswith(".md"):
                    file_id = f[:-3]
                elif f.endswith(".png"):
                    # ID_XX.png
                    # Find the last underscore
                    last_underscore = f.rfind('_')
                    if last_underscore != -1:
                        file_id = f[:last_underscore]
                
                if file_id and file_id not in valid_set:
                    try:
                        os.remove(os.path.join(file_dir, f))
                        send_json({"type": "debug", "msg": f"Deleted stale cache: {f}"})
                    except Exception as e:
                        send_json({"type": "debug", "msg": f"Failed to delete {f}: {e}"})
        except Exception as e:
            send_json({"type": "debug", "msg": f"Purge error: {e}"})

    def remove_cache(self, ids, file_dir):
        if not file_dir or not os.path.exists(file_dir): return
        
        try:
            remove_set = set(ids)
            for f in os.listdir(file_dir):
                file_id = None
                if f.endswith(".md"):
                    file_id = f[:-3]
                elif f.endswith(".png"):
                    last_underscore = f.rfind('_')
                    if last_underscore != -1:
                        file_id = f[:last_underscore]
                
                if file_id and file_id in remove_set:
                    try: 
                        os.remove(os.path.join(file_dir, f))
                        send_json({"type": "debug", "msg": f"Removed cache: {f}"})
                    except: pass
        except:
            pass

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--connection-file", help="Path to Jupyter connection file")
    args = parser.parse_args()

    bridge = KernelBridge(connection_file=args.connection_file)
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
            elif cmd.get("command") == "copy_to_clipboard":
                bridge.copy_to_clipboard(cmd["name"])
            elif cmd.get("command") == "set_plot_mode":
                bridge.set_plot_mode(cmd["mode"])
            elif cmd.get("command") == "purge_cache":
                bridge.purge_cache(cmd["ids"], cmd.get("file_dir"))
            elif cmd.get("command") == "remove_cache":
                bridge.remove_cache(cmd["ids"], cmd.get("file_dir"))
            
        except (json.JSONDecodeError, KeyboardInterrupt):
            pass
            
    bridge.stop()

if __name__ == "__main__":
    main()
