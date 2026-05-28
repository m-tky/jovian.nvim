# jovian.nvim — Claude Code Context

## What This Is

A Neovim plugin for interactive Python development using `# %%` cell markers,
similar to VS Code's Jupyter extension. Executes code against a live Jupyter
kernel and displays results inline in the cell, in a side preview window, and
in a REPL/output window. Plots render as real images via the Kitty graphics
protocol.

## Architecture

### Rust backend (`jovian-core`)

A single Rust binary (`core/`) owns all kernel communication. The Lua
front-end spawns it once and talks to it over **msgpack-RPC on stdio**.

- `core/src/main.rs` — tokio entry point + file logging (`$XDG_CACHE/jovian/core.log`)
- `core/src/rpc.rs` — msgpack-RPC framing (`<u32 BE len><payload>`) + method dispatch
- `core/src/protocol.rs` — Jupyter wire protocol v5.4 + HMAC-SHA256 signing
- `core/src/kernel.rs` — kernel spawn, the 3 ZMQ sockets (shell/control/iopub),
  iopub event loop. Uses the **pure-rust `zeromq` crate** (no system libzmq).
- `core/src/kernelspec.rs` — discover `kernel.json` specs with version fallback
- `core/src/notebook.rs` — `# %%` source parser + sidecar JSON output store
- `core/src/session.rs` — per-buffer state, cell↔msg_id routing, output collector
- `core/src/kitty.rs` — Kitty graphics protocol, writes escapes straight to the tty

The kernel talks the Jupyter wire protocol directly; there is **no Python
bridge process** and **no libzmq FFI** (both removed in Phase 5).

### Lua front-end

- `lua/jovian/backend/rpc.lua` — msgpack-RPC client over `vim.uv` pipes
  (NOT `jobstart` — it strips `\n` from binary stdio)
- `lua/jovian/backend/core.lua` — locates the `jovian-core` binary, owns the
  shared client singleton, performs `kitty_attach` (resolving the real pts
  via `/proc/self/fd` or `$JOVIAN_TTY`)
- `lua/jovian/backend/rust_kernel.lua` — translates RPC `cell_event`
  notifications into UI updates; implements Vars/View via `execute_collect`
- `lua/jovian/install.lua` — downloads a prebuilt binary or `cargo build`s it
  (lazy.nvim `build` hook); under nix the flake bundles the binary instead

### Key data flow

```
:JovianRun
  → core.send_cell() → core.send_payload(code, cell_id)
  → rust_kernel.execute(code, cell_id)
      reparse (buffer text → cell models) + execute RPC
  → jovian-core: execute_request over ZMQ shell socket
      iopub events → session.apply_event → outputs.json + cell_event notify
  → rust_kernel.on_cell_event
      ├─ UI.append_to_repl / append_stream_text   (REPL window)
      ├─ UI.set_cell_status                        (Running/Done/Error extmark)
      └─ cell_frame.schedule / preview re-render   (inline + preview, reads sidecar)
```

### Output rendering (one source of truth)

Outputs live in a per-file sidecar JSON, nbformat-shaped:

```
<file_dir>/.jovian_cache/<filename>/outputs.json
  { "version": 1, "cells": { "<cell_id>": { execution_count, outputs[] } } }
```

`lua/jovian/ui/output_render.lua` reads that JSON and renders the SAME outputs
to three surfaces:
- **inline** — `cell_frame.lua` embeds `├ Out[N] ┤` + output rows in the cell's
  bottom `virt_lines` (opt-in: `inline_outputs`)
- **preview pane** — `render_to_buffer` writes text lines + per-line hl extmarks
- **REPL/output window** — `rust_kernel` writes ANSI + placeholders to the term channel

Images (`image/png|gif|jpeg`) are transmitted once via `kitty.lua`
(`ensure_transmitted` → core `kitty_transmit` RPC, `a=T,U=1,c=N,r=N`) and
rendered as Unicode-placeholder rows whose fg color encodes the image_id.

