-- test_async_flow.lua
-- Verifies that Hosts and Core modules handle async callbacks correctly.

-- 1. Setup package path
-- local sep = package.config:sub(1, 1)
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
package.path = package.path .. ";" .. project_root .. "/lua/?.lua" .. ";" .. project_root .. "/lua/?/init.lua"

-- Unload existing jovian modules to ensure mocks take effect
for k, _ in pairs(package.loaded) do
    if k:match("^jovian") then
        package.loaded[k] = nil
    end
end

-- 2. Mock Dependencies
local Mocks = {
    Config = { options = { python_interpreter = "python3" } },
    UI = {
        append_to_repl = function(msg)
            print("UI: " .. vim.inspect(msg))
        end,
        notify = function(msg)
            print("NOTIFY: " .. msg)
        end,
    },
}

-- Mock Vim API
vim.notify = function(msg)
    print("VIM_NOTIFY: " .. msg)
end
vim.fn = vim.fn or {}
vim.fn.filereadable = function()
    return 1
end
vim.fn.fnamemodify = function(path, mod)
    if mod == ":h" or mod == ":p:h" then
        return path:match("(.*)/") or "."
    end
    if mod == ":t" then
        return path:match(".*/(.*)") or path
    end
    return path
end
vim.fn.system = function()
    return "mock_hash"
end
vim.fn.trim = function(s)
    return s:match("^%s*(.-)%s*$")
end
vim.log = { levels = { INFO = 1, ERROR = 2, WARN = 3 } }

-- Async Job Mock
local PendingJobs = {}
vim.fn.jobstart = function(cmd, opts)
    local cmd_str = type(cmd) == "table" and table.concat(cmd, " ") or cmd
    print("JOB_START: " .. cmd_str)
    local job_id = #PendingJobs + 1
    PendingJobs[job_id] = { cmd = cmd, opts = opts }
    return job_id
end
vim.json = {
    encode = function(t)
        return vim.fn.json_encode(t)
    end,
    decode = function(s)
        return vim.fn.json_decode(s)
    end,
}
vim.api = vim.api or {}
vim.api.nvim_chan_send = function(_id, data)
    print("CHAN_SEND: " .. data)
end

-- Helper to trigger job completion
local function complete_job(job_id, exit_code)
    local job = PendingJobs[job_id]
    if not job then
        print("ERROR: Job " .. job_id .. " not found")
        return
    end
    if job.opts and job.opts.on_exit then
        job.opts.on_exit(job_id, exit_code)
    end
end

-- Inject Mocks
package.loaded["jovian.config"] = Mocks.Config
package.loaded["jovian.ui"] = Mocks.UI

-- Load Modules
local Hosts = require("jovian.hosts")
local Core = require("jovian.core")

-- Tests
local fail_count = 0
local function assert_test(cond, msg)
    if cond then
        print("PASS: " .. msg)
    else
        print("FAIL: " .. msg)
        fail_count = fail_count + 1
    end
end

print("--- Starting Async Flow Tests ---")

-- Test 1: Hosts.validate_connection (Local)
print("\nTest 1: Hosts.validate_connection (Local)")
local t1_done = false
Hosts.validate_connection({ type = "local", python = "python3" }, function()
    t1_done = true
end, function(err)
    print("T1 ERROR: " .. err)
end)

assert_test(not t1_done, "Callback waited for job")
-- Trigger the pending job (python --version)
complete_job(#PendingJobs, 0)
assert_test(t1_done, "Callback executed after job completion")

-- Test 2: Hosts.validate_connection (SSH)
print("\nTest 2: Hosts.validate_connection (SSH)")
local t2_done = false
Hosts.validate_connection({ type = "ssh", host = "myserver", python = "python3" }, function()
    t2_done = true
end, function(err)
    print("T2 ERROR: " .. err)
end)

-- Should have started SSH check
local ssh_check_job = #PendingJobs
assert_test(PendingJobs[ssh_check_job].cmd[1] == "ssh", "SSH check started")

-- Complete SSH check
complete_job(ssh_check_job, 0)

-- Should now have started Python check
local py_check_job = #PendingJobs
assert_test(
    py_check_job > ssh_check_job and PendingJobs[py_check_job].cmd[3] == "python3",
    "Remote Python check started"
)

-- Complete Python check
complete_job(py_check_job, 0)

assert_test(t2_done, "SSH Validation completed successfully")

-- (Test 3 "Core.sync_backend" removed in Phase 5: the Python bridge it
-- rsync'd to remote hosts no longer exists. SSH/remote-kernel routing
-- will return later with the Rust core owning the wire setup.)

if fail_count > 0 then
    print("\nTotal Failures: " .. fail_count)
    os.exit(1)
else
    print("\nAll tests passed!")
    os.exit(0)
end
