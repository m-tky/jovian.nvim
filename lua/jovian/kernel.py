import sys
import json
import os
import io
import traceback
import glob
import re
import builtins
import types
import subprocess
import time
import cProfile
import pstats

try:
    from IPython.core.interactiveshell import InteractiveShell
except ImportError:
    sys.stderr.write("Error: IPython is not installed. Please install it with 'pip install ipython'\n")
    sys.exit(1)

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# オプショナルなライブラリ
try: import dill
except ImportError: dill = None


CACHE_ROOT = ".jovian_cache"

class StreamCapture:
    def __init__(self, stream_name, parent_kernel):
        self.stream_name = stream_name
        self.parent = parent_kernel
        self.buffer = io.StringIO()

    def write(self, text):
        self.buffer.write(text)
        self.parent._send_stream(self.stream_name, text)

    def flush(self): pass
    def get_value(self): return self.buffer.getvalue()
    def reset(self):
        self.buffer.truncate(0)
        self.buffer.seek(0)

class JovianKernel:
    def __init__(self):
        self.current_cell_id = "unknown"
        self.current_filename = "scratchpad"
        self.output_counter = 0
        self.output_queue = [] 
        
        self.original_stdout = sys.stdout
        self.original_stderr = sys.stderr
        
        self.stdout_proxy = StreamCapture('stdout', self)
        self.stderr_proxy = StreamCapture('stderr', self)
        sys.stdout = self.stdout_proxy
        sys.stderr = self.stderr_proxy
        
        # ★ 修正: colors='NoColor' でANSIコードを無効化
        self.shell = InteractiveShell(display_banner=False, colors='Linux')
        self.shell.enable_matplotlib = lambda gui=None: None
        self.shell.showtraceback = self._custom_traceback

        self.original_input = builtins.input
        builtins.input = self._custom_input

        self._original_show = plt.show
        def custom_show_wrapper(*args, **kwargs):
            return self._custom_show(*args, **kwargs)
        plt.show = custom_show_wrapper

    def _custom_traceback(self, *args, **kwargs):
        # IPythonのエラー表示
        # colors='NoColor' なのでクリーンなテキストが来るはず
        traceback_text = self.shell.InteractiveTB.text(*args, **kwargs)
        self.stderr_proxy.write(traceback_text)

    def _custom_input(self, prompt=""):
        if prompt: print(prompt, end='')
        msg = { "type": "input_request", "prompt": str(prompt), "cell_id": self.current_cell_id }
        self.original_stdout.write(json.dumps(msg) + "\n")
        self.original_stdout.flush()
        while True:
            line = sys.stdin.readline()
            if not line: raise EOFError("Kernel stream ended")
            try:
                cmd = json.loads(line)
                if cmd.get('command') == 'input_reply': return cmd.get('value', '')
            except: pass
        return ""

    def _get_variables(self):
        var_list = []
        for name, value in list(self.shell.user_ns.items()):
            if name.startswith("_") or isinstance(value, (types.ModuleType, types.FunctionType, type)): continue
            if name in ['In', 'Out', 'exit', 'quit', 'get_ipython']: continue
            
            type_name = type(value).__name__
            info = str(value)
            info = info.replace("\n", " ")
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
        self.original_stdout.write(json.dumps({"type": "variable_list", "variables": var_list}) + "\n")
        self.original_stdout.flush()

    def _get_dataframe_data(self, var_name):
        if var_name not in self.shell.user_ns: return
        val = self.shell.user_ns[var_name]
        try:
            import pandas as pd
            import numpy as np
            df = None
            if isinstance(val, pd.DataFrame): df = val
            elif isinstance(val, pd.Series): df = val.to_frame()
            elif isinstance(val, np.ndarray):
                if val.ndim > 2: return
                df = pd.DataFrame(val)
            else: return 

            df_view = df.head(100)
            data_json = df_view.to_json(orient='split', date_format='iso')
            parsed = json.loads(data_json)
            self.original_stdout.write(json.dumps({
                "type": "dataframe_data", "name": var_name,
                "columns": parsed.get('columns', []), "index": parsed.get('index', []), "data": parsed.get('data', [])
            }) + "\n")
            self.original_stdout.flush()
        except: self.stderr_proxy.write(traceback.format_exc())

    def _copy_to_clipboard(self, var_name):
        if var_name not in self.shell.user_ns: return
        val = self.shell.user_ns[var_name]
        try:
            import pandas as pd
            import numpy as np
            text_data = ""
            if isinstance(val, (pd.DataFrame, pd.Series)):
                try: text_data = val.to_markdown()
                except ImportError: text_data = val.to_csv(sep='\t')
            elif isinstance(val, np.ndarray):
                text_data = np.array2string(val, separator=', ')
            else:
                text_data = str(val)
            self.original_stdout.write(json.dumps({
                "type": "clipboard_data", "content": text_data
            }) + "\n")
            self.original_stdout.flush()
        except: self.stderr_proxy.write(traceback.format_exc())

    def _save_session(self, filename):
        if dill is None:
            self.stderr_proxy.write("Error: 'dill' module not found.\n")
            return
        try:
            session_data = {}
            for k, v in self.shell.user_ns.items():
                if k.startswith('_') or k in ['In', 'Out', 'exit', 'quit', 'get_ipython']: continue
                if isinstance(v, (types.ModuleType, types.FunctionType, type)): continue
                try:
                    dill.dumps(v)
                    session_data[k] = v
                except: pass
            with open(filename, 'wb') as f: dill.dump(session_data, f)
            print(f"Session saved to {filename}")
        except: self.stderr_proxy.write(traceback.format_exc())

    def _load_session(self, filename):
        if dill is None:
            self.stderr_proxy.write("Error: 'dill' module not found.\n")
            return
        try:
            if not os.path.exists(filename): return print(f"File not found: {filename}")
            with open(filename, 'rb') as f: session_data = dill.load(f)
            self.shell.user_ns.update(session_data)
            print(f"Session loaded from {filename}")
        except: self.stderr_proxy.write(traceback.format_exc())



    def _inspect_object(self, var_name):
        try:
            info = self.shell.object_inspect(var_name)
            result = {
                "name": info.get('name', var_name),
                "type": info.get('type_name', 'unknown'),
                "docstring": info.get('docstring', 'No documentation found.'),
                "file": info.get('file', ''),
                "definition": info.get('definition', '')
            }
            self.original_stdout.write(json.dumps({"type": "inspection_data", "data": result}) + "\n")
            self.original_stdout.flush()
        except: self.stderr_proxy.write(traceback.format_exc())

    def run_profile(self, code, cell_id):
        self.current_cell_id = cell_id
        self.stdout_proxy.reset()
        self.stderr_proxy.reset()
        pr = cProfile.Profile()
        pr.enable()
        try: self.shell.run_cell(code)
        except: self.stderr_proxy.write(traceback.format_exc())
        finally:
            pr.disable()
            s = io.StringIO()
            ps = pstats.Stats(pr, stream=s).sort_stats('cumulative')
            ps.print_stats(30)
            self.original_stdout.write(json.dumps({"type": "profile_stats", "text": s.getvalue()}) + "\n")
            self.original_stdout.flush()

    def _preprocess_magic(self, code):
        lines = code.split('\n')
        processed_lines = []
        for line in lines:
            stripped = line.strip()
            if stripped.startswith('!'):
                cmd = stripped[1:]
                escaped_cmd = cmd.replace('"', '\\"')
                py_line = f'import subprocess; p=subprocess.run("{escaped_cmd}", shell=True, capture_output=True, text=True); print(p.stdout, end=""); print(p.stderr, end="")'
                processed_lines.append(py_line)
            elif stripped.startswith('%cd'):
                path = stripped[3:].strip()
                if (path.startswith('"') and path.endswith('"')) or (path.startswith("'") and path.endswith("'")):
                    path = path[1:-1]
                py_line = f'import os; os.chdir(r"{path}"); print(f"cwd: {{os.getcwd()}}")'
                processed_lines.append(py_line)
            elif stripped.startswith('%time '):
                stmt = stripped[6:]
                py_line = f'__t_start=__import__("time").time(); {stmt}; print(f"Wall time: {{__import__("time").time()-__t_start:.4f}}s")'
                processed_lines.append(py_line)
            else:
                processed_lines.append(line)
        return '\n'.join(processed_lines)

    def _send_stream(self, stream_name, text):
        self.original_stdout.write(json.dumps({
            "type": "stream", "stream": stream_name, "text": text, "cell_id": self.current_cell_id
        }) + "\n")
        self.original_stdout.flush()

    def _get_save_dir(self, filename=None):
        if filename is None: filename = self.current_filename
        safe_name = os.path.basename(filename) or "scratchpad"
        return os.path.join(CACHE_ROOT, safe_name)

    def _sync_queue(self):
        out = self.stdout_proxy.get_value()
        if out: 
            self.output_queue.append({"type": "text", "content": out})
            self.stdout_proxy.reset()
        err = self.stderr_proxy.get_value()
        if err: 
            self.output_queue.append({"type": "text", "content": err})
            self.stderr_proxy.reset()

    def _custom_show(self, *args, **kwargs):
        self._sync_queue()
        save_dir = self._get_save_dir()
        os.makedirs(save_dir, exist_ok=True)
        filename = f"{self.current_cell_id}_{self.output_counter:02d}.png"
        filepath = os.path.join(save_dir, filename)
        abs_path = os.path.abspath(filepath)
        try:
            fig = plt.gcf()
            fig.savefig(filepath, format='png', bbox_inches='tight')
            plt.close(fig)
            self.output_queue.append({"type": "image", "path": abs_path})
            self.output_counter += 1
            self.original_stdout.write(json.dumps({"type": "image_saved", "path": abs_path, "cell_id": self.current_cell_id}) + "\n")
            self.original_stdout.flush()
        except: self.stderr_proxy.write(traceback.format_exc())

    def _clean_text_for_markdown(self, text):
        # ANSI除去 (念のため残すが、NoColor設定で基本は出ないはず)
        text = re.sub(r'\x1b\[[0-9;]*m', '', text) 
        lines = text.split('\n')
        cleaned_lines = []
        for line in lines:
            if '\r' in line:
                parts = line.split('\r')
                final_part = parts[-1]
                if not final_part and len(parts) > 1: final_part = parts[-2]
                cleaned_lines.append(final_part)
            else: cleaned_lines.append(line)
        return '\n'.join(cleaned_lines)

    def _save_markdown_result(self):
        self._sync_queue()
        save_dir = self._get_save_dir()
        os.makedirs(save_dir, exist_ok=True)
        md_filename = f"{self.current_cell_id}.md"
        md_path = os.path.join(save_dir, md_filename)
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(f"# Output: {self.current_cell_id}\n\n")
            if not self.output_queue: f.write("*(No output)*\n")
            for item in self.output_queue:
                if item["type"] == "text":
                    safe_content = self._clean_text_for_markdown(item["content"]).replace("```", "'''")
                    if safe_content.strip(): f.write(f"```text\n{safe_content}\n```\n\n")
                elif item["type"] == "image":
                    f.write(f"![Result]({item['path']})\n\n")
        return os.path.abspath(md_path), ""

    def run_code(self, code, cell_id, filename):
        self.current_cell_id = cell_id
        self.current_filename = filename
        self.output_counter = 0
        self.output_queue = []
        self.stdout_proxy.reset()
        self.stderr_proxy.reset()
        error_info = None

        try:
            result = self.shell.run_cell(code)
            if not result.success:
                # ★ 修正: SyntaxError と RuntimeError を両方キャッチする
                
                # Case 1: SyntaxError (パース段階でのエラー)
                if result.error_before_exec:
                    err = result.error_before_exec
                    if isinstance(err, SyntaxError):
                        error_info = {
                            "line": err.lineno,
                            "msg": f"{type(err).__name__}: {err.msg}"
                        }

                # Case 2: RuntimeError (実行中のエラー)
                elif result.error_in_exec:
                    err = result.error_in_exec
                    # まれに実行中にSyntaxErrorが出ることもある (evalなど)
                    if isinstance(err, SyntaxError):
                        error_info = {
                            "line": err.lineno,
                            "msg": f"{type(err).__name__}: {err.msg}"
                        }
                    else:
                        # 通常の例外: トレースバックをたどる
                        tb = err.__traceback__
                        while tb:
                            # ユーザーのセル(<ipython-input...>)を探す
                            if tb.tb_frame.f_code.co_filename.startswith("<ipython-input"):
                                error_info = {
                                    "line": tb.tb_lineno,
                                    "msg": f"{type(err).__name__}: {str(err)}"
                                }
                                break
                            tb = tb.tb_next
                        
                        # ★ 追加: トレースバックから見つからなかった場合のフォールバック
                        if not error_info:
                             error_info = {
                                "line": 1, # 行番号不明
                                "msg": f"{type(err).__name__}: {str(err)} (Traceback not found in user cell)"
                            }
                            
        except Exception: 
            self.stderr_proxy.write(traceback.format_exc())
        finally:
            md_path, _ = self._save_markdown_result()
            # ★ 修正: status フィールドを追加
            status = "error" if error_info else "ok"
            msg = {"type": "result_ready", "cell_id": cell_id, "file": md_path, "status": status}
            if error_info: msg["error"] = error_info
            self.original_stdout.write(json.dumps(msg) + "\n")
            self.original_stdout.flush()
            
    def _purge_cache(self, valid_ids, filename):
        save_dir = self._get_save_dir(filename)
        if not os.path.exists(save_dir): return
        valid_set = set(valid_ids)
        for f in os.listdir(save_dir):
            parts = f.replace('.', '_').split('_')
            if parts[0] not in valid_set:
                 try: os.remove(os.path.join(save_dir, f))
                 except: pass

    def start(self):
        while True:
            try:
                line = sys.stdin.readline()
                if not line: break
                cmd = json.loads(line)
                if cmd.get('command') == 'execute':
                    self.run_code(cmd['code'], cmd['cell_id'], cmd.get('filename', 'scratchpad'))
                elif cmd.get('command') == 'profile':
                    self.run_profile(cmd['code'], cmd['cell_id'])
                elif cmd.get('command') == 'copy_to_clipboard':
                    self._copy_to_clipboard(cmd.get('name'))
                elif cmd.get('command') == 'save_session':
                    self._save_session(cmd.get('filename'))
                elif cmd.get('command') == 'load_session':
                    self._load_session(cmd.get('filename'))

                elif cmd.get('command') == 'clean_cache':
                    self._purge_cache(cmd.get('valid_ids', []), cmd.get('filename', 'scratchpad'))
                elif cmd.get('command') == 'get_variables': self._get_variables()
                elif cmd.get('command') == 'view_dataframe': self._get_dataframe_data(cmd.get('name'))
                elif cmd.get('command') == 'inspect': self._inspect_object(cmd.get('name'))
                elif cmd.get('command') == 'input_reply': pass 
            except (json.JSONDecodeError, KeyboardInterrupt): pass

if __name__ == "__main__":
    kernel = JovianKernel()
    kernel.start()