### Module responsibilities

| Module | Role |
|---|---|
| `init.lua` | `setup()` entry point; registers autocmds |
| `config.lua` | Default options; `M.options` is the live config table |
| `state.lua` | Single global state table; all mutable plugin state lives here |
| `core.lua` | Kernel lifecycle + execution + Vars/View — delegates to rust_kernel |
| `backend/core.lua` | jovian-core binary locator + shared RPC client + kitty_attach |
| `backend/rpc.lua` | vim.uv msgpack-RPC client |
| `backend/rust_kernel.lua` | cell_event → UI; Vars/View via execute_collect |
| `cell.lua` | Cell ID management, range detection, cell edit operations |
| `session.lua` | Preview-on-cursor, cache cleanup, structure change tracking |
| `commands.lua` | Registers all `:Jovian*` user commands |
| `complete.lua` | `omnifunc` via the core `complete` RPC |
| `hosts.lua` / `ssh_config.lua` | SSH host discovery + config persistence. When a host is active, `rust_kernel.start` forwards it to jovian-core, which owns the SSH tunnel + remote kernel launch (`Kernel::launch_remote`). |
| `ui.lua` | Public UI facade; re-exports from ui/ submodules |
| `ui/layout.lua` / `ui/windows.lua` | Window/buffer orchestration |
| `ui/virtual_text.lua` | Cell status extmarks (Running/Done/Error/Stale) |
| `ui/renderers.lua` | Float content: variables pane, DataFrame viewer |
| `ui/shared.lua` | REPL terminal output + system notifications |
| `ui/cell_frame.lua` | Card-frame extmarks + inline output block (opt-in) |
| `ui/markdown_cell.lua` | Markdown cell styling: headings/bold/code + inline images (data-URI / file-path, via Kitty) (opt-in) |
| `ui/markdown_table.lua` | Box-drawn markdown tables, render-markdown.nvim style: overlays each source row in place (conceal raw + inline virt_text), borders as virt_lines, CJK-aware widths, `table_border` presets + alignment marks. Single line per row (no wrap/`<br>`) |
| `ui/output_render.lua` | nbformat outputs → virt_lines / preview lines |
| `ui/kitty.lua` | Kitty Unicode-placeholder generation + async transmit |
| `diagnostics.lua` | LSP diagnostic filter for magic commands (`!ls`, `%timeit`) |

---

## Development

### Building the Rust core

```bash
cd core && cargo build --release      # outputs core/target/release/jovian-core
```
The nix devShell auto-builds it on first entry. The Lua side finds it via
`$JOVIAN_CORE_BIN`, then `<plugin>/core/target/release/jovian-core`, then `$PATH`.

### Running tests

```bash
nix run .#run-tests        # full suite (builds core, runs all test files)
```
Individual files (need the core binary on `$JOVIAN_CORE_BIN` or a nix build):
```bash
nvim --headless -l tests/test_cell_frame.lua       # cell frame + markdown styling
nvim --headless -l tests/test_inline_outputs.lua   # sidecar JSON → inline/preview
nvim --headless -l tests/test_kitty_images.lua     # placeholder geometry (stubbed RPC)
nvim --headless -l tests/test_rust_phase1.lua      # real kernel: spawn+run+stream
nvim --headless -l tests/test_commands.lua         # mocked: cell navigation/editing
```
**When adding a test file, register it in `flake.nix`'s `run-tests` script and
re-run the whole suite** — anything outside `run-tests` isn't covered by CI.

### Formatting & linting

```bash
stylua .                  # auto-format Lua  (stylua --check . in CI)
luacheck .                # lint Lua
ruff check .              # lint Python (only the demo / example files now)
cd core && cargo fmt && cargo clippy
```

### Nix

```bash
nix develop               # Python + Neovim + Rust toolchain; auto-builds core
nix build .#jovian-core   # just the Rust binary
nix build .#jovian-nvim   # vim plugin with the binary bundled in
nix run .#nvim-jovian -- demo_jovian.py   # full demo (Rust backend, all features)
```

