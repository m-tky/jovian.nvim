# Development Guide for jovian.nvim

This document provides an overview of the project structure and guidelines for contributing to `jovian.nvim`.

## 📂 Project Structure

The core logic is located in `lua/jovian/`:

- **`init.lua`**: The entry point. Handles `setup` and delegates command registration.
- **`commands.lua`**: Contains all user command definitions (`JovianRun`, `JovianToggle`, etc.).
- **`core.lua`**: The brain of the plugin. Manages the Python kernel process (local or remote) and orchestrates logic.
- **`backend/kernel_bridge.py`**: The Python script that runs on the target host (local or remote). It wraps an `IPython.interactive` shell, captures I/O, and communicates with Neovim via JSON messages. It also handles plot display, supporting both inline images and external windows (via TkAgg) simultaneously.
- **`handlers.lua`**: Contains handler functions for processing messages received from the Python kernel.
- **`hosts.lua`**: Manages host configurations (Local/SSH), persistence, and validation.
- **`ui.lua`**: The main UI module. Acts as a facade for UI submodules.
    - **`ui/windows.lua`**: Manages Windows and Buffers (REPL, Preview, Vars Pane).
    - **`ui/renderers.lua`**: Handles rendering of content (Variables, Dataframes).
    - **`ui/virtual_text.lua`**: Manages virtual text and extmarks.
    - **`ui/shared.lua`**: Shared UI utilities to avoid circular dependencies.
- **`utils.lua`**: Utility functions for text manipulation.
    - Cell parsing (finding ranges).
    - Cell operations (Delete, Move, Split).
- **`config.lua`**: Defines default configuration options.
- **`diagnostics.lua`**: Handles LSP diagnostic filtering (suppressing errors for magic commands).
- **`jovian_queries/`**: Contains custom TreeSitter queries for syntax highlighting (injections and highlights).

### Key Concepts

- **Extmark Management**: Virtual text (e.g., "Done", "Running") is managed via a dedicated namespace (`State.status_ns`). Functions in `ui.lua` (`set_cell_status`, `clear_status_extmarks`) control this.
- **Window Management**: Window IDs are stored in `State.win` (e.g., `State.win.output`, `State.win.variables`). We check `vim.api.nvim_win_is_valid` before accessing them.
- **Magic Command Handling**:
    - **LSP Suppression**: `diagnostics.lua` intercepts `textDocument/publishDiagnostics` from the LSP client. It filters out Syntax Errors on lines starting with `%` or `!`.
    - **TreeSitter Highlighting**: We use custom queries in `jovian_queries/` to highlight magic commands.
        - A custom predicate `#same-line?` is registered in `init.lua` to handle fragmented nodes (e.g., `!ls --color=always`).
        - We use `priority` 105 to ensure our highlights override the default Python highlights.
- **Remote Execution Architecture**:
    - **Connection**: We use `ssh` to connect to remote hosts.
    - **Backend Deployment**: The `lua/jovian/backend/` directory is automatically copied (scp) to the remote host (`~/.jovian/backend/`) upon connection.
    - **Communication**: Neovim communicates with the remote `kernel_bridge.py` via the SSH process's stdin/stdout.
    - **File Sync**: Generated files (images, markdown) are synced back to the local machine via `scp` for preview.

- **Cache Management**:
    - Cache is stored in `.jovian_cache/` relative to the source file.
    - **Orphaned Cache Cleanup**: `core.lua` contains `clean_orphaned_caches` which scans the cache directory and removes subdirectories corresponding to missing source files. This is triggered on `VimEnter`, `VimLeavePre`, and via `:JovianCleanCache`.

## 🤝 Contribution Guide

### Adding New Cell Operations

If you want to add a new cell operation (e.g., `JovianSplitCell`), follow these steps:

1.  **Implement Logic in `utils.lua`**:
    - Manipulate the buffer text using `vim.api.nvim_buf_set_lines`.
    - **CRITICAL**: You **MUST** handle Extmark cleanup. If you move or delete lines that contain a cell header (`# %%`), the associated Extmarks might persist or become orphaned.
    - Use `UI.clear_status_extmarks` or `UI.delete_status_extmark` to clean up before modifying text.

2.  **Register Command in `init.lua`**:
    - Add a new user command that calls your utility function.
    - **Trigger Structure Check**: Call `require("jovian.core").check_structure_change()` after the operation to ensure the plugin's internal state (cache) remains consistent.

### Testing

Tests are located in the `tests/` directory. They are simple Lua scripts that mock the Neovim API or run within a Neovim instance to verify functionality.

To run a verification script:
```bash
nvim -l tests/verify_command_cleanup.lua
```

## ⚠️ Known Issues & Development Notes

### Virtual Text Stability (Undo/Redo)

One of the challenges in this plugin is maintaining accurate virtual text (cell status) during complex edits and Undo/Redo operations.

- **Debouncing**: We use a **debounced `TextChanged` listener** (in `init.lua` -> `core.lua`) to periodically scan the buffer and clean up invalid Extmarks.
- **Atomic Operations**: When implementing move operations, we use `vim.api.nvim_buf_set_lines` in a single call (or grouped via `undojoin` previously) to ensure that Undo restores the buffer to a clean state.
- **Explicit Cleanup**: Do not rely solely on Neovim's automatic Extmark movement. Explicitly clear status marks when logically removing a cell to prevent "ghost" marks.
