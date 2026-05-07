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

| Feature                      | Description                                                             |
| :--------------------------- | :---------------------------------------------------------------------- |
| **🚀 Interactive Execution** | Run code cells (`# %%`) or selections instantly.                        |
| **👀 Live Preview**          | See results (text & plots) in a side-by-side preview window.            |
| **📊 Variables Pane**        | Monitor active variables, their types, and values in real-time.         |
| **🖼️ Plot Support**          | View Matplotlib/Plotly plots directly in Neovim (via `image.nvim`).     |
| **☁️ Remote & Tailscale**    | One-button SSH/Tailscale tunneling with automatic lifecycle management. |
| **🔄 Easy Sync**             | Build-in `rsync` command to keep local/remote files in sync.           |
| **🎨 Smart UI**              | Auto-resizing windows, virtual text status, and DataFrame pagination.   |
| **⚡ Magic Commands**        | Full support for `%timeit`, `!ls`, and other IPython magics.            |

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
- **System Libraries** (Required for Lua-native ZMQ & Sync):
  - **`libzmq`** (ZeroMQ)
  - **`openssl`**
  - **`rsync`** (For `:JovianSync`)
- **Python 3** with dependencies:
  ```bash
  pip install ipykernel jupyter_client pandas
  ```
- **[image.nvim](https://github.com/3rd/image.nvim)** — Required for plot viewing
- **[jupytext.nvim](https://github.com/GCBallesteros/jupytext.nvim)** — Recommended for `.ipynb` support

---

## 📦 Installation

#### Using [Lazy.nvim](https://github.com/folke/lazy.nvim)
```lua
{
    "m-tky/jovian.nvim",
    dependencies = {
        "3rd/image.nvim",
        "neovim/nvim-lspconfig",
    },
    config = function()
        require("jovian").setup({
            python_interpreter = "python3",
        })
    end
}
```

#### Using Nix (Flake)
If you are using Nix, Jovian provides a standard Neovim plugin package and a pre-configured Python environment with all necessary dependencies (`ipykernel`, `pandas`, `zeromq`, etc.).

```nix
# Example usage in another flake
{
  inputs.jovian.url = "github:m-tky/jovian.nvim";
  
  outputs = { self, nixpkgs, jovian }: {
    neovim = pkgs.neovim.override {
      configure.packages.myVimPackage.start = [
        jovian.packages.${system}.jovian-nvim
      ];
      # Point to the pre-bundled Python environment
      customRC = ''
        lua << EOF
          require("jovian").setup({
            python_interpreter = "${jovian.packages.${system}.pythonEnv}/bin/python3",
          })
        EOF
      '';
    };
  };
}
```

#### Runtime Autocompletion

Jovian provides context-aware autocompletion powered by the Jupyter kernel. This allows you to complete dictionary keys, data columns, and dynamic attributes that static LSP (like Pyright) might miss.

By default, it is set as `omnifunc`. You can trigger it with `<C-x><C-o>`.

**Integration with [blink.cmp](https://github.com/Saghen/blink.cmp):**
Add the following to your configuration to see Jupyter completions alongside LSP results:

```lua
require('blink.cmp').setup({
  sources = {
    default = { 'lsp', 'path', 'snippets', 'buffer', 'jovian' },
    providers = {
      jovian = {
        name = 'Jovian',
        module = 'blink.cmp.sources.omnifunc',
        enabled = true,
      }
    }
  }
})
```

---

## 🎮 Usage Guide

### Running Code

- Define cells with `# %%`
- Run with `:JovianRun` — output appears in the Preview Window (**Native ZMQ execution for zero latency!**)
- Check virtual text status (`Running`, `Done`) on cell headers

### Working with Data

- `:JovianVars` — View active variables. (**Paging supported for large environments**)
  - Use `<PageDown>` / `<PageUp>` in the float window to navigate.
- `:JovianView` — Inspect DataFrames in a floating window (**Paging supported: 50 rows/page**).
  - Use `<PageDown>` / `<PageUp>` to navigate pages.
- `:JovianSync` — Sync your current local project to the remote server via `rsync`.

### Remote Development (SSH & Tailscale)

1.  Run **`:JovianConnect`**.
2.  Select a host from your `~/.ssh/config` or **Tailscale** nodes.
3.  Choose **"Auto-Tunnel"** mode.
4.  Specify **"Remote Directory"** (e.g., `~/projects/my-analysis`).
5.  Jovian will automatically start a remote kernel, setup SSH tunnels, and connect!
6.  Use **`:JovianSync`** to push your local data/code to the remote server.

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
	-- Visuals
	flash_highlight_group = "Visual",
	flash_duration = 300,
	float_border = "rounded", -- Border style for floating windows (single, double, rounded, solid, shadow)

	-- Python Environment
	python_interpreter = "python3",

	-- Behavior
	notify_threshold = 10,
	notify_mode = "all", -- "all", "error", "none"
	show_execution_time = true,
	plot_view_mode = "inline", -- "inline", "window"

	ui = {
		-- cell_separator_highlight:
        -- "line"  : Highlight the entire line (default).
        -- "text"  : Highlight only the text.
        -- "none"  : No highlight.
        cell_separator_highlight = "text",
		-- winblend = 0,
		layouts = {
			{
				elements = {
					{ id = "preview", size = 0.75 },
					{ id = "pin", size = 0.30 },
				},
				position = "right", -- "left", "top", "bottom"
				size = 0.30,
			},
			{
				elements = {
					{ id = "output", size = 0.65 },
					{ id = "variables", size = 0.35 },
				},
				position = "bottom",
				size = 0.25,
			},
		},
	},

	-- UI Symbols
	ui_symbols = {
		running = " Running...",
		done = " Done",
		error = " Error",
		interrupted = " Interrupted",
		stale = " Stale",
	},

	-- Magic Commands
	suppress_magic_command_errors = true,

	-- TreeSitter
	    treesitter = {
        -- Set to false to disable
        -- Set to true (default) to use built-in queries
        -- Set to a string to use a custom query
        markdown_injection = true,
        magic_command_highlight = true,
    },
})
```

</details>

## 🌲 TreeSitter Queries

To enable **Markdown highlighting** in Python comments and **Magic Command** highlighting, you need to add the plugin's query files to your Neovim configuration:

1. Create a `queries/python` directory in your Neovim config (e.g., `~/.config/nvim/queries/python/`).
2. Copy `injections.scm` and `highlights.scm` from `jovian.nvim/queries/python/` to that directory.

Neovim's TreeSitter will automatically pick up these queries.

---

## 🧠 How it Works

`jovian.nvim` bridges Neovim with a persistent Python process:

1. **Kernel Bridge** — Launches `kernel_bridge.py` in the background (local or SSH)
2. **Communication** — JSON messages via stdin/stdout
3. **Execution** — Wraps an embedded IPython kernel
4. **Plotting** — Saves plots as images, rendered via `image.nvim`

This keeps Neovim responsive while heavy computations run in the background.

---

## ☁️ Remote Data Handling

When using `jovian.nvim` with a remote host, the **Python Kernel runs on the remote machine**.

### 1. Unified Connection via `:JovianConnect`

Instead of manually adding hosts, use `:JovianConnect` to interactively pick from:
- `~/.ssh/config` entries.
- **Tailscale** nodes (requires `tailscale` CLI).

### 2. File Synchronization via `:JovianSync`

To keep your remote data in sync with local changes:
- Run `:JovianSync` to push the current directory to the `remote_cwd`.
- Run `:JovianSync <path>` to push specific files.
- Default excludes: `.git`, `__pycache__`, `.jovian_cache`.

### 3. Path Mapping (`remote_cwd`)

When connecting, Jovian asks for a **Remote Directory**.
- The remote kernel will `cd` into this directory before starting.
- Your code's relative paths (e.g., `pd.read_csv("./data.csv")`) will correctly resolve to files in that remote directory.

---

## 📚 Command Reference

<details>
<summary>Execution Commands</summary>

| Command                | Description             |
| :--------------------- | :---------------------- |
| `:JovianRun`           | Run current cell        |
| `:JovianRunAndNext`    | Run and jump to next    |
| `:JovianRunAll`        | Run all cells           |
| `:JovianRunAbove`      | Run cells up to current |
| `:JovianRunLine`       | Run current line        |
| `:JovianSendSelection` | Run selection           |
| `:JovianStart`         | Start kernel            |
| `:JovianRestart`       | Restart kernel          |
| `:JovianInterrupt`     | Interrupt execution     |

</details>

<details>
<summary>UI & Layout Commands</summary>

| Command                       | Description       |
| :---------------------------- | :---------------- |
| `:JovianOpen`                 | Open full UI      |
| `:JovianToggle`               | Toggle UI         |
| `:JovianClearREPL`            | Clear REPL        |
| `:JovianToggleVars`           | Toggle Variables  |
| `:JovianTogglePlot`           | Toggle plot mode  |
| `:JovianToggleStatus`         | Toggle cell marks |
| `:JovianPin` / `:JovianUnpin` | Pin/unpin output  |

</details>

<details>
<summary>Cell Management Commands</summary>

| Command                                       | Description    |
| :-------------------------------------------- | :------------- |
| `:JovianNextCell` / `:JovianPrevCell`         | Navigate cells |
| `:JovianNewCellBelow` / `:JovianNewCellAbove` | Insert cell    |
| `:JovianDeleteCell`                           | Delete cell    |
| `:JovianMoveCellUp` / `:JovianMoveCellDown`   | Move cell      |
| `:JovianMergeBelow`                           | Merge cells    |
| `:JovianSplitCell`                            | Split cell     |

</details>

<details>
<summary>Data & Inspection Commands</summary>

| Command             | Description       |
| :------------------ | :---------------- |
| `:JovianVars`       | Show variables    |
| `:JovianView [var]` | View DataFrame    |
| `:JovianCopy [var]` | Copy to clipboard |
| `:JovianDoc [obj]`  | View docstring    |
| `:JovianPeek [obj]` | Quick peek        |
| `:JovianProfile`    | Profile cell      |
| `:JovianClean(!)`   | Clean caches      |

</details>

<details>
<summary>Host Management Commands</summary>

| Command               | Description            |
| :-------------------- | :--------------------- |
| `:JovianConnect`      | SSH/Tailscale Connect  |
| `:JovianSync`         | Sync data via rsync    |
| `:JovianTunnelStatus` | Check tunnel health    |
| `:JovianAddHost`      | Add SSH host (Manual)  |
| `:JovianAddLocal`     | Add local (Manual)     |
| `:JovianUse`          | Switch host            |
| `:JovianRemoveHost`   | Remove host            |

</details>

<details>
<summary>Diagnostics</summary>

| Command               | Description       |
| :-------------------- | :---------------- |
| `:checkhealth jovian` | Run health checks |

</details>

---

## 🎨 Customization

Override these highlight groups to match your theme:

| Group                                         | Purpose                           |
| :-------------------------------------------- | :-------------------------------- |
| `JovianFloat`, `JovianFloatBorder`            | Floating windows                  |
| `JovianHeader`, `JovianSeparator`             | Table elements                    |
| `JovianCellMarker`                            | Cell separator highlight (`# %%`) |
| `JovianVariable`, `JovianType`, `JovianValue` | Variables pane                    |

---

## 🙏 Acknowledgements

This plugin is inspired by **[vim-jukit](https://github.com/luk400/vim-jukit)**.