---

## Config Options Reference

```lua
require("jovian").setup({
    -- Python
    python_interpreter = "python3",   -- or JOVIAN_PYTHON env var
                                      -- an absolute path → used as the kernel's
                                      -- python directly (bypasses kernelspec lookup)

    -- UI
    float_border       = "rounded",   -- single/double/rounded/solid/shadow
    flash_duration     = 300,         -- ms, highlight on cell run
    show_execution_time = true,
    notify_threshold   = 10,          -- seconds before showing a notification
    notify_mode        = "all",       -- "all" | "error" | "none"
    dataframe_page_size = 50,

    -- Phase 2/3/4 visuals (opt-in)
    cell_frame          = false,      -- ┌─ Code [id] ─┐ card borders
    cell_frame_priority = 100,        -- side-bar extmark priority; raise (e.g. 4096)
                                      -- to draw the frame above indent-guide plugins
    markdown_cell_style = false,      -- conceal #/**bold**/tables in markdown cells
    table_border        = "round",    -- round/none/heavy/double (render-markdown style)
    inline_outputs      = false,      -- render outputs below the cell (needs cell_frame)
    folding             = false,      -- cell-based folds for Python files

    -- Image sizing (Kitty graphics)
    image_rows = 14, image_cols = 56,            -- inline cell output block
    preview_cell_pixel_height = 16,              -- px height of one terminal cell
    preview_cell_pixel_aspect = 0.5,             -- cell width/height ratio
    -- preview scales each image from its PNG/GIF header dims, never upscales
    -- past native size, capped to the preview window

    -- Highlight overrides — string = :hi link target, table = nvim_set_hl attrs.
    -- nil = follow the colorscheme / built-in fallback.
    highlights = {
        cell_border_code = nil,       -- code cell frame (default: Function-family)
        cell_border_markdown = nil,   -- markdown cell frame (default: WarningMsg-family)
        md_h1 = nil, md_h2 = nil, ... md_h6 = nil,   -- heading levels
        md_bold = nil, md_code = nil, md_bullet = nil, md_quote = nil,
        md_table_divider = nil, md_table_header = nil,
        out_divider = nil, out_stdout = nil, out_stderr = nil,
        out_result = nil, out_error = nil,
    },

    ui = {
        cell_separator_highlight = "text",  -- "text" | "line" | "none"
        layouts = { ... },                  -- see config.lua for structure
    },

    ui_symbols = {
        running = " Running...", done = " Done", error = " Error",
        interrupted = " Interrupted", stale = " Stale",
    },

    suppress_magic_command_errors = true,

    -- use_rust_core is recognised but inert — the Rust backend is the only
    -- path now (the legacy Python bridge was removed in Phase 5).
})
```

---

## Commands

### Execution
| Command | Description |
|---|---|
| `:JovianStart` | Start / connect to kernel |
| `:JovianRun` | Run current cell |
| `:JovianRunAndNext` | Run cell and jump to next |
| `:JovianRunAll` | Run all cells top-to-bottom |
| `:JovianRunAbove` | Run all cells above cursor |
| `:JovianRunLine` | Run current line |
| `:JovianSendSelection` | Run visual selection |
| `:JovianRestart` | Restart kernel |
| `:JovianInterrupt` | Interrupt kernel |
| `:JovianREPL` | Open `jupyter console` attached to the running kernel |

### UI
| Command | Description |
|---|---|
| `:JovianOpen` / `:JovianToggle` | Open / toggle all panels |
| `:JovianToggleVars` | Toggle variables pane |
| `:JovianToggleStatus` | Toggle cell status virtual text |
| `:JovianToggleCellFrame` | Toggle cell card frames |
| `:JovianToggleMarkdownStyle` | Toggle markdown cell styling |
| `:JovianTogglePin` / `:JovianPin` / `:JovianUnpin` | Pinned output window |
| `:JovianClearREPL` | Clear the REPL output buffer |

