# Contributing to jovian.nvim

Thanks for considering a contribution. This document covers the workflow and
expectations; the architectural background and developer cheatsheet live in
`CLAUDE.md` and `DEVELOPMENT.md`.

## Quick start

```bash
git clone https://github.com/m-tky/jovian.nvim
cd jovian.nvim
nix develop                          # or: cd core && cargo build --release
nix run .#run-tests                  # full test suite
```

If you're not on Nix, you'll need:

- Neovim 0.10+
- Python 3.10+ with `ipykernel`
- Rust toolchain (stable) for `cargo build`
- `stylua`, `luacheck`, `ruff` for linting

## Workflow

1. **Open an issue first** for non-trivial changes — a 5-line bug fix is
   fine to PR directly, but a new feature or a refactor deserves a quick
   design discussion before you spend time on it.
2. **Branch from `main`** with a descriptive name (e.g.
   `feat/jovian-pick-kernel`, `fix/extmark-orphan`).
3. **Keep PRs focused.** One feature or one fix per PR; avoid bundling
   unrelated changes.
4. **Add tests.** New behavior needs a test. New test files must be
   registered in `flake.nix`'s `run-tests` script — anything outside that
   is invisible to CI.
5. **Run lints + tests locally** before pushing:
   ```bash
   stylua --check .
   luacheck .
   ruff check .
   cd core && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
   nix run .#run-tests
   ```
6. **Conventional commit prefixes** are appreciated (`feat:`, `fix:`,
   `docs:`, `test:`, `refactor:`, `style:`, `chore:`, `ci:`). Look at
   `git log` for the existing style.

## Adding a `:Jovian*` command

1. Implement the logic where it belongs (`cell.lua` for cell editing,
   `core.lua` for kernel calls, etc.).
2. Register the command in `lua/jovian/commands.lua` inside `M.setup()`.
3. Document it in three places:
   - `doc/jovian.txt` (the `*:Jovian…*` tag block)
   - `README.md` command reference table
   - `CLAUDE.md` command reference table
4. If the command mutates buffer structure, wrap it via `cell_edit()` so
   the structure check runs after.

## Adding an option

1. Add a default in `lua/jovian/config.lua` with a comment block describing
   what it does and when to set it.
2. Document it in `doc/jovian.txt` (Options section) and `README.md`
   (Configuration section).
3. If the option gates new behavior, default it to `false` / `nil` — see
   the `cell_frame` / `markdown_cell_style` / `inline_outputs` pattern.

## Style notes

- **Lua:** `stylua` is authoritative. 4-space indent. No 1-line `if`s.
- **Rust:** `rustfmt` + `clippy -D warnings`. Prefer `?` over `unwrap()`.
- **Comments:** describe *why*, not *what*. The "what" is obvious from
  the code; the "why" is the bit that decays.
- **Tests:** prefer black-box tests that exercise public behavior. Mocking
  is fine for terminal / RPC boundaries — see
  `tests/test_kitty_images.lua` for the pattern.
- **No backwards-compat shims for unreleased changes.** We're pre-1.0;
  remove old code rather than soft-deprecating it.

## Reporting bugs

Open an issue with:

- Neovim version (`nvim --version` first line)
- Terminal + version (Kitty / Ghostty / WezTerm / ...)
- `jovian-core --version` (or the commit SHA if built from source)
- Output of `:checkhealth jovian`
- Minimal reproduction — a small `.py` file with the cells that trigger
  the bug, and the steps you ran

For image / Kitty issues, attach the output of `:JovianDebugImages`.

## License

By contributing, you agree that your contributions are licensed under the
project's MIT license. See `LICENSE`.
