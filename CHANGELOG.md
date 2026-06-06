# Changelog

All notable changes to jovian.nvim are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it leaves `0.x`.

## [Unreleased]

### Added
- `doc/jovian.txt` — `:h jovian` help file covering setup, commands, options
  and highlight groups.
- `plugin/jovian.lua` — VimEnter auto-setup safety net so non-lazy plugin
  managers get working `:Jovian*` commands without an explicit `setup()`
  call.
- Rust core CI: `cargo fmt --check`, `cargo clippy --deny warnings`, and
  `cargo test` now run on every push.

### Changed
- `DEVELOPMENT.md` rewritten for the current Rust-backend architecture; the
  stale references to `kernel_bridge.py`, `handlers.lua`, and `utils.lua`
  are gone.

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

[Unreleased]: https://github.com/m-tky/jovian.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/m-tky/jovian.nvim/releases/tag/v0.1.0