### Cell navigation & editing
| Command | Description |
|---|---|
| `:JovianNextCell` / `:JovianPrevCell` | Jump between cells |
| `:JovianNewCellBelow` / `Above` | Insert new cell |
| `:JovianNewMarkdownCellBelow` | Insert markdown cell |
| `:JovianDeleteCell` | Delete current cell |
| `:JovianMoveCellUp` / `Down` | Reorder cells |
| `:JovianSplitCell` | Split cell at cursor |
| `:JovianMergeBelow` | Merge current cell with next |

### Inspection & data
| Command | Description |
|---|---|
| `:JovianVars` | Show variables pane |
| `:JovianView [var]` | Paginated DataFrame viewer |

(`:JovianDoc`, `:JovianPeek`, `:JovianCopy`, `:JovianBackend`,
`:JovianTogglePlot` were removed — use LSP hover / a one-off cell instead.)

### Remote / host
| Command | Description |
|---|---|
| `:JovianConnect` | Pick an SSH/Tailscale host and activate it |
| `:JovianAddHost` / `:JovianAddLocal` | Register host |
| `:JovianUse [name]` / `:JovianRemoveHost [name]` | Switch / remove host |
| `:JovianSync [path]` | rsync files to remote host |
| `:JovianTunnelStatus` | Show active remote host + kernel state |

> Remote kernels run through the Rust core: when an SSH host is active,
> `start_kernel` calls `Kernel::launch_remote`, which bootstraps the kernel on
> the remote (remote picks its own ports), then runs a single `ssh -L …`
> process that both forwards the 5 ZMQ ports to localhost and execs the kernel.
> The ZMQ layer connects to `127.0.0.1` either way. Key/agent SSH auth only;
> no remote kernelspec discovery (assumes `<python> -m ipykernel_launcher`).

### Misc
| Command | Description |
|---|---|
| `:JovianClean[!]` | Clean stale/orphaned cache |
| `:JovianClearCache[!]` | Clear cell output cache |
| `:JovianClearDiag` | Clear LSP diagnostics |
| `:JovianDebugImages` | Probe the Kitty image pipeline (reports attach/transmit errors) |
| `:checkhealth jovian` | Validate dependencies |

---

## Design Decisions

**Why a Rust core instead of the old Python bridge + libzmq FFI?**
One binary talks the Jupyter wire protocol directly (pure-rust zeromq, no
system libzmq), owns nbformat I/O, and writes Kitty graphics escapes to the
tty. It replaced ~1700 lines of dual-path Lua/Python with lower latency and a
single code path. Modeled on sheng-tse/jupynvim's architecture.

**Why `.py` + `# %% id="..."` (not `.ipynb`)?**
The source stays a plain, git-diffable Python file. Outputs live in a separate
sidecar JSON so the `.py` never carries base64 blobs. IDs in the header line
correlate cached outputs with cells across edits.

**Why a sidecar JSON instead of per-cell markdown files?**
One nbformat-shaped store feeds all three render surfaces (inline / preview /
REPL) identically, preserves full output fidelity (images, HTML, errors), and
survives nvim restarts. Outputs from a previous session render with a
`(cached)` tag until re-run.

**Why Kitty Unicode placeholders (not `image.nvim`)?**
No external Lua dependency; the Rust core transmits PNG bytes to the tty once
and the placeholder chars (with image_id in their fg color) survive Neovim
redraws because they're real buffer/virt_text. Requires a Kitty-graphics
terminal (Kitty, Ghostty 1.3+, recent WezTerm).

**Why are the visual layers opt-in?**
`cell_frame` / `markdown_cell_style` overlay extmarks and set window
`conceallevel`; `inline_outputs` needs a Kitty terminal. Defaulting them off
keeps the plugin unsurprising for users who just want execution + preview.
