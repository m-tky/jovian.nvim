# jovian.nvim 🪐

![Lua](https://img.shields.io/badge/Lua-blue.svg?style=for-the-badge&logo=lua)
![Neovim](https://img.shields.io/badge/Neovim%200.9+-green.svg?style=for-the-badge&logo=neovim)

**jovian.nvim** transforms Neovim into a powerful Jupyter-like environment for Python. Edit `.py` files using the `# %%` cell format, execute code interactively, view rich outputs (including plots), and manage your data—all without leaving your editor.

![Demo](https://via.placeholder.com/800x400?text=Demo+GIF+Placeholder)

---

## 📖 Table of Contents

- [Features](#-features)
- [Try with Nix](#-try-with-nix)
- [Requirements](#-requirements)
- [Installation](#-installation)
- [Usage Guide](#-usage-guide)
- [Keybindings](#-recommended-keybindings)
- [Configuration](#-configuration)
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

## ⚡ Try with Nix

No install needed! If you have [Nix](https://nixos.org/), try `jovian.nvim` instantly:

```bash
nix develop github:m-tky/jovian.nvim
# Inside the shell:
nvim-jovian demo_jovian.py
```

> [!NOTE]
> This trial environment uses the **Kitty** terminal backend for image rendering. Run inside [Kitty](https://sw.kovidgoyal.net/kitty/) for best results.

---

## 📋 Requirements

- **Neovim** (v0.9+)
- **Python 3** with dependencies:
  ```bash
  pip install ipykernel jupyter_client
  ```
- **[image.nvim](https://github.com/3rd/image.nvim)** — Required for plot viewing
- **[jupytext.nvim](https://github.com/GCBallesteros/jupytext.nvim)** — Recommended for `.ipynb` support

---

## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "jovian-org/jovian.nvim",
    dependencies = {
        "3rd/image.nvim",
        "GCBallesteros/jupytext.nvim",
    },
    config = function()
        -- Setup image.nvim (adjust backend to your terminal)
        require("image").setup({
            backend = "kitty", 
            processor = "magick_cli",
            max_width_window_percentage = 100,
            max_height_window_percentage = 30,
            window_overlap_clear_enabled = true,
        })

        -- Setup jovian.nvim
        require("jovian").setup({
            python_interpreter = "python3",
        })
    end
}
```

---

## 🎮 Usage Guide

### Running Code
- Define cells with `# %%`
- Run with `:JovianRun` — output appears in the Preview Window
- Check virtual text status (`Running`, `Done`) on cell headers

### Working with Data
- `:JovianVars` — View active variables
- `:JovianView` — Inspect DataFrames in a floating window
- `:JovianDoc <obj>` / `:JovianPeek <obj>` — View docstrings or quick values

### Remote Development (SSH)
1. `:JovianAddHost my-server user@1.2.3.4 /usr/bin/python3`
2. `:JovianUse my-server`
3. Code runs remotely, results display locally!

---

## ⌨️ Recommended Keybindings

```lua
local map = vim.keymap.set

-- Execution
map("n", "<leader>r", "<cmd>JovianRun<CR>", { desc = "Run Cell" })
map("n", "<leader>x", "<cmd>JovianRunAndNext<CR>", { desc = "Run & Next" })
map("n", "<leader>R", "<cmd>JovianRunAll<CR>", { desc = "Run All Cells" })

-- UI
map("n", "<leader>jo", "<cmd>JovianOpen<CR>", { desc = "Open UI" })
map("n", "<leader>jt", "<cmd>JovianToggle<CR>", { desc = "Toggle UI" })
map("n", "<leader>jv", "<cmd>JovianVars<CR>", { desc = "Variables" })

-- Navigation
map("n", "]c", "<cmd>JovianNextCell<CR>", { desc = "Next Cell" })
map("n", "[c", "<cmd>JovianPrevCell<CR>", { desc = "Prev Cell" })
```

---

## ⚙️ Configuration

<details>
<summary>Click to expand full configuration options</summary>

```lua
require("jovian").setup({
    ui = {
        transparent_float = false,
        winblend = 0,
        layouts = { ... }
    },
    ui_symbols = {
        running = " Running...",
        done = " Done",
        error = " Error",
    },
    python_interpreter = "python3",
    notify_mode = "all", -- "all", "error", "none"
})
```
</details>

---

## 🧠 How it Works

`jovian.nvim` bridges Neovim with a persistent Python process:

1. **Kernel Bridge** — Launches `kernel_bridge.py` in the background (local or SSH)
2. **Communication** — JSON messages via stdin/stdout
3. **Execution** — Wraps an embedded IPython kernel
4. **Plotting** — Saves plots as images, rendered via `image.nvim`

This keeps Neovim responsive while heavy computations run in the background.

---

## 📚 Command Reference

<details>
<summary>Execution Commands</summary>

| Command | Description |
| :--- | :--- |
| `:JovianRun` | Run current cell |
| `:JovianRunAndNext` | Run and jump to next |
| `:JovianRunAll` | Run all cells |
| `:JovianRunAbove` | Run cells up to current |
| `:JovianRunLine` | Run current line |
| `:JovianSendSelection` | Run selection |
| `:JovianStart` | Start kernel |
| `:JovianRestart` | Restart kernel |
| `:JovianInterrupt` | Interrupt execution |
</details>

<details>
<summary>UI & Layout Commands</summary>

| Command | Description |
| :--- | :--- |
| `:JovianOpen` | Open full UI |
| `:JovianToggle` | Toggle UI |
| `:JovianClearREPL` | Clear REPL |
| `:JovianToggleVars` | Toggle Variables |
| `:JovianTogglePlot` | Toggle plot mode |
| `:JovianPin` / `:JovianUnpin` | Pin/unpin output |
</details>

<details>
<summary>Cell Management Commands</summary>

| Command | Description |
| :--- | :--- |
| `:JovianNextCell` / `:JovianPrevCell` | Navigate cells |
| `:JovianNewCellBelow` / `:JovianNewCellAbove` | Insert cell |
| `:JovianDeleteCell` | Delete cell |
| `:JovianMoveCellUp` / `:JovianMoveCellDown` | Move cell |
| `:JovianMergeBelow` | Merge cells |
| `:JovianSplitCell` | Split cell |
</details>

<details>
<summary>Data & Inspection Commands</summary>

| Command | Description |
| :--- | :--- |
| `:JovianVars` | Show variables |
| `:JovianView [var]` | View DataFrame |
| `:JovianCopy [var]` | Copy to clipboard |
| `:JovianDoc [obj]` | View docstring |
| `:JovianPeek [obj]` | Quick peek |
| `:JovianProfile` | Profile cell |
| `:JovianClean(!)` | Clean caches |
</details>

<details>
<summary>Host Management Commands</summary>

| Command | Description |
| :--- | :--- |
| `:JovianAddHost` | Add SSH host |
| `:JovianAddLocal` | Add local config |
| `:JovianUse` | Switch host |
| `:JovianRemoveHost` | Remove host |
</details>

---

## 🎨 Customization

Override these highlight groups to match your theme:

| Group | Purpose |
| :--- | :--- |
| `JovianFloat`, `JovianFloatBorder` | Floating windows |
| `JovianHeader`, `JovianSeparator` | Table elements |
| `JovianVariable`, `JovianType`, `JovianValue` | Variables pane |

---

## 🙏 Acknowledgements

This plugin is inspired by **[vim-jukit](https://github.com/luk400/vim-jukit)**.