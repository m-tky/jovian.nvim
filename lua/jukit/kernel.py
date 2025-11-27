import sys
import json
import os
import io
import contextlib

# バックエンド設定 (GUIエラー回避のため最優先)
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# 設定
CACHE_DIR = ".jukit_cache"
os.makedirs(CACHE_DIR, exist_ok=True)

class JukitKernel:
    def __init__(self):
        self.current_cell_id = "unknown"
        self.current_filename = "unknown_script"
        self.output_counter = 0
        self.stdout_buffer = io.StringIO()
        
        self.original_stdout = sys.stdout
        self.original_stderr = sys.stderr
        
        # Monkey Patches
        sys.stdout = self
        sys.stderr = self
        
        self._original_show = plt.show
        
        # ★★★ 修正ポイント ★★★
        # メソッドを直接代入するとMatplotlibが壊れるので、関数でラップする
        def custom_show_wrapper(*args, **kwargs):
            return self._custom_show(*args, **kwargs)
            
        plt.show = custom_show_wrapper

    def write(self, text):
        self.stdout_buffer.write(text)

    def flush(self):
        pass

    def _get_output_path(self, ext):
        safe_filename = os.path.basename(self.current_filename)
        if not safe_filename: safe_filename = "scratchpad"

        file_dir = os.path.join(CACHE_DIR, safe_filename)
        os.makedirs(file_dir, exist_ok=True)
        
        filename = f"{self.current_cell_id}_{self.output_counter:02d}.{ext}"
        return os.path.join(file_dir, filename)

    def flush_stdout_to_file(self):
        content = self.stdout_buffer.getvalue()
        if not content:
            return

        filepath = self._get_output_path("txt")
        
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(content)
        
        self._send_json("text_file", filepath)
        
        self.output_counter += 1
        self.stdout_buffer = io.StringIO()

    def _send_json(self, msg_type, payload):
        msg = {
            "type": msg_type,
            "payload": payload,
            "cell_id": self.current_cell_id
        }
        self.original_stdout.write(json.dumps(msg) + "\n")
        self.original_stdout.flush()

    def _custom_show(self, *args, **kwargs):
        self.flush_stdout_to_file()
        
        fig = plt.gcf()
        filepath = self._get_output_path("png")
        
        try:
            fig.savefig(filepath, format='png', bbox_inches='tight')
        except Exception as e:
            # 画像保存エラーもキャッチしてログに残す
            self.stdout_buffer.write(f"\n[Jukit Error] Image save failed: {e}\n")
            self.flush_stdout_to_file()
            return
        finally:
            plt.close(fig)
        
        self._send_json("image_file", filepath)
        self.output_counter += 1

    def run_code(self, code, cell_id, filename):
        self.current_cell_id = cell_id
        self.current_filename = filename
        self.output_counter = 0
        self.stdout_buffer = io.StringIO()

        try:
            exec(code, globals())
            self.flush_stdout_to_file()
        except Exception as e:
            import traceback
            self.stdout_buffer.write(traceback.format_exc())
            self.flush_stdout_to_file()

    def start(self):
        while True:
            try:
                line = sys.stdin.readline()
                if not line: break
                
                cmd = json.loads(line)
                if cmd.get('command') == 'execute' or cmd.get('type') == 'execute':
                    filename = cmd.get('filename', 'unknown_script.py')
                    self.run_code(cmd['code'], cmd['cell_id'], filename)
            except json.JSONDecodeError:
                pass
            except KeyboardInterrupt:
                break

if __name__ == "__main__":
    kernel = JukitKernel()
    kernel.start()
