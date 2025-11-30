import builtins
import cProfile
import io
import json
import os
import pstats
import sys
import traceback

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

try:
    from IPython.core.interactiveshell import InteractiveShell
except ImportError:
    sys.stderr.write(
        "Error: IPython is not installed. Please install it with 'pip install ipython'\n"
    )
    sys.exit(1)

import protocol
import utils


class JovianShell:
    def __init__(self):
        self.current_cell_id = "unknown"
        self.current_filename = "scratchpad"
        self.current_file_dir = None
        self.output_counter = 0
        self.output_queue = []

        self.original_stdout = sys.stdout
        self.original_stderr = sys.stderr

        self.stdout_proxy = protocol.StreamCapture("stdout", self._send_stream_callback)
        self.stderr_proxy = protocol.StreamCapture("stderr", self._send_stream_callback)
        sys.stdout = self.stdout_proxy
        sys.stderr = self.stderr_proxy

        self.shell = InteractiveShell(display_banner=False, colors="Linux")
        self.original_input = builtins.input
        builtins.input = self._custom_input

        self._original_show = plt.show

        def custom_show_wrapper(*args, **kwargs):
            return self._custom_show(*args, **kwargs)

        plt.show = custom_show_wrapper

    def _send_stream_callback(self, stream_name, text):
        protocol.send_stream(stream_name, text, self.current_cell_id)

    def _custom_input(self, prompt=""):
        if prompt:
            print(prompt, end="")
        msg = {
            "type": "input_request",
            "prompt": str(prompt),
            "cell_id": self.current_cell_id,
        }
        self.original_stdout.write(json.dumps(msg) + "\n")
        self.original_stdout.flush()
        while True:
            line = sys.stdin.readline()
            if not line:
                raise EOFError("Kernel stream ended")
            try:
                cmd = json.loads(line)
                if cmd.get("command") == "input_reply":
                    return cmd.get("value", "")
            except:
                pass
        return ""

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
        save_dir = utils.get_save_dir(self.current_filename, self.current_file_dir)
        os.makedirs(save_dir, exist_ok=True)
        filename = f"{self.current_cell_id}_{self.output_counter:02d}.png"
        filepath = os.path.join(save_dir, filename)
        abs_path = os.path.abspath(filepath)
        try:
            fig = plt.gcf()
            fig.savefig(filepath, format="png", bbox_inches="tight")
            plt.close(fig)
            self.output_queue.append({"type": "image", "path": abs_path})
            self.output_counter += 1
            protocol.send_json(
                {
                    "type": "image_saved",
                    "path": abs_path,
                    "cell_id": self.current_cell_id,
                }
            )
        except:
            self.stderr_proxy.write(traceback.format_exc())

    def _save_markdown_result(self):
        self._sync_queue()
        save_dir = utils.get_save_dir(self.current_filename, self.current_file_dir)
        os.makedirs(save_dir, exist_ok=True)
        md_filename = f"{self.current_cell_id}.md"
        md_path = os.path.join(save_dir, md_filename)
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(f"# Output: {self.current_cell_id}\n\n")
            if not self.output_queue:
                f.write("*(No output)*\n")
            for item in self.output_queue:
                if item["type"] == "text":
                    safe_content = utils.clean_text_for_markdown(
                        item["content"]
                    ).replace("```", "'''")
                    if safe_content.strip():
                        f.write(f"```text\n{safe_content}\n```\n\n")
                elif item["type"] == "image":
                    f.write(f"![Result]({item['path']})\n\n")
        return os.path.abspath(md_path), ""

    def run_code(self, code, cell_id, filename, file_dir=None):
        self.current_cell_id = cell_id
        self.current_filename = filename
        self.current_file_dir = file_dir
        self.output_counter = 0
        self.output_queue = []
        self.stdout_proxy.reset()
        self.stderr_proxy.reset()
        error_info = None

        try:
            result = self.shell.run_cell(code)
            if not result.success:
                if result.error_before_exec:
                    err = result.error_before_exec
                    if isinstance(err, SyntaxError):
                        error_info = {
                            "line": err.lineno,
                            "msg": f"{type(err).__name__}: {err.msg}",
                        }
                elif result.error_in_exec:
                    err = result.error_in_exec
                    if isinstance(err, SyntaxError):
                        error_info = {
                            "line": err.lineno,
                            "msg": f"{type(err).__name__}: {err.msg}",
                        }
                    else:
                        tb = err.__traceback__
                        while tb:
                            if tb.tb_frame.f_code.co_filename.startswith(
                                "<ipython-input"
                            ):
                                error_info = {
                                    "line": tb.tb_lineno,
                                    "msg": f"{type(err).__name__}: {str(err)}",
                                }
                                break
                            tb = tb.tb_next

                        if not error_info:
                            error_info = {
                                "line": 1,
                                "msg": f"{type(err).__name__}: {str(err)} (Traceback not found in user cell)",
                            }

        except Exception:
            self.stderr_proxy.write(traceback.format_exc())
        finally:
            md_path, _ = self._save_markdown_result()
            status = "error" if error_info else "ok"
            msg = {
                "type": "result_ready",
                "cell_id": cell_id,
                "file": md_path,
                "status": status,
            }
            if error_info:
                msg["error"] = error_info
            protocol.send_json(msg)

    def run_profile(self, code, cell_id):
        self.current_cell_id = cell_id
        self.stdout_proxy.reset()
        self.stderr_proxy.reset()
        pr = cProfile.Profile()
        pr.enable()
        try:
            self.shell.run_cell(code)
        except:
            self.stderr_proxy.write(traceback.format_exc())
        finally:
            pr.disable()
            s = io.StringIO()
            ps = pstats.Stats(pr, stream=s).sort_stats("cumulative")
            ps.print_stats(30)
            protocol.send_json({"type": "profile_stats", "text": s.getvalue()})
