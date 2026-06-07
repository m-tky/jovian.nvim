# Changelog

All notable changes to jovian.nvim are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it leaves `0.x`.

## [Unreleased]

## [0.2.0] — 2026-06-07

A correctness + UX release. Same architecture as 0.1.0 (Rust core,
single `jovian-core` binary, msgpack-RPC stdio), but a long backlog
of reliability fixes and a handful of substantial new features.

### Added
- **Native `.ipynb` editing.** `:edit foo.ipynb` (or `nvim foo.ipynb`)
  is hijacked by BufReadCmd / BufWriteCmd; the buffer shows the
  rendered `# %%` cell view, `:w` re-serializes back to nbformat v4.
  On-disk file stays Jupyter format. Outputs round-trip through the
  existing sidecar.
- **`:JovianImport` / `:JovianExport`** for one-shot `.ipynb` ↔ `.py +
  sidecar` conversion (separate from the live BufReadCmd path).
- **Cell tags.** `# %% id="..." tags=["slow","skip"]` — jupytext-
  compatible syntax. Driven by two new commands: `:JovianRunOnly
  <tag>...` and `:JovianRunAllExcept <tag>...`. Tags round-trip
  through .ipynb metadata.
- **`:JovianRestartAndRunAll`** — JupyterLab-style "I changed something
  fundamental, redo from scratch."
