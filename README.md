# jovian.nvim

**jovian.nvim** is a Neovim plugin designed to provide a Jupyter-like experience for editing Python files, specifically those using the "percent" format (`# %%`). It allows you to execute code cells, view markdown previews, monitor variables, and control the Jupyter kernel directly from Neovim.

## ✨ Features

- **Code Cell Execution**: Run individual cells or the entire file.
- **Markdown Preview**: Live preview of markdown cells.
- **Variables Pane**: Monitor active variables in a dedicated pane.
- **Kernel Control**: Start, restart, and interrupt the Python kernel.
- **Cell Management**: Move, delete, split, and merge cells easily.
- **Virtual Text Status**: Visual indicators for cell status (`Running`, `Done`, `Error`).
- **Kernel Selection**: Switch between local and remote (SSH) Python kernels dynamically.

## 📦 Dependencies

### Required
- **Python Environment**: You only need `ipython` installed.
  ```bash
  pip install ipython
  ```

### Recommended
- **[jupytext.nvim](https://github.com/GCBallesteros/jupytext.nvim)**: Highly recommended for seamless conversion between `.ipynb` files and the percent-formatted python files (`.py`) used by this plugin. It allows you to open `.ipynb` files directly as `.py` files in Neovim.

### Important (For Image Support)
- **[image.nvim](https://github.com/3rd/image.nvim)**: Required for displaying plots and images within Neovim.

**Example configure `image.nvim` as follows:**

```lua
require("image").setup({
    backend = "kitty", -- it depends on your environment (e.g., "ueberzug")
    processor = "magick_cli", -- it depends on your environment
    max_width_window_percentage = 100,
    max_height_window_percentage = 30,
    window_overlap_clear_enabled = true,
})
```

## ⚙️ Configuration

You can configure `jovian.nvim` by passing a table to the `setup` function.

```lua
require("jovian").setup({
    -- UI Settings
    preview_width_percent = 35,
    repl_height_percent = 30,
    vars_pane_width_percent = 20, -- Width of the variables pane (% of editor width)
    toggle_var = true, -- If true, Vars pane opens/closes with JovianToggle/JovianOpen

    -- UI Symbols (Virtual Text)
    ui_symbols = {
        running = " Running...",
        done = " Done",
        error = "✘ Error",
        interrupted = " Interrupted",
    },

    -- Visuals
    flash_highlight_group = "Visual",
    flash_duration = 300,
    float_border = "rounded",

    -- Python
    python_interpreter = "python3",
})
```

## 📁 Caching & Git

`jovian.nvim` creates a hidden directory named `.jovian_cache` in **the same directory as the file you are editing**. This directory stores intermediate files and metadata.

**Recommendation**: Add this directory to your `.gitignore` (globally or per-project) to keep your repository clean.

```gitignore
**/.jovian_cache
```

### Key Options
- **`toggle_var`**: When set to `true`, the Variables Pane will automatically open and close alongside the REPL and Preview windows when you use `JovianToggle` or `JovianOpen`.
- **`vars_pane_width_percent`**: Controls the width of the Variables Pane as a percentage of the total editor width.
- **`ui_symbols`**: Customize the text/icons displayed for cell status.
- **`python_interpreter`**: Defaults to `"python3"`. Since `jovian.nvim` inherits the shell environment from which Neovim was started, this default works seamlessly with **venv**, **nix**, **direnv**, and other environment managers.

## 🚀 Commands

### Host Management (SSH & Local)
- **`:JovianAddHost [name] [ssh_host] [python_path]`**: Add a remote SSH host configuration.
- **`:JovianAddLocal [name] [python_path]`**: Add a local Python configuration.
- **`:JovianUse [name]`**: Switch to a specific host configuration.
- **`:JovianRemoveHost [name]`**: Remove a host configuration.

**Note**: If arguments are omitted, these commands will prompt you interactively.

### UI & Layout
- **`:JovianOpen`**: Open the Jovian UI (REPL, Preview, and optionally Vars Pane).
- **`:JovianToggle`**: Toggle the visibility of the Jovian UI.
- **`:JovianClear`**: Clear the REPL output.
- **`:JovianToggleVars`**: Manually toggle the Variables Pane.

### Execution
- **`:JovianRun`**: Run the current cell.
- **`:JovianRunAndNext`**: Run the current cell and move to the next one.
- **`:JovianRunAll`**: Run all cells in the file.
- **`:JovianRunLine`**: Run the current line.
- **`:JovianSendSelection`**: Run the visually selected code.

### Kernel Control
- **`:JovianStart`**: Start the kernel manually.
- **`:JovianRestart`**: Restart the kernel.
- **`:JovianInterrupt`**: Interrupt the current execution.

### Cell Management
- **`:JovianNextCell` / `:JovianPrevCell`**: Navigate between cells.
- **`:JovianNewCellAbove` / `:JovianNewCellBelow`**: Insert a new cell.
- **`:JovianNewMarkdownCellBelow`**: Insert a new markdown cell below.
- **`:JovianDeleteCell`**: Delete the current cell.
- **`:JovianMoveCellUp` / `:JovianMoveCellDown`**: Move the current cell up or down.
- **`:JovianMergeBelow`**: Merge the current cell with the one below.
- **`:JovianSplitCell`**: Split the current cell at the cursor.

### Data & Inspection
- **`:JovianVars`**: Show variables in a floating window (or update the persistent pane).
- **`:JovianView [df]`**: View a pandas DataFrame or variable in a floating window.
- **`:JovianCopy [var]`**: Copy a variable's value to the clipboard.
- **`:JovianDoc [obj]`**: Inspect an object (docstring, definition).
- **`:JovianPeek [obj]`**: Peek at an object's value/info.

## 🖥️ UI Layout

The Jovian UI is designed to maximize coding efficiency:

1.  **REPL Window**: Opens at the bottom of the screen (`belowright split`).
2.  **Preview Window**: Opens to the right (`vsplit`), displaying rendered markdown.
3.  **Variables Pane**: Opens as a **vertical split to the right of the REPL**. This allows you to keep an eye on your data without obscuring your code or output.

### Virtual Text Status
Cells display their execution status using virtual text on the header line (`# %%`):
- **Running**: Indicates the cell is currently executing.
- **Done**: Indicates execution completed successfully.
- **Error**: Indicates an error occurred.

**Stability**: The virtual text system is robust and handles **Undo/Redo** operations gracefully. If you move or delete cells and then undo, the status indicators will be correctly restored or cleared.

## 🙏 Acknowledgements

This plugin is heavily inspired by **[vim-jukit](https://github.com/luk400/vim-jukit)**. I am grateful for the following concepts and implementations that served as a reference:

- **Architecture**: The core design of separating the Neovim frontend from a Python backend that manages the IPython kernel.
- **Output Capture**: The technique of monkey-patching `sys.stdout` and `sys.stderr` to capture and redirect execution output back to Neovim.
- **UI Layout**: The effective split-window arrangement for code, REPL, and plot previews.
- **Caching Structure**: The fundamental approach to managing execution artifacts and persistent caching (which now includes remote host integration).
