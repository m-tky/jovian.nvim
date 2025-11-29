# 🛠️ Developer Guide for Jovian.nvim

This document explains the internal architecture of `jovian.nvim` and provides guidelines for contributors.

## 🏗️ Architecture

Jovian operates on a **Client-Server model**, communicating via standard I/O (stdio).

### 1. Client (Lua)
The Lua client runs within Neovim and handles:
*   **User Interface**: Managing split windows, floating windows, and virtual text.
*   **Process Control**: Starting the Python kernel using `vim.fn.jobstart`.
*   **Communication**: Sending JSON commands to the kernel's `stdin` and processing JSON responses from `stdout`.
*   **State Management**: Tracking cell execution status, job IDs, and buffer mappings.

### 2. Server (Python)
The backend is a standalone script (`lua/jovian/kernel.py`) that:
*   Embeds an `IPython.core.interactiveshell.InteractiveShell`.
*   Intercepts `stdout` and `stderr` to capture execution output.
*   Listens for JSON commands on `stdin`.
*   Executes code and sends results back as JSON strings.

## 📂 File Structure

*   **`lua/jovian/init.lua`**: The plugin entry point. Registers user commands and autocommands.
*   **`lua/jovian/core.lua`**: The brain of the operation. Handles job control, message dispatching, and SSH tunneling logic.
*   **`lua/jovian/ui.lua`**: UI components. Manages window layouts, TUI rendering, and syntax highlighting.
*   **`lua/jovian/state.lua`**: A shared table for global state (job IDs, active buffers, etc.).
*   **`lua/jovian/config.lua`**: Configuration handling and default values.
*   **`lua/jovian/utils.lua`**: Helper functions for string manipulation and cell parsing.
*   **`lua/jovian/kernel.py`**: The Python backend script.

## 📡 JSON Protocol

Communication between Lua and Python uses line-delimited JSON.

### Commands (Lua -> Python)

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `execute` | `code`, `cell_id`, `filename` | Execute a code block. |
| `get_variables` | None | Request a list of active variables. |
| `view_dataframe` | `name` | Request data for a DataFrame/Array. |

| `inspect` | `name` | Request object documentation/info. |
| `profile` | `code`, `cell_id` | Run cProfile on the code. |
| `save_session` | `filename` | Save variables to a file. |
| `load_session` | `filename` | Load variables from a file. |
| `copy_to_clipboard`| `name` | Copy variable content to clipboard. |

### Events (Python -> Lua)

| Type | Description |
| :--- | :--- |
| `stream` | Real-time stdout/stderr text. |
| `result_ready` | Execution finished. Contains status and error info. |
| `image_saved` | A matplotlib plot was saved to disk. |
| `variable_list` | Response for `get_variables`. |
| `dataframe_data` | Response for `view_dataframe`. |
| `inspection_data` | Response for `inspect`. |
| `input_request` | The kernel is waiting for `input()`. |

## 🔌 SSH Remote Implementation

The remote execution feature is implemented in `core.lua` using a "copy-and-execute" strategy:

1.  **Transfer**: When `ssh_host` is set, `core.lua` uses `scp` to copy the local `kernel.py` to `/tmp/jovian_kernel.py` on the remote host.
2.  **Execute**: It then starts an `ssh` process via `vim.fn.jobstart` that runs `python3 -u /tmp/jovian_kernel.py`.
3.  **Tunnel**: Standard I/O is piped through the SSH connection, making the remote kernel appear local to the Lua client.

## 🧪 Development Setup

1.  Clone the repository.
2.  Open `lua/jovian/init.lua` or any other file.
3.  Use `:luafile %` to reload Lua changes immediately.
4.  Use `:JovianRestart` to reload the Python kernel after modifying `kernel.py`.

## 🤝 Contribution Guidelines

*   **Code Style**: Follow the existing coding style.
*   **Testing**: Ensure new features work with both local and remote (SSH) configurations.
*   **Documentation**: Update `README.md` if you add new user-facing features.
