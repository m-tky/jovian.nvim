# Development Guide for jovian.nvim

This is the working notes for hacking on the plugin. Architectural overview
and end-user docs live in `CLAUDE.md` and `doc/jovian.txt`; this file focuses
on the developer workflow — how to build, test, lint, and where to look when
something breaks.

## Repository layout

```
jovian.nvim/
├── core/                       Rust backend (`jovian-core`)
│   ├── src/
│   │   ├── main.rs             tokio entry + file logging
│   │   ├── rpc.rs              msgpack-RPC framing + method dispatch
│   │   ├── kernel.rs           kernel spawn + 3 ZMQ sockets + iopub loop
│   │   ├── kernelspec.rs       kernel.json discovery
│   │   ├── protocol.rs         Jupyter wire protocol v5.4 + HMAC signing
│   │   ├── notebook.rs         `# %%` parser + sidecar JSON I/O
│   │   ├── session.rs          per-buffer state + cell↔msg_id routing
│   │   └── kitty.rs            Kitty graphics escape writer
│   └── Cargo.toml
├── lua/jovian/
│   ├── init.lua                setup() + autocmds
│   ├── commands.lua            :Jovian* user commands
│   ├── config.lua              defaults + setup()
│   ├── state.lua               single mutable plugin state
│   ├── python.lua              interpreter resolver
│   ├── cell.lua                cell ID + range + edits
│   ├── session.lua             cache cleanup + preview-on-cursor
│   ├── complete.lua            omnifunc via core's `complete` RPC
│   ├── diagnostics.lua         LSP filter for !magic commands
│   ├── highlights.lua          built-in highlight groups
│   ├── health.lua              :checkhealth jovian
│   ├── hosts.lua               registered hosts persistence
│   ├── ssh_config.lua          ~/.ssh/config + tailscale discovery
│   ├── install.lua             prebuilt binary downloader / `cargo build`
│   ├── ui.lua                  UI facade re-exporting ui/*
│   ├── ui/
│   │   ├── layout.lua          window/buffer orchestration
│   │   ├── windows.lua         low-level window helpers
│   │   ├── renderers.lua       float content (vars pane, DF viewer)
│   │   ├── virtual_text.lua    status extmarks
│   │   ├── shared.lua          REPL output + system notifications
│   │   ├── cell_frame.lua      ┌─ Code [id] ─┐ card frames
│   │   ├── markdown_cell.lua   markdown styling (headings/bold/code/img)
│   │   ├── markdown_table.lua  box-drawn markdown tables
│   │   ├── math.lua            LaTeX → Unicode for $…$/$$…$$
│   │   ├── output_render.lua   nbformat outputs → virt_lines / preview
│   │   ├── kitty.lua           Kitty Unicode-placeholder generation
│   │   ├── highlights.lua      shared color helpers
│   │   └── debounce.lua        small debouncer
│   └── backend/
│       ├── rpc.lua             vim.uv msgpack-RPC client
│       ├── core.lua            binary locator + shared client + kitty_attach
│       └── rust_kernel.lua     cell_event → UI; Vars/View via execute_collect
├── plugin/jovian.lua           VimEnter auto-setup safety net
├── doc/jovian.txt              `:h jovian`
├── queries/python/             custom TreeSitter queries (magic commands)
├── tests/                      headless test harness
├── flake.nix                   nix devShell + run-tests + nvim-jovian wrapper
└── .github/workflows/          CI (lint + tests) and release (prebuilt cores)
```

## Building

### Rust core

```bash
cd core && cargo build --release      # → core/target/release/jovian-core
```

The Lua side locates the binary in this order:
1. `$JOVIAN_CORE_BIN` (explicit override)
2. `<plugin>/core/target/release/jovian-core`
3. `$PATH` lookup for `jovian-core`

### Nix

```bash
nix develop                  # devShell with python + neovim + rust toolchain
nix build .#jovian-core      # just the Rust binary
nix build .#jovian-nvim      # vim plugin with binary bundled in
nix run .#nvim-jovian -- demo_jovian.py
```

The devShell's `shellHook` auto-builds the core on first entry and exports
`JOVIAN_CORE_BIN`, `JOVIAN_PYTHON`, and `JOVIAN_TTY`.

## Running tests

```bash
nix run .#run-tests                              # full suite
```

Individual tests need either `$JOVIAN_CORE_BIN` set or a fresh nix build:

```bash
nvim --headless -l tests/test_cell_frame.lua
nvim --headless -l tests/test_inline_outputs.lua
nvim --headless -l tests/test_kitty_images.lua    # mocked RPC
nvim --headless -l tests/test_rust_phase1.lua     # real kernel
nvim --headless -l tests/test_commands.lua        # mocked: cell editing
```

> **When you add a test file, register it in `flake.nix`'s `run-tests`
> script.** Anything outside `run-tests` is not run by CI.

The remote-SSH test is skipped unless `$JOVIAN_REMOTE_SSH_HOST` is set —
it requires a reachable host with python + ipykernel available.

## Linting and formatting

```bash
stylua .                  # auto-format Lua  (CI runs `stylua --check .`)
luacheck .                # Lua lints
ruff check .              # Python lints (demo + example files only)
cd core && cargo fmt && cargo clippy --all-targets -- -D warnings
cd core && cargo test
```

CI runs all of the above. Pre-commit hooks aren't shipped — set them up
locally if you want them.

## Architecture cheatsheet

The full picture lives in `CLAUDE.md`. The two things that catch newcomers:

1. **One sidecar drives three surfaces.** Outputs are written by the Rust
   core to `.jovian_cache/<filename>/outputs.json` in nbformat shape. The
   inline cell view, the preview pane, and the REPL window all read from
   that same JSON via `lua/jovian/ui/output_render.lua` — there is no
   separate "inline" vs "preview" rendering path.

2. **Kitty images are transmitted once.** `kitty.lua` builds Unicode
   placeholder rows whose foreground color encodes the image_id. The PNG
   bytes themselves go to the tty via `core kitty_transmit` (`a=T,U=1`).
   The placeholders survive Neovim redraws because they're real buffer or
   virt_text content — no `image.nvim` dependency.

## Contributing

### Adding a `:Jovian*` command

1. Implement the user-visible logic somewhere appropriate (`cell.lua` for
   cell editing, `core.lua` for kernel interaction, etc.).
2. Register the command in `lua/jovian/commands.lua` inside `M.setup()`.
3. Add it to `doc/jovian.txt` (the |jovian-commands| section).
4. Add it to the command table in `README.md`.
5. If it mutates buffer structure, wrap it in `cell_edit()` so the structure
   check runs after.

### Adding a UI rendering layer

1. Add the module under `lua/jovian/ui/`.
2. Add an opt-in option flag in `lua/jovian/config.lua`.
3. Wire autocmds in `lua/jovian/init.lua` (look at `cell_frame` /
   `markdown_cell` for the pattern: register unconditionally, early-return
   inside the render fn when the flag is off).
4. Add a test under `tests/` and register it in `flake.nix`.

### Extending the Rust core

Wire-protocol details live in `core/src/protocol.rs`. Any new RPC method
needs:

1. A dispatch arm in `core/src/rpc.rs` (`handle_request`).
2. A corresponding call site in `lua/jovian/backend/` (typically
   `rust_kernel.lua` or `backend/core.lua`).
3. A unit/integration test — if it's a notification, exercise it through
   `tests/test_rust_phase1.lua`-style headless flows.

The kernel talks v5.4 of the Jupyter wire protocol over three ZMQ sockets
(shell / control / iopub). HMAC-SHA256 signing is mandatory and lives in
`protocol.rs`.

## Known footguns

**Extmarks and undo.** Cell status extmarks can outlive the lines they were
attached to if you mutate the buffer without clearing them first. Always
call `UI.clear_status_extmarks(...)` before deleting cell headers — see
`commands.lua::merge_cell_below` for the canonical pattern.

**Window vs buffer options.** `conceallevel` is a window option. The Phase
2 features (cell frame, markdown styling) bump it to 2 from autocmds — if
you add a new feature that conceals source, copy the `apply_window_options`
pattern in `init.lua`.

**`vim.uv` pipes, not `jobstart`.** The msgpack-RPC client uses raw pipes
because `jobstart` strips `\n` from binary stdio. Don't "simplify" it by
switching to `jobstart`; you'll silently corrupt msgpack frames.

## Where to look when…

| Symptom | Start here |
|---|---|
| Kernel won't start | `core/src/kernel.rs`, `lua/jovian/backend/core.lua` |
| Outputs missing inline | `lua/jovian/ui/output_render.lua` + sidecar JSON |
| Image rendering broken | `:JovianDebugImages` → `core/src/kitty.rs` |
| Status extmark ghosts | `lua/jovian/ui/virtual_text.lua` + `cell.lua` edits |
| Remote kernel hangs | `core/src/kernel.rs::launch_remote`, ssh -L tunnel |
| Magic command red squigglies | `lua/jovian/diagnostics.lua` |

Logs:

- Rust core: `$XDG_CACHE_HOME/jovian/core.log` (`~/.cache/jovian/core.log`)
- Neovim: `~/.local/state/nvim/log` (RPC frames at debug level if you
  raise the level in `backend/rpc.lua`)
