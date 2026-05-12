# jovian.nvim — Claude Code Context

## What This Is

A Neovim plugin for interactive Python development using `# %%` cell markers,
similar to VS Code's Jupyter extension. Executes code against a live IPython
kernel and displays results in a side-by-side markdown preview window.

## Architecture

### Dual-Bridge Design

Two communication paths to the Python kernel run in parallel:

**Python Bridge** (always active)
- `lua/jovian/backend/kernel_bridge.py` runs as a subprocess
- Neovim spawns it via `vim.fn.jobstart`, talks over stdin/stdout JSON lines
- Handles: execution results, variable inspection, DataFrame views, image
  saving, clipboard copy, remote file sync
- Message format: `{"type": "...", ...}` lines received in `core.lua` →
  dispatched to `handlers.lua`

**Native Lua/ZMQ Messenger** (active when libzmq is available)
- `lua/jovian/backend/zmq.lua` — FFI wrapper around system libzmq
- `lua/jovian/backend/messenger.lua` — Jupyter wire protocol (HMAC-SHA256)
- Connects directly to the kernel's IOPUB and SHELL ZMQ sockets
- Handles: real-time stream output, cell status updates (busy/idle),
  completion requests — with lower latency than the Python bridge
- Activated automatically; falls back to Python bridge if libzmq is missing
- `State.lua_shell_socket` is non-nil when this path is active

When both are running, `handlers.handle_stream` skips Python bridge stream
messages to avoid duplicates (checks `State.lua_shell_socket`).

### Key Data Flow

```
User runs :JovianRun
  → core.send_cell()
  → core.send_payload(code, cell_id, filename)
      ├─ [native path] messenger.send_message(shell_socket, execute_request)
      │    ZMQ IOPUB → timer poll → status/stream updates → UI
      └─ [bridge path] chan_send(job_id, JSON)
           kernel_bridge.py → result_ready JSON → handlers.handle_result_ready
               → session.save_execution_result (writes .md + .png to cache)
               → UI.open_markdown_preview (renders in preview window)
```

### Module Responsibilities

| Module | Role |
|---|---|
| `init.lua` | `setup()` entry point; registers autocmds |
| `config.lua` | Default options; `M.options` is the live config table |
| `state.lua` | Single global state table; all mutable plugin state lives here |
| `core.lua` | Kernel lifecycle + execution + inspection commands |
| `cell.lua` | Cell ID management, range detection, cell edit operations |
| `session.lua` | Cache I/O, stale detection, structure change tracking |
| `handlers.lua` | Routes JSON messages from the Python bridge to UI/state |
| `commands.lua` | Registers all `:Jovian*` user commands |
| `hosts.lua` | Persists SSH/local host configs to `stdpath("data")/jovian/hosts.json` |
| `tunnel.lua` | SSH port-forwarding for remote kernels |
| `ui.lua` | Public UI facade; re-exports from ui/ submodules |
| `ui/layout.lua` | Window layout orchestration (open/toggle/resize) |
| `ui/windows.lua` | Low-level window/buffer creation |
| `ui/virtual_text.lua` | Cell status extmarks (Running/Done/Error/Stale) |
| `ui/renderers.lua` | Float window content: variables, DataFrames, peek/doc |
| `ui/shared.lua` | Terminal output (REPL buffer) and system notifications |
| `diagnostics.lua` | LSP diagnostic filter for magic commands (`!ls`, `%timeit`) |
| `complete.lua` | `omnifunc` completion via kernel |
| `inline_images.lua` | Inline plot rendering (requires `image.nvim`; opt-in) |

### Cache Layout

```
<file_dir>/.jovian_cache/<filename>/
  <cell_id>.md          — markdown output for preview window
  <cell_id>_<ts>_<n>.png — plot images
```

Cache files are cleaned on save/exit (`session.clean_stale_cache`) and when
source files are deleted (`session.clean_orphaned_caches`).

---

## Development

### Running Tests

```bash
nvim -l tests/test_commands.lua
nvim -l tests/test_async_flow.lua
nvim -l tests/test_resize_layout.lua
nvim -l tests/edge_cases.lua      # requires a live Python kernel
```

Tests use a mocked Vim API. Non-zero exit = failure.

### Formatting & Linting

```bash
stylua .                  # auto-format Lua
stylua --check .          # check only (used in CI)
luacheck .                # lint
ruff check .              # lint Python files
```

### Nix Dev Environment

```bash
nix develop               # enters shell with Python + Neovim pre-configured
nix run .#run-tests       # runs all tests via the Nix test runner
```

---

## Config Options Reference

