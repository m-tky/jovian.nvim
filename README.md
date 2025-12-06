# jovian.nvim 🪐

![Lua](https://img.shields.io/badge/Lua-blue.svg?style=for-the-badge&logo=lua)
![Neovim](https://img.shields.io/badge/Neovim%200.9+-green.svg?style=for-the-badge&logo=neovim)

**jovian.nvim** transforms Neovim into a powerful Jupyter-like environment for Python. Edit `.py` files using the `# %%` cell format, execute code interactively, view rich outputs (including plots), and manage your data—all without leaving your editor.

![Demo](https://via.placeholder.com/800x400?text=Demo+GIF+Placeholder)

---

## 📖 Table of Contents

- [Features](#-features)
- [Requirements](#-requirements)
- [Installation](#-installation)
- [Configuration](#-configuration)
- [Usage Guide](#-usage-guide)
  - [Running Code](#running-code)
  - [Managing Cells](#managing-cells)
  - [Working with Data](#working-with-data)
  - [Remote Development (SSH)](#remote-development-ssh)
- [Keybindings](#-recommended-keybindings)
- [How it Works](#-how-it-works)
- [Command Reference](#-command-reference)
- [Customization](#-customization)
- [Acknowledgements](#-acknowledgements)

---

## ✨ Features

| Feature | Description |
| :--- | :--- |
| **🚀 Interactive Execution** | Run code cells (`# %%`) or selections instantly. |
| **👀 Live Preview** | See results (text & plots) in a side-by-side preview window. |
| **📊 Variables Pane** | Monitor active variables, their types, and values in real-time. |
| **🖼️ Plot Support** | View Matplotlib/Plotly plots directly in Neovim (via `image.nvim`). |
| **☁️ Remote & Local** | Seamlessly connect to local kernels or **remote SSH hosts**. |
| **🎨 Smart UI** | Auto-resizing windows, virtual text status, and transparent UI options. |
| **⚡ Magic Commands** | Full support for `%timeit`, `!ls`, and other IPython magics. |

---

## 📋 Requirements

- **Neovim** (v0.9+)
- **Python 3** (with `pip`)
- **Dependencies** (installed in your Python environment):
  ```bash
  pip install ipykernel jupyter_client
  ```
- **[image.nvim](https://github.com/3rd/image.nvim)** (Required for plot viewing)
- **[jupytext.nvim](https://github.com/GCBallesteros/jupytext.nvim)** (Recommended for `.ipynb` support)

---

## ⚡ Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "jovian-org/jovian.nvim",
    dependencies = {
        "3rd/image.nvim", -- For plots
        "GCBallesteros/jupytext.nvim", -- For .ipynb files
    },
    config = function()
        -- 1. Setup image.nvim (Adjust backend to your terminal, e.g., "ueberzug" or "kitty")
        require("image").setup({
            backend = "kitty", 
            processor = "magick_cli",
            max_width_window_percentage = 100,
            max_height_window_percentage = 30,
            window_overlap_clear_enabled = true,
        })

        -- 2. Setup jovian.nvim
        require("jovian").setup({
            python_interpreter = "python3", -- Or absolute path to venv python
            
            -- Optional: Configure UI
            ui = {
                transparent_float = true, -- Transparent floating windows
                winblend = 0,             -- Opacity (0-100)
            }
        })
    end
}
```

---

## ⌨️ Recommended Keybindings

`jovian.nvim` does not enforce keybindings. Add these to your config for a standard experience:

```lua
local map = vim.keymap.set

-- Execution
map("n", "<leader>r", "<cmd>JovianRun<CR>", { desc = "Run Cell" })
map("n", "<leader>x", "<cmd>JovianRunAndNext<CR>", { desc = "Run & Next" })
map("n", "<leader>R", "<cmd>JovianRunAll<CR>", { desc = "Run All Cells" })

-- UI
map("n", "<leader>jo", "<cmd>JovianOpen<CR>", { desc = "Open Jovian UI" })
map("n", "<leader>jt", "<cmd>JovianToggle<CR>", { desc = "Toggle UI" })
map("n", "<leader>jv", "<cmd>JovianVars<CR>", { desc = "Show Variables" })

-- Cell Management
map("n", "]c", "<cmd>JovianNextCell<CR>", { desc = "Next Cell" })
map("n", "[c", "<cmd>JovianPrevCell<CR>", { desc = "Prev Cell" })
map("n", "<leader>cn", "<cmd>JovianNewCellBelow<CR>", { desc = "New Cell Below" })
```

---

## 🎮 Usage Guide

### Running Code
- **Cells**: Define cells with `# %%`.
- **Execute**: Use `:JovianRun` to run the current cell. Output appears in the **Preview Window**.
- **Status**: Check the virtual text (`Running`, `Done`) on the cell header.

### Working with Data
- **Variables**: Use `:JovianVars` to see a table of active variables.
- **DataFrames**: Place cursor on a DataFrame variable and run `:JovianView` to see it in a floating window.
- **Inspection**: Use `:JovianDoc <obj>` to view docstrings or `:JovianPeek <obj>` for a quick value check.

### Remote Development (SSH)
1.  **Add Host**: `:JovianAddHost my-server user@1.2.3.4 /usr/bin/python3`
2.  **Connect**: `:JovianUse my-server`
3.  **Run**: Code runs on the remote server, but results (including plots!) show up locally in Neovim.

---

## ⚙️ Configuration

<details>
<summary>Click to see full default configuration</summary>

```lua
require("jovian").setup({
    ui = {
        transparent_float = false,
        winblend = 0,
        layouts = {
            -- Customize window splits here
        }
    },
    ui_symbols = {
        running = " Running...",
        done = " Done",
        error = " Error",
    },
    python_interpreter = "python3",
    notify_mode = "all", -- "all", "error", "none"
})
```
</details>

---

---

## 🧠 How it Works

`jovian.nvim` operates by bridging Neovim with a persistent Python process:

1.  **Kernel Bridge**: When you start a session, the plugin launches a Python script (`kernel_bridge.py`) in the background (locally or via SSH).
2.  **Communication**: Neovim sends code and commands to this script via **standard input/output (stdin/stdout)** using JSON messages.
3.  **Execution**: The bridge wraps an embedded **IPython kernel**, allowing it to execute code, capture output (stdout/stderr), and inspect variables.
4.  **Plotting**: Plots generated by Matplotlib/Plotly are saved as temporary images and rendered in Neovim using **image.nvim**.

This architecture ensures that your Neovim UI remains responsive even while heavy computations are running in the background.

---

## 📚 Command Reference

### Execution
| Command | Description |
| :--- | :--- |
| `:JovianRun` | Run the current cell. |
| `:JovianRunAndNext` | Run the current cell and jump to the next one. |
| `:JovianRunAll` | Run all cells in the file. |
| `:JovianRunAbove` | Run all cells from the start up to the current cell. |
| `:JovianRunLine` | Run the current line. |
| `:JovianSendSelection` | Run the visually selected code. |
| `:JovianStart` | Manually start the kernel. |
| `:JovianRestart` | Restart the kernel. |
| `:JovianInterrupt` | Interrupt execution. |

### UI & Layout
| Command | Description |
| :--- | :--- |
| `:JovianOpen` | Open the full UI (REPL, Preview, Vars). |
| `:JovianToggle` | Toggle UI visibility. |
| `:JovianClearREPL` | Clear the REPL output buffer. |
| `:JovianToggleVars` | Toggle the Variables Pane. |
| `:JovianTogglePlot` | Toggle between inline and window plot modes. |
| `:JovianTogglePin` | Toggle the Pin window. |
| `:JovianPin` | Pin the current cell's output to the Pin window. |
| `:JovianUnpin` | Clear the Pin window. |

### Cell Management
| Command | Description |
| :--- | :--- |
| `:JovianNextCell` / `:JovianPrevCell` | Jump to next/previous cell. |
| `:JovianNewCellBelow` / `:JovianNewCellAbove` | Insert a new code cell. |
| `:JovianNewMarkdownCellBelow` | Insert a new markdown cell. |
| `:JovianDeleteCell` | Delete the current cell. |
| `:JovianMoveCellUp` / `:JovianMoveCellDown` | Move the current cell up/down. |
| `:JovianMergeBelow` | Merge current cell with the one below. |
| `:JovianSplitCell` | Split current cell at cursor. |

### Data & Inspection
| Command | Description |
| :--- | :--- |
| `:JovianVars` | Show variables in a floating window. |
| `:JovianView [var]` | View a DataFrame or variable in a float. |
| `:JovianCopy [var]` | Copy variable value to clipboard. |
| `:JovianDoc [obj]` | Show docstring/definition. |
| `:JovianPeek [obj]` | Quick peek at object value. |
| `:JovianProfile` | Run cell with profiling. |
| `:JovianBackend` | Show current Matplotlib backend. |
| `:JovianClean(!)` | Clean stale caches (use `!` for orphaned caches). |
| `:JovianClearCache(!)` | Clear cache for current cell (use `!` for all). |
| `:JovianClearDiag` | Clear diagnostics. |

### Host Management
| Command | Description |
| :--- | :--- |
| `:JovianAddHost` | Add a remote SSH host. |
| `:JovianAddLocal` | Add a local Python config. |
| `:JovianUse` | Switch to a host/config. |
| `:JovianRemoveHost` | Remove a host config. |

---

### 🎨 Customization (Highlights)

Override these groups to match your theme:
- `JovianFloat`, `JovianFloatBorder` (Windows)
- `JovianHeader`, `JovianSeparator` (Tables)
- `JovianVariable`, `JovianType`, `JovianValue` (Variables)

---

## ⚡ Try with Nix

No install needed! If you have Nix:

```bash
nix develop github:m-tky/jovian.nvim
# Inside the shell:
nvim-jovian demo_jovian.py
```

---

## 🙏 Acknowledgements

This plugin is inspired by **[vim-jukit](https://github.com/luk400/vim-jukit)**.