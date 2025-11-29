import os
import re

CACHE_ROOT = ".jovian_cache"


def get_save_dir(filename=None):
    if filename is None:
        filename = "scratchpad"
    safe_name = os.path.basename(filename) or "scratchpad"
    return os.path.join(CACHE_ROOT, safe_name)


def clean_text_for_markdown(text):
    # Remove ANSI codes
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    lines = text.split("\n")
    cleaned_lines = []
    for line in lines:
        if "\r" in line:
            parts = line.split("\r")
            final_part = parts[-1]
            if not final_part and len(parts) > 1:
                final_part = parts[-2]
            cleaned_lines.append(final_part)
        else:
            cleaned_lines.append(line)
    return "\n".join(cleaned_lines)


def preprocess_magic(code):
    lines = code.split("\n")
    processed_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("!"):
            cmd = stripped[1:]
            escaped_cmd = cmd.replace('"', '\\"')
            py_line = f'import subprocess; p=subprocess.run("{escaped_cmd}", shell=True, capture_output=True, text=True); print(p.stdout, end=""); print(p.stderr, end="")'
            processed_lines.append(py_line)
        elif stripped.startswith("%cd"):
            path = stripped[3:].strip()
            if (path.startswith('"') and path.endswith('"')) or (
                path.startswith("'") and path.endswith("'")
            ):
                path = path[1:-1]
            py_line = f'import os; os.chdir(r"{path}"); print(f"cwd: {{os.getcwd()}}")'
            processed_lines.append(py_line)
        elif stripped.startswith("%time "):
            stmt = stripped[6:]
            py_line = f'__t_start=__import__("time").time(); {stmt}; print(f"Wall time: {{__import__("time").time()-__t_start:.4f}}s")'
            processed_lines.append(py_line)
        else:
            processed_lines.append(line)
    return "\n".join(processed_lines)