```lua
require("jovian").setup({
    -- Python
    python_interpreter = "python3",   -- or JOVIAN_PYTHON env var

    -- UI
    float_border       = "rounded",   -- single/double/rounded/solid/shadow
    flash_duration     = 300,         -- ms, highlight on cell run
    show_execution_time = true,
    notify_threshold   = 10,          -- seconds before showing a notification
    notify_mode        = "all",       -- "all" | "error" | "none"
    plot_view_mode     = "inline",    -- "inline" | "window"
    dataframe_page_size = 50,

    -- Opt-in features (off by default)
    inline_images      = false,       -- requires image.nvim
    folding            = false,       -- cell-based folds for Python files

    -- Cell separator highlight
    ui = {
        cell_separator_highlight = "text",  -- "text" | "line" | "none"
        layouts = { ... },                  -- see config.lua for structure
    },

    -- Virtual text symbols
    ui_symbols = {
        running     = " Running...",
        done        = " Done",
        error       = " Error",
        interrupted = " Interrupted",
        stale       = " Stale",
    },

    -- Magic command LSP suppression
    suppress_magic_command_errors = true,

    -- Native ZMQ path (disable if libzmq causes issues)
    use_lua_native_shell = true,
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
| `:JovianInterrupt` | Send SIGINT to kernel |
| `:JovianREPL` | Open interactive IPython console connected to the running kernel |

### UI
| Command | Description |
|---|---|
| `:JovianOpen` | Open all panels |
| `:JovianToggle` | Toggle all panels |
| `:JovianToggleVars` | Toggle variables pane |
| `:JovianToggleStatus` | Toggle cell status virtual text |
| `:JovianTogglePlot` | Toggle inline/window plot mode |
| `:JovianTogglePin` | Toggle pinned output window |
| `:JovianPin` / `:JovianUnpin` | Pin/unpin current cell output |
| `:JovianClearREPL` | Clear the REPL output buffer |

### Cell Navigation & Editing
| Command | Description |
|---|---|
| `:JovianNextCell` / `:JovianPrevCell` | Jump between cells |
| `:JovianNewCellBelow` / `Above` | Insert new cell |
| `:JovianNewMarkdownCellBelow` | Insert markdown cell |
| `:JovianDeleteCell` | Delete current cell |
| `:JovianMoveCellUp` / `Down` | Reorder cells |
| `:JovianSplitCell` | Split cell at cursor |
| `:JovianMergeBelow` | Merge current cell with next |

### Inspection & Data
| Command | Description |
|---|---|
| `:JovianVars` | Show variables in float |
| `:JovianView [var]` | Inspect variable / DataFrame |
| `:JovianCopy [var]` | Copy variable to clipboard |
| `:JovianDoc [obj]` | Show docstring |
| `:JovianPeek [obj]` | Quick type/value preview |

### Remote / Host
| Command | Description |
|---|---|
| `:JovianConnect` | Interactive SSH/Tunnel setup wizard |
| `:JovianAddHost` / `:JovianAddLocal` | Register host |
| `:JovianUse [name]` | Switch active host |
| `:JovianRemoveHost [name]` | Remove host |
| `:JovianSync [path]` | rsync files to remote host |
| `:JovianTunnelStatus` | Show active tunnel info |

### Misc
| Command | Description |
|---|---|
| `:JovianClean[!]` | Clean stale/orphaned cache |
| `:JovianClearCache[!]` | Clear cell output cache |
| `:JovianClearDiag` | Clear LSP diagnostics |
| `:JovianRenderImages` | Force render inline images (when `inline_images=true`) |
| `:JovianBackend` | Print matplotlib backend |
| `:checkhealth jovian` | Validate dependencies |

---

## Design Decisions

**Why a Python bridge + native ZMQ, not just one?**
The Python bridge handles complex tasks (variable serialization, image saving,
SSH sync) that would be painful in Lua. The native ZMQ path gives sub-20ms
stream output and completion latency, which the subprocess JSON round-trip
can't match.

**Why `# %%` cell IDs in-file?**
Cell outputs are cached to `.jovian_cache/<filename>/<id>.md`. IDs stored in
the file survive across sessions and allow the cache to be correlated with
specific cells even after editing. IDs are auto-generated on first execution.

**Why `inline_images` defaults to false?**
`image.nvim` is a hard dependency for rendering and requires a terminal with
Kitty/Sixel protocol. Most users don't have this; gating it avoids silent
failures.

**Why `folding` defaults to false?**
Silently overriding fold settings on all Python files is surprising behavior.
Users who want cell-based folding opt in explicitly.

**Why `JovianREPL` uses `jupyter console --existing`?**
It attaches to the same kernel session that cell execution uses — variables
defined in cells are immediately available in the REPL and vice versa. Falls
back to standalone IPython if no connection file is available.
