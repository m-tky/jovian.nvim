# jovian.nvim 🪐

![Lua](https://img.shields.io/badge/Lua-blue.svg?style=for-the-badge&logo=lua)
![Rust](https://img.shields.io/badge/Rust-orange.svg?style=for-the-badge&logo=rust)
![Neovim](https://img.shields.io/badge/Neovim%200.10+-green.svg?style=for-the-badge&logo=neovim)

**jovian.nvim** turns Neovim into a Jupyter-like environment for Python. Edit
`.py` files using the `# %%` cell format, execute code against a live IPython
kernel, and view rich output — text, tables, errors, and plots — inline below
each cell or in a side-by-side preview window, without leaving your editor.

Execution is powered by **`jovian-core`**, a small Rust backend that speaks the
Jupyter wire protocol directly. No `libzmq`, no `pyzmq`, no Python bridge
process — just a single static binary talking msgpack-RPC to Neovim.

---

## 📖 Table of Contents

- [Features](#-features)
- [Try with Nix](#-try-with-nix)
- [Requirements](#-requirements)
- [Installation](#-installation)
- [Usage Guide](#-usage-guide)
- [Visual Features](#-visual-features)
- [Recommended Keybindings](#️-recommended-keybindings)
- [Configuration](#️-configuration)
- [How it Works](#-how-it-works)
- [Command Reference](#-command-reference)
- [Customization](#-customization)
- [Roadmap](#-roadmap)
- [Acknowledgements](#-acknowledgements)

---

## ✨ Features

| Feature | Description |
| :--- | :--- |
| **🦀 Rust core** | A single `jovian-core` binary speaks the Jupyter wire protocol directly over msgpack-RPC. No `libzmq`/`pyzmq`/Python-bridge dependencies. |
| **🚀 Low latency** | Streamed stdout/stderr, cell status, and completions come straight off the kernel's IOPUB/SHELL sockets. |
| **👀 Live preview** | Rich output (text, tables, errors, plots) in a side-by-side window, rendered from a structured output store. |
| **🃏 Inline cell cards** | Optional bordered "cards" around each cell with output rendered directly beneath it, à la notebook UIs. |
| **📝 Markdown cells** | Optional styling for `# %% [markdown]` cells: headings, bold/italic, code spans, bullets, and aligned tables. |
| **🖼️ Inline plots** | Matplotlib/Plotly images rendered in-terminal via the Kitty graphics protocol (Kitty, Ghostty, recent WezTerm). |
| **📊 Variables & DataFrames** | `:JovianVars` and `:JovianView` inspect the live namespace and paginate DataFrames. |
| **⚡ Quick eval / REPL** | Try throwaway code against the kernel without polluting `In[]`/`Out[]` history. |
| **🔁 Persistent outputs** | Cell output is cached to an `nbformat`-shaped JSON sidecar, so results survive restarts. |
| **☁️ Remote kernels** | Run the kernel on an SSH host; `jovian-core` tunnels its ZMQ ports back to localhost. Key/agent auth. |
| **🪄 Magic commands** | `%timeit`, `!ls`, and other IPython magics work, with LSP false-positives suppressed. |

---

## ⚡ Try with Nix

No install needed. If you have [Nix](https://nixos.org/), the flake bundles the
prebuilt `jovian-core` binary and a minimal Python environment:

```bash
nix run github:m-tky/jovian.nvim -- demo_jovian.py
```

The demo launches with the inline cell cards, markdown styling, and inline
output features all enabled so you can see everything at once.

---

## 📋 Requirements

> [!TIP]
> **For Nix / NixOS users**: everything below — the Rust binary, the Python
> environment, and a Kitty-capable terminal — is handled by the flake. See
> [Installation (Nix)](#using-nix-flake).

### 1. Python (essential)

A Python 3.10+ environment containing:

- **`ipykernel`** — the kernel jovian connects to.
- **`ipython`** — provides the interactive shell used by `:JovianREPL`.

That's it for the kernel. There is no `pyzmq`, `jupyter-client`, or
`jupyter-console` requirement anymore — `jovian-core` talks to the kernel
directly.

### 2. The `jovian-core` binary

The native backend. You get it one of three ways, in order of preference:

1. **Prebuilt download** (default): the plugin's `build` hook downloads the
   release binary matching your platform (Linux/macOS, x86_64/aarch64).
2. **Built from source**: if no prebuilt matches, the hook runs
   `cargo build --release` — this needs a [Rust toolchain](https://rustup.rs).
3. **Nix**: the flake drops the binary in place; nothing to download or build.

### 3. Optional

- **A Kitty-graphics terminal** ([Kitty](https://sw.kovidgoyal.org/kitty/),
  [Ghostty](https://ghostty.org/) 1.3+, recent [WezTerm](https://wezfurlong.org/wezterm/))
  — required for inline plot rendering. Without one, images are skipped; text
  output is unaffected.
- **[nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)** —
  for code highlighting and markdown injection inside cells.
- **[jupytext.nvim](https://github.com/GCBallesteros/jupytext.nvim)** — to open
  and edit `.ipynb` files as `# %%` Python.

---

## 📦 Installation

#### Using [Lazy.nvim](https://github.com/folke/lazy.nvim)

The `build` hook installs `jovian-core` (prebuilt download, or cargo fallback):

```lua
{
    "m-tky/jovian.nvim",
    build = function(plugin)
        require("jovian.install").run(plugin)
    end,
    config = function()
        require("jovian").setup({
            python_interpreter = "python3",
            -- Opt-in visuals (all off by default):
            cell_frame = true,           -- bordered cell cards
            markdown_cell_style = true,  -- styled markdown cells
            inline_outputs = true,       -- output rendered below cells
        })
    end,
}
```

#### Using Nix (Flake)

The recommended way on Nix is the **overlay**, which adds `jovian-nvim` (with
the binary bundled) to `pkgs.vimPlugins`.

```nix
# Example integration in your flake.nix
{
  inputs.jovian.url = "github:m-tky/jovian.nvim";

  outputs = { nixpkgs, jovian, ... }: {
    # 1. Apply the overlay
    pkgs = import nixpkgs {
      inherit system;
      overlays = [ jovian.overlays.default ];
    };

    # 2. Add it to your Neovim plugins like any other plugin
    # Example using Home Manager:
    programs.neovim.plugins = [
      pkgs.vimPlugins.jovian-nvim
    ];

    # 3. (Optional) Use the provided minimal Python environment
    # require("jovian").setup({
    #   python_interpreter = "${pkgs.jovian-minimal-python}/bin/python3",
    # })
  };
}
```

#### Runtime Autocompletion

Jovian provides context-aware completion powered by the kernel — dictionary
keys, DataFrame columns, and dynamic attributes that a static LSP can miss. It
is registered as `omnifunc` (trigger with `<C-x><C-o>`).

**Integration with [blink.cmp](https://github.com/Saghen/blink.cmp):**

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

### Running code

- Define cells with `# %%`. IDs (`# %% id="..."`) are generated on first run.
- `:JovianStart` connects a kernel (or it starts lazily on first run).
- `:JovianRun` runs the current cell; `:JovianRunAndNext`, `:JovianRunAll`,
  `:JovianRunAbove`, `:JovianRunLine`, and `:JovianSendSelection` cover the rest.
- Cell headers show virtual-text status: `Running…`, `Done`, `Error`, `Stale`.

### Inspecting data

- `:JovianVars` — show the live namespace in a floating window.
- `:JovianView [var]` — inspect a DataFrame (paginated, 50 rows/page; use
  `<PageDown>` / `<PageUp>`).

### Quick eval and REPL

- `:JovianEval [code]` runs a one-off expression against the kernel with
  **history disabled** — it sees all your variables but doesn't bump
  `In[]`/`Out[]` or get recorded.
- `:JovianREPL`, or pressing `i` / `e` in the Output window, opens an
  interactive loop on top of the same mechanism: type, run, repeat. An empty
  line exits. No `jupyter console` needed.

### Output window

By default the Output (REPL) window is **on-demand** — toggle it with
`:JovianToggleOutput`. Output still accumulates in the background, so the full
cross-cell log and live `\r` progress bars (tqdm) are there when you open it.
Set `output_window = "always"` to dock it, or `"off"` to drop it entirely.

### Remote kernels (SSH)

Run the kernel on a remote host while editing locally. `jovian-core` starts the
kernel over SSH and tunnels its ZMQ ports back to `localhost`, so everything
else (output, plots, completion) works identically.

1. `:JovianConnect` — pick a host from `~/.ssh/config` (or Tailscale), then
   enter the remote python and working directory. The host becomes active.
   (`:JovianAddHost` registers a host manually; `:JovianUse <name>` switches.)
2. `:JovianRun` — the kernel launches **on the remote** and output streams back.
3. `:JovianSync [path]` — `rsync` your local files to the remote working dir.
4. `:JovianTunnelStatus` — show the active host and whether the kernel is up.

**Requirements:** key- or `ssh-agent`-based auth (no interactive password
prompt), and `ipykernel` installed in the remote python. Closing Neovim or
`:JovianRestart` tears the remote kernel down cleanly.

---

## 🎨 Visual Features

Three independent, **opt-in** rendering layers. Enable any combination:

```lua
require("jovian").setup({
    cell_frame = true,          -- ┌─ [3] Code ──┐ card borders around cells
    markdown_cell_style = true, -- conceal/style # %% [markdown] cells
    inline_outputs = true,      -- render kernel output below each cell
})
```

- **`cell_frame`** draws a bordered card around each cell (code vs. markdown
  cells get distinct border colors). It shifts the right edge of cell lines, so
  it's off by default.
- **`markdown_cell_style`** conceals markdown punctuation (`#`, `**`, `` ` ``)
  in `# %% [markdown]` cells and renders headings, bold/italic, code spans,
  bullets, and box-drawn tables. The raw source re-appears on the cursor line
  while you edit.
- **`inline_outputs`** renders each cell's output (stdout/stderr, text results,
  error tracebacks, and Kitty images) as virtual lines beneath the cell. Long
  text output is elided to `inline_output_max_lines` (default 20) — the full
  text stays in the preview pane and Output window. Requires `cell_frame`.

Toggle at runtime with `:JovianToggleCellFrame` and `:JovianToggleMarkdownStyle`.

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
map("n", "<leader>je", "<cmd>JovianEval<CR>", { desc = "Quick eval" })

-- Navigation
map("n", "]c", "<cmd>JovianNextCell<CR>", { desc = "Next Cell" })
map("n", "[c", "<cmd>JovianPrevCell<CR>", { desc = "Prev Cell" })
```

---

## ⚙️ Configuration

<details>
<summary>Click to expand the full configuration options</summary>

```lua
require("jovian").setup({
    -- Visuals
    flash_highlight_group = "Visual",
    flash_duration = 300,
    float_border = "rounded", -- single | double | rounded | solid | shadow

    -- Python
    python_interpreter = "python3", -- or set $JOVIAN_PYTHON

    -- Behavior
    notify_threshold = 10,   -- seconds before a long run notifies
    notify_mode = "all",     -- "all" | "error" | "none"
    show_execution_time = true,
    folding = false,         -- cell-based folds for Python files
    dataframe_page_size = 50,

    -- Output (REPL) window: "ondemand" (default) | "always" | "off"
    output_window = "ondemand",

    -- Opt-in visual layers (all off by default)
    cell_frame = false,
    markdown_cell_style = false,
    inline_outputs = false,        -- requires cell_frame
    inline_output_max_lines = 20,  -- elide longer inline text output

    -- Inline image placement (terminal cells)
    image_rows = 14,
    image_cols = 56,
    -- Preview-pane image sizing (parses PNG/GIF headers; never upscales)
    preview_cell_pixel_height = 16,
    preview_cell_pixel_aspect = 0.5,
    preview_image_max_cols = nil,  -- nil = fill the preview text area
    preview_image_max_rows = nil,

    -- Default persistent panels. Variables and Output are intentionally not
    -- here: Variables is a float via :JovianVars, Output is governed by
    -- `output_window` above.
    ui = {
        cell_separator_highlight = "text", -- "line" | "text" | "none"
        layouts = {
            {
                elements = {
                    { id = "preview", size = 0.70 },
                    { id = "pin", size = 0.30 },
                },
                position = "left", -- "left" | "right" | "top" | "bottom"
                size = 0.35,
            },
        },
    },

    -- Cell status virtual text
    ui_symbols = {
        running = " Running...",
        done = " Done",
        error = " Error",
        interrupted = " Interrupted",
        stale = " Stale",
    },

    -- Magic commands
    suppress_magic_command_errors = true,

    -- TreeSitter (true | false | custom query string)
    treesitter = {
        markdown_injection = true,
        magic_command_highlight = true,
    },

    -- Per-group highlight overrides — see Customization below.
    highlights = {},
})
```

</details>

---

## 🧠 How it Works

```
:JovianRun
  → core.send_cell()
  → jovian-core (Rust) execute_request over the SHELL socket
      ├─ IOPUB stream/status/result/error events
      │    → msgpack-RPC notifications → handlers → UI (inline / preview / pin)
      └─ outputs mirrored to .jovian_cache/<filename>/outputs.json (sidecar)
```

- **`jovian-core`** (Rust, in `core/`) spawns and owns the IPython kernel,
  signs messages with HMAC-SHA256, and speaks the Jupyter v5 wire protocol over
  pure-Rust ZeroMQ. It exposes a small msgpack-RPC API over stdio.
- **Neovim** spawns the binary via `vim.uv` pipes and exchanges length-prefixed
  msgpack frames (`request` / `response` / `notification`).
- **Outputs** are stored in an `nbformat`-shaped JSON sidecar at
  `.jovian_cache/<filename>/outputs.json`, keyed by cell ID. The inline,
  preview, and pin renderers all read from this structured store — output is
  not tied to a markdown file format.
- **Images** are transmitted to the terminal via the Kitty graphics protocol
  (Unicode placeholder mode); Neovim only places the placeholder glyphs.
- **Remote kernels** are the same path with `ssh` standing in for the local
  `python`: the remote picks its own free ports and writes the connection file,
  then a single `ssh -L …` process both forwards those ports to `localhost` and
  runs the kernel — so the ZMQ layer connects to `127.0.0.1` either way.

Why a `.py` + `# %%` source format with IDs? Cell IDs stored in the file let
the output sidecar correlate with specific cells across edits and sessions,
while keeping the source plain, diff-friendly, and source-controllable.

---

## 📚 Command Reference

<details>
<summary>Execution</summary>

| Command | Description |
| :--- | :--- |
| `:JovianStart` | Start / connect a kernel |
| `:JovianRun` | Run current cell |
| `:JovianRunAndNext` | Run cell and jump to next |
| `:JovianRunAll` | Run all cells |
| `:JovianRunAbove` | Run all cells above the cursor |
| `:JovianRunLine` | Run the current line |
| `:JovianSendSelection` | Run the visual selection |
| `:JovianRestart` | Restart the kernel |
| `:JovianInterrupt` | Interrupt execution (SIGINT) |
| `:JovianEval` | Quick-eval an expression (no history) |
| `:JovianREPL` | Interactive eval loop on the live kernel |

</details>

<details>
<summary>UI & Layout</summary>

| Command | Description |
| :--- | :--- |
| `:JovianOpen` / `:JovianToggle` | Open / toggle the panels |
| `:JovianToggleOutput` | Toggle the Output (REPL) window |
| `:JovianToggleVars` | Toggle the Variables pane |
| `:JovianToggleStatus` | Toggle cell status virtual text |
| `:JovianToggleCellFrame` | Toggle bordered cell cards |
| `:JovianToggleMarkdownStyle` | Toggle markdown cell styling |
| `:JovianPin` / `:JovianUnpin` | Pin / unpin current cell output |
| `:JovianTogglePin` | Toggle the pinned output window |
| `:JovianClearREPL` | Clear the Output buffer |

</details>

<details>
<summary>Cell management</summary>

| Command | Description |
| :--- | :--- |
| `:JovianNextCell` / `:JovianPrevCell` | Navigate cells |
| `:JovianNewCellBelow` / `:JovianNewCellAbove` | Insert a cell |
| `:JovianNewMarkdownCellBelow` | Insert a markdown cell |
| `:JovianDeleteCell` | Delete the current cell |
| `:JovianMoveCellUp` / `:JovianMoveCellDown` | Reorder cells |
| `:JovianSplitCell` | Split the cell at the cursor |
| `:JovianMergeBelow` | Merge with the next cell |

</details>

<details>
<summary>Data & inspection</summary>

| Command | Description |
| :--- | :--- |
| `:JovianVars` | Show variables in a float |
| `:JovianView [var]` | Inspect a variable / DataFrame |

</details>

<details>
<summary>Remote / host</summary>

| Command | Description |
| :--- | :--- |
| `:JovianConnect` | Pick an SSH/Tailscale host and activate it |
| `:JovianAddHost` / `:JovianAddLocal` | Register a host manually |
| `:JovianUse [name]` / `:JovianRemoveHost [name]` | Switch / remove host |
| `:JovianSync [path]` | `rsync` local files to the remote host |
| `:JovianTunnelStatus` | Show the active remote host + kernel state |

</details>

<details>
<summary>Cache & diagnostics</summary>

| Command | Description |
| :--- | :--- |
| `:JovianClean[!]` | Clean stale / orphaned cache |
| `:JovianClearCache[!]` | Clear cell output cache |
| `:JovianClearDiag` | Clear LSP diagnostics |
| `:JovianDebugImages` | Probe the Kitty image pipeline |
| `:checkhealth jovian` | Validate dependencies |

</details>

---

## 🎨 Customization

Override highlight groups to match your theme. Most groups default to a
fallback chain that picks up your colorscheme's own heading/accent colors, so
they look reasonable out of the box. Override per-group via the `highlights`
table — a **string** is treated as a link target, a **table** as `nvim_set_hl`
attributes:

```lua
require("jovian").setup({
    highlights = {
        cell_border_code = "Function",            -- link
        cell_border_markdown = { fg = "#e0af68" },  -- attrs
        md_h1 = "@markup.heading.1.markdown",
        out_error = "ErrorMsg",
    },
})
```

| Area | Groups |
| :--- | :--- |
| Cell cards | `JovianCellBorderCode`, `JovianCellBorderMarkdown` |
| Markdown cells | `JovianMdH1`…`JovianMdH6`, `JovianMdBold`, `JovianMdEm`, `JovianMdCode`, `JovianMdBullet`, `JovianMdQuote`, `JovianMdTableDivider`, `JovianMdTableHeader` |
| Inline / preview output | `JovianOutDivider`, `JovianOutStdout`, `JovianOutStderr`, `JovianOutResult`, `JovianOutError` |
| Floats & panes | `JovianFloat`, `JovianFloatBorder`, `JovianHeader`, `JovianSeparator`, `JovianVariable`, `JovianType`, `JovianValue` |
| Cell separator | `JovianCellMarker` |

---

## 🙏 Acknowledgements

- **[jupynvim](https://github.com/sheng-tse/jupynvim)** — the Rust backend
  architecture (a single core binary speaking the Jupyter wire protocol over
  msgpack-RPC, with Kitty placeholder image rendering) is modeled directly on
  jupynvim. Many thanks to its author.
- **[vim-jukit](https://github.com/luk400/vim-jukit)** — the original
  inspiration for jovian's cell-based workflow.