- **`:JovianInspect [expr]`** — wires the kernel's `inspect_request`
  (Jupyter's `?foo`) to a floating docstring window.
- **`:JovianMergeAbove`** — symmetric to the existing `:JovianMergeBelow`.
- **`default_keymaps = true`** option (off by default) — installs the
  buffer-local keymap set from `lua/jovian/keymaps.lua` on filetype=python.
- **RunAll progress notification.** Multi-cell runs emit a final summary
  ("8/8 cells done in 47s") plus a desktop notification when the batch
  crosses `notify_threshold`.
- **Per-cell elapsed time.** The status extmark suffix is now `(230ms)`
  / `(1.3s)` / `(5m12s)` instead of the wall-clock timestamp; uses
  `vim.uv.hrtime` for sub-second precision.
- **Help file** (`doc/jovian.txt`) with `:h jovian` coverage of every
  command, option, and highlight group; auto-generated tags ignored.
- **`plugin/jovian.lua`** — VimEnter auto-setup safety net so non-lazy
  plugin managers get working `:Jovian*` commands without an explicit
  `setup()` call.
- **Repo hygiene**: `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  GitHub issue / PR templates.

### Fixed
- **Kernel-died detection.** A new tokio watcher emits a `kernel_died`
  notification when the child process exits on its own (segfault, OOM,
  remote disconnect). The Lua side marks running cells as errored and
  tells the user to `:JovianRestart`. Previously a crashed kernel
  hung the UI on "Running..." indefinitely.
- **`kernel_info_request` handshake at startup.** `start_kernel` now
  waits for the kernel to respond on the shell socket before returning;
  the first `:JovianRun` no longer races the ZMQ bind.
- **Atomic sidecar writes.** `write_sidecar` now writes to `.tmp` and
  renames, so a concurrent reader never sees a half-written JSON file.
- **Debounced sidecar persistence.** A chatty cell (10k-line print loop)
  used to trigger 10k full-file serializations; now coalesced to one
  per 100 ms via a tokio::Notify-driven flusher task.
- **Bounded mpsc channels.** Heavy kernel output backpressures the ZMQ
  socket instead of growing memory unboundedly.
- **`msg_to_cell` GC.** Routing entries are dropped on
  `(execute_reply ∧ status:idle)`, so the routing map no longer grows
  forever across a long session.
- **Cell completion gate.** "Done" status now requires BOTH
  `execute_reply` on shell AND `status: idle` on iopub; trailing
  stream output no longer arrives after the "Done" extmark.
- **Socket-owner task abort on `kill()`.** All long-running kernel tasks
  (iopub + shell/control owners) are tracked in a Vec<JoinHandle> and
  aborted en masse on kernel close; the pure-Rust zeromq impl could
  hang in `sock.recv()` after the kernel died without this.
- **Connection file cleanup.** `/tmp/jovian/kernel-*.json` is removed
  on `Kernel::kill` instead of accumulating until reboot.
- **Iopub / socket recv backoff.** Persistent recv errors now use
  exponential backoff capped at 5 s and exit the loop instead of
  spinning warn! at 20 lines/s forever.
- **Child stderr/stdout are drained** so a chatty kernel doesn't fill
  the 64 KB pipe buffer and stall its own writes.
- **`:JovianPin` rebuilt** on the sidecar JSON. It was silently broken
  since Phase 5 (looked up a `.md` path written by the removed Python
  bridge); now uses the same `output_render` path as the preview pane.
- **`:JovianClearCache` wired** to the Rust core's `clear_outputs` /
  `clear_cell_output` RPCs (also silently no-op'd previously).
- **`:JovianTunnelStatus`** fixed: was always reporting "running"
  because of a sentinel-string truthiness check.
- **Buffer-state cleanup on wipe.** A BufDelete/BufWipeout autocmd now
  sweeps `cell_buf_map` / `cell_status_extmarks` / `cell_start_time` /
  `cell_status_cache` for entries pointing at the dying buffer.
- **Debouncer cleanup on BufWipeout.** Pending render timers are
  closed when their buffer goes away.
- **`flash_range` captures bufnr up-front** so switching buffers during
  the 300 ms flash doesn't wipe the wrong buffer's highlight namespace.
- **`notify_threshold` is now consulted** — the docs documented it but
  no code read it. Long-running cells get a desktop notification on
  completion.

### Changed
- **CI now runs `cargo fmt --check` / `cargo clippy -D warnings` /
  `cargo test`** alongside the Lua + Python lints.
- **`DEVELOPMENT.md` rewritten** for the current Rust-backend
  architecture; stale references to `kernel_bridge.py`, `handlers.lua`,
  `utils.lua`, and `jovian_queries/` are gone.

### Removed
- **Legacy Python-bridge fallback paths** in `session.lua`
  (`clear_cache`, `sync_remote_file`, `save_execution_result`) — the
  `kernel_bridge.py` they fed was deleted in Phase 5.
- **Dead RPC handlers**: `version`, `snapshot`, `stop_kernel`,
  `restart_kernel`, `execute_silent`, `persist_outputs`,
  `kitty_clear` — none had Lua callers; `inspect` and `clear_*` were
  kept because they're now wired up (see Added/Fixed).
- **Unused dependencies**: `tokio-stream`, `futures`, `rmp-serde`,
  `thiserror` (and tokio's `signal` / `fs` features).
- **Dead `CellType::Raw`** variant, **`transient` field** on display
  events, **`KernelEvent::UpdateDisplayData`** (no consumer), and the
  duplicate `ev_parent` match in `session.rs`.
- **Dead host-validation path**: `Hosts.validate_connection` (200 ms-5 s
  pre-flight ssh probe duplicated by the Rust core's start_kernel)
  and the `type = "connection"` host kind nobody could create.
- **Dead State fields**: `vars_request_force_float`, `batch_execution`,
  `current_preview_file`; `last_stream_type` / `last_stream_tail`
  scoped down to file-locals in `ui/shared.lua`.
- **Dead config keys**: `use_rust_core`, `treesitter.*`,
  `connection_file`.
- **`examples/demo_jovian.py`** collapsed into the root `demo_jovian.py`
  (was two drifting copies).

### Refactored
- **`ui/highlights.lua` → `ui/hl_utils.lua`** — disambiguates from the
  top-level `lua/jovian/highlights.lua` which defines the highlight
  groups themselves.
- **`KernelEvent::parent_msg_id()` method** replaces a 10-arm match
  duplicated across `apply_event` and the removed `ev_parent`.

### Tests
- 23 Rust unit tests (up from 17): `parses_tags` /
  `no_tags_when_absent` / `tags_tolerant_of_whitespace_and_empty_list`
  in notebook.rs, plus three .ipynb round-trip tests in the new
  `ipynb` module.
- New headless suite: `tests/test_ipynb.lua` — 23 assertions covering
  :JovianImport, :JovianExport, and the BufReadCmd / BufWriteCmd
  native-open round-trip via the real msgpack-RPC client.

## [0.1.0] — pre-release

Project is still pre-1.0; the entries below are a rolling summary of major
feature work. Each bullet groups multiple commits — see `git log` for the
full chain.

### Backend
- **Rust core (Phase 5):** replaced the legacy Python bridge + libzmq FFI
  with a single `jovian-core` binary speaking the Jupyter wire protocol
  directly over msgpack-RPC. Pure-Rust ZMQ; no system `libzmq`.
- **Remote kernels through the Rust core:** SSH tunnel + remote kernel
  launch live in `kernel.rs::launch_remote`; a PTY is forced so remote
  kernels die on disconnect.
- **CI release pipeline:** prebuilt `jovian-core` binaries for
  `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin` on
  every `v*` tag push.

### UI
- **Inline cell output rendering** (opt-in `inline_outputs`): outputs read
  from a single nbformat-shaped sidecar and rendered as virt_lines below
  each cell.
- **Cell card frames** (opt-in `cell_frame`): `┌─ Code [id] ─┐` borders,
  configurable corner style and side-bar priority, scrollbar-aware right
  padding.
- **Markdown cell styling** (opt-in `markdown_cell_style`): headings,
  bold/italic, inline `code`, bullets, blockquotes, data-URI and
  file-path images via Kitty graphics.
- **Markdown tables** in render-markdown.nvim style with `round` / `none` /
  `heavy` / `double` border presets.
- **LaTeX math** (`$…$` / `$$…$$`) converted to Unicode in place; built-in
  converter with hooks for `latex2text` / `utftex`.
- **Output window on-demand** (`output_window = "ondemand"` by default);
  Variables pane moved out of the default layout.
- **Kitty image pipeline:** images transmitted once via `a=T,U=1,c=N,r=N`,
  rendered as Unicode-placeholder rows whose fg color encodes the image_id.
  Preview and Output windows render images too. Auto-fit to the pane, never
  upscaling past native size.

### Python environment
- **Auto-resolved interpreter:** `setup()` probes PATH / `$VIRTUAL_ENV` /
  `$CONDA_PREFIX` / `.venv` / `venv` for an `ipykernel`-capable python.
- **`:JovianPickPython`:** interactive picker listing every discovered
  python and registered Jupyter kernelspec; restarts the kernel on switch.

### Tests
- `test_python_resolve`, `test_outputs_json_resilience`,
  `test_remote_ssh`, `test_kitty_images`, `test_markdown_images`,
  `test_markdown_table`, `test_math`, `test_cell_frame`,
  `test_inline_outputs`, plus the existing async / commands / cells /
  edge cases / Rust phase-1 / resize-layout suite.

[Unreleased]: https://github.com/m-tky/jovian.nvim/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/m-tky/jovian.nvim/releases/tag/v0.2.0
[0.1.0]: https://github.com/m-tky/jovian.nvim/releases/tag/v0.1.0
