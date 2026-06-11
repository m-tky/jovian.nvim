-- Remote-kernel end-to-end test: start a kernel on an SSH host via
-- jovian-core's launch_remote (bootstrap → -L forwards → exec kernel), run a
-- cell, and verify stdout streams back exactly as for a local kernel.
--
-- Opt-in: only runs when JOVIAN_REMOTE_SSH_HOST is set (a Host alias resolvable
-- by `ssh`, with key/agent auth). Skipped silently otherwise so the normal CI
-- suite — which has no SSH host — stays green.
--
-- Throwaway sshd+ipykernel container to test against (podman or docker):
--
--   W=/tmp/jovian-remote-test; mkdir -p "$W"
--   ssh-keygen -t ed25519 -N "" -f "$W/id_ed25519" -q
--   cat > "$W/Containerfile" <<'DOCKER'
--   FROM python:3.12-slim
--   ARG PUBKEY
--   RUN apt-get update && apt-get install -y --no-install-recommends openssh-server \
--       && rm -rf /var/lib/apt/lists/*
--   RUN pip install --no-cache-dir ipykernel
--   RUN ssh-keygen -A && mkdir -p /root/.ssh && chmod 700 /root/.ssh \
--       && echo "$PUBKEY" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys \
--       && sed -i 's/#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
--       && printf '\nPubkeyAuthentication yes\nPerSourcePenalties no\n' >> /etc/ssh/sshd_config
--   CMD ["/usr/sbin/sshd", "-D", "-e"]
--   DOCKER
--   podman build --build-arg PUBKEY="$(cat "$W/id_ed25519.pub")" -t jovian-remote-test "$W"
--   podman run -d --name jovian-remote -p 127.0.0.1:2222:22 jovian-remote-test
--
-- Add a matching `Host jovian-test` block to ~/.ssh/config (ssh ignores $HOME,
-- so it must be the real one) pointing HostName 127.0.0.1, Port 2222, User root,
-- IdentityFile $W/id_ed25519, IdentitiesOnly yes, StrictHostKeyChecking no. Then:
--
--   JOVIAN_REMOTE_SSH_HOST=jovian-test \
--   JOVIAN_REMOTE_PYTHON=python3 \
--   nvim --headless -l tests/test_remote_ssh.lua

local HOST = os.getenv("JOVIAN_REMOTE_SSH_HOST")
if not HOST or HOST == "" then
    -- Exit code 2 = SKIP so run-tests reports it rather than counting a
    -- silent pass (see test_rust_phase1.lua).
    print("SKIP: JOVIAN_REMOTE_SSH_HOST not set")
    os.exit(2)
end
local REMOTE_PYTHON = os.getenv("JOVIAN_REMOTE_PYTHON")
if not REMOTE_PYTHON or REMOTE_PYTHON == "" then
    REMOTE_PYTHON = "python3"
end
print("remote host:", HOST, "python:", REMOTE_PYTHON)

vim.opt.rtp:prepend(vim.fn.getcwd())

local tmp = vim.fn.tempname() .. ".py"
vim.cmd("edit " .. tmp)
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    '# %% id="probe1"',
    "import sys, platform",
    'print("hello from remote:", 1 + 1, platform.node())',
})
vim.cmd("write")

require("jovian").setup({})

-- core.lua schedules a one-time Hosts.load_hosts() on module load that resets
-- ssh_host to the default local host. Drain that scheduled callback before we
-- activate our remote host, otherwise it clobbers ssh_host back to nil.
vim.wait(300)

local Config = require("jovian.config")
-- Activate the SSH host exactly as hosts.use_host would.
Config.options.ssh_host = HOST
Config.options.ssh_python = REMOTE_PYTHON
Config.options.remote_cwd = "."

local State = require("jovian.state")
local Core = require("jovian.core")
local UI = require("jovian.ui")

local captured = {}
local original_append = UI.append_to_repl
UI.append_to_repl = function(text, hl)
    if type(text) == "table" then
        for _, l in ipairs(text) do
            table.insert(captured, l)
        end
    else
        table.insert(captured, tostring(text))
    end
    pcall(original_append, text, hl)
end
local original_stream = UI.append_stream_text
UI.append_stream_text = function(text, stream)
    table.insert(captured, "[stream:" .. (stream or "?") .. "] " .. (text or ""))
    pcall(original_stream, text, stream)
end

UI.open_windows()

local cell_done = false
local cell_errored = false
local original_set_status = UI.set_cell_status
UI.set_cell_status = function(buf, cell_id, status, msg)
    print(string.format("[status] cell=%s status=%s msg=%q", cell_id, status, msg or ""))
    if cell_id == "probe1" then
        if status == "done" then
            cell_done = true
        elseif status == "error" then
            cell_errored = true
            cell_done = true
        end
    end
    return original_set_status(buf, cell_id, status, msg)
end

local ready = false
table.insert(State.on_ready_callbacks, function()
    ready = true
end)
Core.start_kernel()

-- SSH connect + remote ipykernel startup is slower than a local spawn.
local deadline = vim.uv.now() + 40000
while not ready and vim.uv.now() < deadline do
    vim.wait(100)
end
assert(ready, "remote kernel did not become ready within 40s")
print("remote kernel ready")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
Core.send_cell()

deadline = vim.uv.now() + 20000
while not cell_done and vim.uv.now() < deadline do
    vim.wait(100)
end
assert(cell_done, "cell did not finish within 20s")
assert(not cell_errored, "cell errored on the remote kernel")

local joined = table.concat(captured, "\n")
print("---captured---\n" .. joined .. "\n--------------")
assert(joined:find("hello from remote: 2", 1, true), "remote stdout not captured")

Core.stop_kernel()
vim.wait(500)
print("OK (remote kernel)")
os.exit(0)
