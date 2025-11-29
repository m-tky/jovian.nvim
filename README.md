# 🪐 Jovian.nvim

**Jovian.nvim** is a powerful Neovim plugin that brings a Jupyter Notebook-like experience directly into your editor. It allows you to execute Python code, visualize data, and manage cells without leaving Neovim, offering a lightweight and keyboard-centric alternative to browser-based notebooks.

## ✨ Features

*   **IPython Kernel Integration**: Seamlessly execute code using a persistent IPython kernel.
*   **Cell-Based Execution**: Define code cells using `# %%` markers and run them individually or in batches.
*   **Rich Output Display**: View execution results (stdout/stderr) in a dedicated split window.
*   **Data Visualization**:
    *   **Data Viewer**: Inspect `pandas` DataFrames and `numpy` arrays in a floating spreadsheet view (`:JovianView`).
    *   **Image Support**: Automatically saves `matplotlib` plots and previews them in a dedicated window.
*   **Variable Explorer**: Keep track of active variables, their types, and shapes (`:JovianVars`).
*   **Profiling**: Analyze code performance with built-in `cProfile` integration (`:JovianProfile`).
*   **Remote Execution (SSH)**: Execute code on a remote server transparently via SSH.
*   **Session Management**: Save and load your workspace state (variables) using `dill`.
*   **Diagnostics**: Inline highlighting of Python errors for immediate feedback.

## 📦 Requirements

*   **Neovim** (v0.9.0+)
*   **Python 3**
*   **Python Packages**:
    *   Required: `ipython`
    *   Recommended: `pandas`, `numpy`, `matplotlib`
    *   Optional: `dill` (for session saving)

    ```bash
    pip install ipython pandas numpy matplotlib dill
    ```

## 🚀 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "your-username/jovian.nvim",
    ft = "python",
    config = function()
        require("jovian").setup({
            python_interpreter = "python3",
        })
    end
}
```

## ⚙️ Configuration

Here is the default configuration with all available options:

```lua
require("jovian").setup({
    -- UI Settings
    preview_width_percent = 35,  -- Width of the preview window
    repl_height_percent = 30,    -- Height of the REPL window
    preview_image_ratio = 0.3,   -- Image scaling in preview
    repl_image_ratio = 0.3,      -- Image scaling in REPL

    -- Python Environment
    python_interpreter = "python3",

    -- SSH Remote Execution (Optional)
    -- ssh_host = "user@hostname", -- Remote host
    -- ssh_python = "/usr/bin/python3", -- Remote python path

    -- Visuals
    flash_highlight_group = "Visual", -- Highlight group for cell execution flash
    flash_duration = 300,             -- Duration of the flash in ms

    -- Behavior
    notify_threshold = 10, -- Notify if execution takes longer than X seconds
})
```

## ⌨️ Keybindings

Jovian.nvim does not enforce default keybindings. Add the following to your `init.lua` for a recommended setup:

```lua
local map = vim.keymap.set

-- Window Management
map("n", "<leader>jo", "<cmd>JovianOpen<cr>", { desc = "Open Jovian Windows" })
map("n", "<leader>jt", "<cmd>JovianToggle<cr>", { desc = "Toggle Jovian Windows" })

-- Execution
map("n", "<leader>r", "<cmd>JovianRun<cr>", { desc = "Run Current Cell" })
map("n", "<leader>R", "<cmd>JovianRunAll<cr>", { desc = "Run All Cells" })
map("v", "<leader>r", "<cmd>JovianSendSelection<cr>", { desc = "Run Selection" })

-- Navigation & Editing
map("n", "]c", "<cmd>JovianNextCell<cr>", { desc = "Next Cell" })
map("n", "[c", "<cmd>JovianPrevCell<cr>", { desc = "Previous Cell" })
map("n", "<leader>cn", "<cmd>JovianNewCellBelow<cr>", { desc = "New Cell Below" })

-- Data & Tools
map("n", "<leader>jv", "<cmd>JovianVars<cr>", { desc = "Variable Explorer" })
map("n", "<leader>jd", "<cmd>JovianView<cr>", { desc = "View DataFrame/Array" })
map("n", "<leader>k", "<cmd>JovianDoc<cr>", { desc = "Inspect Object" })

-- Kernel Control
map("n", "<leader>kk", "<cmd>JovianRestart<cr>", { desc = "Restart Kernel" })
map("n", "<leader>ki", "<cmd>JovianInterrupt<cr>", { desc = "Interrupt Kernel" })
```

## 🎮 Usage

### Working with Cells

Define cells using `# %%`. You can add an optional ID or description:

```python
# %% id="imports"
import numpy as np
import pandas as pd

# %% id="data-processing"
df = pd.DataFrame(np.random.randn(10, 4), columns=list('ABCD'))
print(df)
```

### Commands Reference

| Command | Description |
| :--- | :--- |
| **Execution** | |
| `:JovianRun` | Execute the current cell. |
| `:JovianRunAll` | Execute all cells in the buffer. |
| `:JovianSendSelection` | Execute the selected visual range. |
| `:JovianProfile` | Profile the current cell using `cProfile`. |
| **Management** | |
| `:JovianOpen` | Open the Output and REPL windows. |
| `:JovianToggle` | Toggle the visibility of Jovian windows. |
| `:JovianRestart` | Restart the IPython kernel. |
| `:JovianInterrupt` | Interrupt the current execution (SIGINT). |
| `:JovianClear` | Clear the REPL output. |
| `:JovianClean` | Clean stale cache files. |
| **Data & Tools** | |
| `:JovianVars` | Show a list of active variables. |
| `:JovianView [var]` | Open a spreadsheet viewer for a DataFrame or Array. |
| `:JovianDoc [var]` | Inspect an object (show docstring/info). |
| `:JovianCopy [var]` | Copy a variable to the clipboard. |
| **Navigation** | |
| `:JovianNextCell` | Jump to the next cell. |
| `:JovianPrevCell` | Jump to the previous cell. |
| `:JovianNewCellBelow` | Insert a new cell below the current one. |
| `:JovianNewCellAbove` | Insert a new cell above the current one. |
| `:JovianMergeBelow` | Merge the current cell with the one below. |
| **Session** | |
| `:JovianSaveSession [file]` | Save the current session variables to a file. |
| `:JovianLoadSession [file]` | Load session variables from a file. |

## 🌐 SSH Remote Execution

Jovian.nvim supports running code on a remote server while keeping your editing experience local.

1.  **Setup SSH**: Ensure you have password-less SSH access (public key auth) to your remote server.
2.  **Configure**:
    ```lua
    require("jovian").setup({
        ssh_host = "user@remote-server.com",
        ssh_python = "/path/to/remote/python3", -- Ensure ipython is installed there
    })
    ```
3.  **Run**: Jovian will automatically transfer the kernel script and tunnel the connection. All commands work as if they were local.
