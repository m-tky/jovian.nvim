# Development Guide for jovian.nvim

This document provides an overview of the project structure and guidelines for contributing to `jovian.nvim`.

## 📂 Project Structure

The core logic is located in `lua/jovian/`:

- **`init.lua`**: The entry point. Handles `setup`, command registration, and autocmds.
- **`core.lua`**: The brain of the plugin. Manages the Python kernel process, handles communication (sending code, receiving results), and orchestrates the overall logic.
- **`hosts.lua`**: Manages host configurations (Local/SSH), persistence, and validation.
- **`ui.lua`**: Handles all UI elements.
    - Manages Windows and Buffers (REPL, Preview, Vars Pane).
    - **Extmark Management**: Handles the creation, deletion, and cleanup of virtual text (cell status).
- **`utils.lua`**: Utility functions for text manipulation.
    - Cell parsing (finding ranges).
    - Cell operations (Delete, Move, Split).
- **`config.lua`**: Defines default configuration options.

### Key Concepts

- **Extmark Management**: Virtual text (e.g., "Done", "Running") is managed via a dedicated namespace (`State.status_ns`). Functions in `ui.lua` (`set_cell_status`, `clear_status_extmarks`) control this.
- **Window Management**: Window IDs are stored in `State.win` (e.g., `State.win.output`, `State.win.variables`). We check `vim.api.nvim_win_is_valid` before accessing them.

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
