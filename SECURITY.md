# Security Policy

## Supported versions

jovian.nvim is pre-1.0 and rolling-release; only the latest commit on `main`
receives security fixes.

## Reporting a vulnerability

**Do not open a public GitHub issue for security reports.**

Email security reports to the maintainer (see the `Cargo.toml`/`README.md`
contact, or the git history's author email). Include:

- A description of the issue and the affected component (Lua front-end,
  Rust core, remote-kernel path, etc.).
- A minimal reproduction or proof-of-concept.
- Your assessment of impact (information disclosure, RCE, etc.) and
  conditions required to exploit.

You should receive an acknowledgement within 5 business days. We aim to
have a fix and a coordinated disclosure window agreed within 30 days of the
initial report.

## Threat model — what's in scope

- **Local kernel execution.** The plugin sends user-authored Python to a
  local Jupyter kernel. Compromise of the kernel process is *not*
  considered a vulnerability — the user is already authoring code that
  will be executed.
- **HMAC signing of kernel messages.** `jovian-core` HMAC-SHA256-signs
  every Jupyter wire-protocol message with a per-session key. A bug that
  weakens or skips signing is in scope.
- **Remote kernel SSH transport.** Remote kernels run through `ssh -L`
  port forwards. The plugin must not bypass host-key verification or
  prefer password auth — key/agent auth only. A bug that downgrades this
  is in scope.
- **Sidecar JSON parsing.** Outputs are read from
  `.jovian_cache/<file>/outputs.json`. A malformed or attacker-controlled
  sidecar should not crash Neovim or execute arbitrary code. A bug here
  is in scope.
- **Kitty graphics escapes.** PNG bytes are passed to the terminal via
  the Kitty graphics protocol. A bug that injects arbitrary terminal
  escapes outside the documented Kitty protocol is in scope.

## Out of scope

- Running untrusted `.py` files. If you `:JovianRun` code from an unknown
  source, the code executes — that's the point of the plugin.
- Terminal emulator vulnerabilities. Kitty / Ghostty / WezTerm bugs are
  the terminal's responsibility.
- Issues that require an attacker who already has shell access to the
  machine running Neovim.
