-- Phase 1 smoke test: spawn a real Python kernel via jovian-core,
-- run a cell, verify stdout streams back into the REPL window and the
-- cell status virtual text transitions running → done.
--
-- Requires JOVIAN_PYTHON env var pointing at a python with ipykernel
-- installed (set automatically by the nix-jovian wrapper / nix devShell).
-- Skipped silently if ipykernel can't be imported.

-- Resolve a python binary that has ipykernel. We prefer JOVIAN_PYTHON since
-- that's what the nix-jovian wrapper sets; otherwise fall back to whichever
-- `python3` is on PATH. The Rust core needs an ABSOLUTE path (so we can pass
-- it as python_path and bypass kernelspec discovery), so we resolve via
-- `command -v` when we get a bare name.
local function resolve_python()
    local p = os.getenv("JOVIAN_PYTHON")
    if not p or p == "" then
        p = vim.trim(vim.fn.system("command -v python3"))
    end
    if not p or p == "" or vim.fn.executable(p) == 0 then return nil end
    local ok = os.execute(p .. " -c 'import ipykernel' 2>/dev/null")
    if not (ok == 0 or ok == true) then return nil end
    return p
end

local PYTHON = resolve_python()
if not PYTHON then
    print("SKIP: no python with ipykernel found")
    os.exit(0)
end
print("using python:", PYTHON)

-- Set up runtimepath so require('jovian') works
vim.opt.rtp:prepend(vim.fn.getcwd())

-- Open a buffer with a # %% cell BEFORE setup, so session_path() resolves
-- to a real file path the kernel can `cd` into.
local tmp = vim.fn.tempname() .. ".py"
vim.cmd("edit " .. tmp)
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    '# %% id="probe1"',
    'print("hello from rust path:", 1 + 1)',
})
vim.cmd("write")

require("jovian").setup({
    use_rust_core = true,
    python_interpreter = PYTHON,
    use_lua_native_shell = false,
})

local State = require("jovian.state")
local Core = require("jovian.core")
local UI = require("jovian.ui")

-- Capture REPL appends without needing the UI buffer to be open
local captured = {}
local original_append = UI.append_to_repl
UI.append_to_repl = function(text, hl)
    if type(text) == "table" then
        for _, l in ipairs(text) do table.insert(captured, l) end
    else
        table.insert(captured, tostring(text))
    end
    -- still call original so the real buffer (if open) sees it too
    pcall(original_append, text, hl)
end
local original_stream = UI.append_stream_text
UI.append_stream_text = function(text, stream)
    table.insert(captured, "[stream:" .. (stream or "?") .. "] " .. (text or ""))
    pcall(original_stream, text, stream)
end

-- Open the output window so send_cell's is_window_open() guard passes
UI.open_windows()

local cell_done = false
local original_set_status = UI.set_cell_status
UI.set_cell_status = function(buf, cell_id, status, msg)
    print(string.format("[status] cell=%s status=%s msg=%q", cell_id, status, msg or ""))
    if cell_id == "probe1" and (status == "done" or status == "error") then
        cell_done = true
    end
    return original_set_status(buf, cell_id, status, msg)
end

-- Wait for kernel to be ready, then run the cell
local ready = false
table.insert(State.on_ready_callbacks, function() ready = true end)
Core.start_kernel()

local deadline = vim.uv.now() + 15000
while not ready and vim.uv.now() < deadline do
    vim.wait(100)
end
assert(ready, "kernel did not become ready within 15s")
print("kernel ready")

-- Move cursor to the cell and trigger a run
vim.api.nvim_win_set_cursor(0, { 1, 0 })
Core.send_cell()

deadline = vim.uv.now() + 10000
while not cell_done and vim.uv.now() < deadline do
    vim.wait(100)
end
assert(cell_done, "cell did not finish within 10s")

-- Check captured stream content
local joined = table.concat(captured, "\n")
print("---captured---\n" .. joined .. "\n--------------")
assert(joined:find("hello from rust path: 2", 1, true), "stdout not captured")

Core.stop_kernel()
vim.wait(500)
print("OK")
os.exit(0)
