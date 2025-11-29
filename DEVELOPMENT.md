# Development Documentation

This document outlines the architecture and technical details of `jovian.nvim`.

## Architecture Overview

`jovian.nvim` operates on a client-server model:

*   **Frontend (Lua):** Runs inside Neovim. Handles UI, user commands, and process management.
*   **Backend (Python):** Runs as a separate process (IPython kernel). Executes code and manages state.

Communication occurs via standard input/output (stdio) using newline-delimited JSON messages.

## Directory Structure

*   `lua/jovian/`
    *   `init.lua`: Entry point. Registers user commands and autocommands.
    *   `core.lua`: Core logic. Manages the Python kernel process, sends commands, and dispatches received messages.
    *   `ui.lua`: UI management. Handles REPL/Preview windows, floating windows, and notifications.
    *   `utils.lua`: Utility functions for cell parsing, ID generation, and buffer manipulation.
    *   `config.lua`: Configuration management.
    *   `state.lua`: Shared state (window IDs, buffer IDs, kernel job ID).
    *   `backend/`: Python backend source code.
        *   `main.py`: Entry point for the Python process.
        *   `shell.py`: Wraps the IPython kernel (`InteractiveShell`).
        *   `handlers.py`: Command handlers (variables, dataframes, inspection).
        *   `protocol.py`: JSON communication protocol helpers.

## Technical Details

### Communication Protocol

Messages are JSON objects sent over stdio.

*   **Lua -> Python:**
    ```json
    { "command": "execute", "code": "print('hello')", "cell_id": "cell_123" }
    ```
*   **Python -> Lua:**
    ```json
    { "type": "stream", "stream": "stdout", "text": "hello\n" }
    { "type": "result_ready", "cell_id": "cell_123", "status": "ok" }
    ```

### JSON Buffering

Since standard output may be chunked by the OS or buffers, a single JSON message might be split across multiple `on_stdout` callbacks in Lua.

*   **Implementation:** `lua/jovian/core.lua` (`on_stdout`)
*   **Logic:**
    1.  Incoming data chunks are appended to `State.stdout_buffer`.
    2.  The buffer is split by newline characters.
    3.  Complete lines are parsed as JSON.
    4.  Incomplete lines (at the end of the chunk) remain in the buffer for the next callback.

### Window Management

*   **REPL & Preview:** Managed in `lua/jovian/ui.lua`.
    *   `M.open_windows()`: Creates splits for REPL and Preview.
    *   **Focus Restoration:** Before opening or toggling windows, the current window ID is captured. After the operation, `vim.api.nvim_set_current_win` is used to restore focus to the code editor.
*   **Floating Windows:** Used for `JovianVars`, `JovianPeek`, etc.
    *   **Borders:** Configurable via `Config.options.float_border`. The value is passed directly to `vim.api.nvim_open_win`.

### Python Backend

*   **IPython Integration:** Uses `IPython.core.interactiveshell.InteractiveShell` to execute code.
*   **Output Capture:**
    *   `sys.stdout` and `sys.stderr` are redirected to `protocol.StreamCapture`.
    *   Captured output is sent to Lua as `stream` messages.
*   **Matplotlib Integration:**
    *   `plt.show()` is patched to save figures to a temporary directory.
    *   The path to the saved image is sent to Lua, which can then display it (e.g., via `image.nvim` if integrated, or just a notification).

### Localization

The codebase is English-only.
*   **Lua:** All user-facing strings (notifications, virtual text) and comments are in English.
*   **Python:** All comments and error messages are in English.
*   **Verification:** `grep` checks ensure no non-ASCII characters (excluding icons) remain in the source code.
