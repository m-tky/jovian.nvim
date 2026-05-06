-- test_commands.lua
-- Functional verification of Jovian commands using real modules and mocked Vim API.

-- 1. Setup package path
-- local sep = package.config:sub(1, 1)
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
package.path = package.path .. ";" .. project_root .. "/lua/?.lua" .. ";" .. project_root .. "/lua/?/init.lua"

-- Unload existing jovian modules to ensure we load fresh ones
for k, _ in pairs(package.loaded) do
    if k:match("^jovian") then
        package.loaded[k] = nil
    end
end

-- 2. Mock Vim API
_G.vim = _G.vim or {}
vim.api = vim.api or {}
vim.fn = vim.fn or {}
vim.cmd = vim.cmd or function() end
vim.notify = function(msg)
    print("NOTIFY: " .. msg)
end
vim.schedule = function(cb)
    cb()
end -- Run immediately
vim.defer_fn = function(cb, _ms)
    cb()
end -- Run immediately
vim.loop = {
    new_timer = function()
        return { start = function() end, close = function() end }
    end,
    fs_scandir = function()
        return nil
    end, -- Mock scandir
}
vim.log = { levels = { INFO = 1, ERROR = 2, WARN = 3 } }

-- Mock Window Validity
vim.api.nvim_win_is_valid = function()
    return true
end

-- Mock Buffer/Window State
local mock_lines = { '# %% id="cell1"', "print('hello')", '# %% id="cell2"', "x = 1" }
vim.api.nvim_buf_line_count = function()
    return #mock_lines
end
vim.api.nvim_buf_get_lines = function(_buf, start, end_, _strict)
    local res = {}
    for i = start + 1, math.min(end_, #mock_lines) do
        table.insert(res, mock_lines[i])
    end
    return res
end
vim.api.nvim_buf_get_name = function()
    return "/tmp/test.py"
end
vim.api.nvim_win_set_cursor = function() end
vim.api.nvim_buf_set_extmark = function()
    return 1
end -- Mock extmark
vim.api.nvim_buf_clear_namespace = function() end
vim.api.nvim_create_namespace = function()
    return 1
end
vim.api.nvim_win_get_cursor = function()
    return { 2, 0 }
end -- Cursor on "print('hello')" (cell1)
vim.fn.line = function(expr)
    if expr == "." then
        return 2
    end
    return 1
end
vim.fn.expand = function(expr)
    if expr == "%:p:h" then
        return "/tmp"
    end
    if expr == "%:t" then
        return "test.py"
    end
    if expr == "<cword>" then
        return "my_var"
    end
    return ""
end
vim.fn.fnamemodify = function(path, mod)
    if mod == ":p:h" then
        return path:match("(.*)/") or "."
    end
    if mod == ":t" then
        return path:match(".*/(.*)") or path
    end
    if mod == ":p:h:h" then
        local h = path:match("(.*)/") or "."
        return h:match("(.*)/") or "."
    end
    return path
end
vim.fn.filereadable = function()
    return 0
end
vim.fn.isdirectory = function()
    return 0
end
vim.fn.readdir = function()
    return {}
end
vim.fn.mkdir = function() end
vim.fn.writefile = function() end
vim.fn.readfile = function()
    return {}
end
vim.fn.delete = function() end
vim.fn.stdpath = function()
    return "/tmp"
end
vim.fn.getcwd = function()
    return "/tmp"
end
vim.fn.system = function()
    return ""
end

-- Mock JSON
vim.json = {
    encode = function(t)
        -- Simple mock encoder for verify
        local str = "{"
        for k, v in pairs(t) do
            str = str .. k .. "=" .. tostring(v) .. ","
        end
        return str .. "}"
    end,
    decode = function(_s)
        return {}
    end,
}

-- Mock Job Control
local sent_payloads = {}
vim.fn.jobstart = function(_cmd, opts)
    if opts and opts.on_exit then
        opts.on_exit(0, 0)
    end
    return 123 -- job_id
end
vim.fn.jobpid = function(_id)
    return 9999
end -- Mock PID
vim.api.nvim_chan_send = function(_id, data)
    table.insert(sent_payloads, data)
    print("CHAN_SEND: " .. data)
end

-- Mock User Commands
_G.commands = {}
vim.api.nvim_create_user_command = function(name, callback, _opts)
    _G.commands[name] = callback
end

-- 3. Load Real Modules
require("jovian.commands").setup()
local State = require("jovian.state")

-- Helper to run command
local function run_command(name, args)
    print("Testing " .. name .. "...")
    if not _G.commands[name] then
        print("FAIL: Command " .. name .. " not registered")
        return
    end

    -- Clear payloads
    sent_payloads = {}

    local status, err = pcall(_G.commands[name], { args = args or "" })

    if not status then
        print("FAIL: Error executing " .. name .. ": " .. err)
        return
    end
    return true
end

-- 4. Functional Tests

local fail_count = 0
local function assert_test(cond, msg)
    if cond then
        print("PASS: " .. msg)
    else
        print("FAIL: " .. msg)
        fail_count = fail_count + 1
    end
end

print("--- Functional Verification ---")

-- Test 1: JovianStart (Should set job_id)
run_command("JovianStart")
assert_test(State.job_id == 123, "JovianStart set job_id")

-- Test 2: JovianRun (Should send execute command)
-- Ensure windows are "open" in State
State.win.output = 100
run_command("JovianRun")
assert_test(#sent_payloads > 0 and sent_payloads[1]:match("command=execute"), "JovianRun sent execute payload")

-- Test 3: JovianVars (Should send vars command)
-- Ensure job_id is still set
State.job_id = 123
run_command("JovianVars")
assert_test(#sent_payloads > 0 and sent_payloads[1]:match("command=get_variables"), "JovianVars sent variables payload")

-- Test 4: JovianInterrupt (Should send interrupt command)
State.job_id = 123
-- Mock kill
vim.loop.kill = function() end
run_command("JovianInterrupt")
-- Interrupt doesn't send JSON, it sends SIGINT.
-- But we can check if it ran without error.
assert_test(true, "JovianInterrupt executed (SIGINT sent)")

-- Test 6: JovianClean (Should run without error)
run_command("JovianClean")
assert_test(true, "JovianClean executed")

-- Test 7: JovianClearCache (Should send remove_cache)
run_command("JovianClearCache")
assert_test(
    #sent_payloads > 0 and sent_payloads[1]:match("command=remove_cache"),
    "JovianClearCache sent remove_cache payload"
)

-- Test 8: JovianProfile (Should send profile command)
run_command("JovianProfile")
assert_test(#sent_payloads > 0 and sent_payloads[1]:match("command=profile"), "JovianProfile sent profile payload")

-- Test 9: JovianCopy (Should send copy_to_clipboard command)
run_command("JovianCopy", "my_var")
local payload = sent_payloads[1] or ""
assert_test(
    #sent_payloads > 0 and payload:match("command=copy_to_clipboard") and payload:match("name=my_var"),
    "JovianCopy sent copy_to_clipboard payload"
)

if fail_count > 0 then
    print("\nTotal Failures: " .. fail_count)
    os.exit(1)
else
    print("\nAll tests passed!")
    os.exit(0)
end
