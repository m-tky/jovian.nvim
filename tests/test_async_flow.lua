-- test_async_flow.lua
-- Verifies that Hosts and Core modules handle async callbacks correctly.

-- 1. Setup package path
local sep = package.config:sub(1,1)
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
        append_to_repl = function(msg) print("UI: " .. vim.inspect(msg)) end,
        notify = function(msg) print("NOTIFY: " .. msg) end
    }
}

-- Mock Vim API
vim.notify = function(msg) print("VIM_NOTIFY: " .. msg) end
vim.fn = vim.fn or {}
vim.fn.filereadable = function() return 1 end
vim.fn.fnamemodify = function(p, m) return p end
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
    encode = function(t) return vim.fn.json_encode(t) end,
    decode = function(s) return vim.fn.json_decode(s) end
}
vim.api = vim.api or {}
vim.api.nvim_chan_send = function(id, data)
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
print("--- Starting Async Flow Tests ---")

-- Test 1: Hosts.validate_connection (Local)
print("\nTest 1: Hosts.validate_connection (Local)")
local t1_done = false
Hosts.validate_connection({ type = "local", python = "python3" }, 
    function() 
        print("T1 SUCCESS") 
        t1_done = true
    end,
    function(err) 
        print("T1 ERROR: " .. err) 
    end
)

if t1_done then
    print("FAIL: Callback called synchronously!")
else
    print("PASS: Callback waited for job")
    -- Trigger the pending job (python --version)
    complete_job(#PendingJobs, 0)
    if t1_done then
        print("PASS: Callback executed after job completion")
    else
        print("FAIL: Callback not executed")
    end
end

-- Test 2: Hosts.validate_connection (SSH)
print("\nTest 2: Hosts.validate_connection (SSH)")
local t2_done = false
Hosts.validate_connection({ type = "ssh", host = "myserver", python = "python3" },
    function()
        print("T2 SUCCESS")
        t2_done = true
    end,
    function(err)
        print("T2 ERROR: " .. err)
    end
)

-- Should have started SSH check
local ssh_check_job = #PendingJobs
if PendingJobs[ssh_check_job].cmd[1] == "ssh" then
    print("PASS: SSH check started")
else
    print("FAIL: Expected SSH check, got " .. vim.inspect(PendingJobs[ssh_check_job].cmd))
end

-- Complete SSH check
complete_job(ssh_check_job, 0)

-- Should now have started Python check
local py_check_job = #PendingJobs
if py_check_job > ssh_check_job and PendingJobs[py_check_job].cmd[3] == "python3" then
    print("PASS: Remote Python check started")
else
    print("FAIL: Expected Remote Python check")
end

-- Complete Python check
complete_job(py_check_job, 0)

if t2_done then
    print("PASS: SSH Validation completed successfully")
else
    print("FAIL: SSH Validation did not complete")
end

-- Test 3: Core.sync_backend
print("\nTest 3: Core.sync_backend")
local t3_done = false
Core.sync_backend("myserver", "/local/backend",
    function()
        print("T3 SUCCESS")
        t3_done = true
    end,
    function(err)
        print("T3 ERROR: " .. err)
    end
)

-- Should have started 'ssh rm'
local rm_job = #PendingJobs
if string.match(PendingJobs[rm_job].cmd, "rm %-rf") then
    print("PASS: Remote cleanup started")
else
    print("FAIL: Expected rm -rf, got " .. PendingJobs[rm_job].cmd)
end

-- Complete cleanup
complete_job(rm_job, 0)

-- Should have started 'scp'
local scp_job = #PendingJobs
if scp_job > rm_job and string.match(PendingJobs[scp_job].cmd, "scp %-r") then
    print("PASS: SCP started")
else
    print("FAIL: Expected SCP")
end

-- Complete SCP
complete_job(scp_job, 0)

if t3_done then
    print("PASS: Backend Sync completed successfully")
else
    print("FAIL: Backend Sync did not complete")
end
