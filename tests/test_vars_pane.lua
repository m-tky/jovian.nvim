vim.opt.rtp:prepend(".")
local Jovian = require("jovian")
local Core = require("jovian.core")
local UI = require("jovian.ui")
local State = require("jovian.state")

local function wait_for(cond, timeout, msg)
    local ok = vim.wait(timeout or 5000, cond, 50)
    if not ok then
        print("TIMEOUT: " .. (msg or "Condition not met"))
        os.exit(1)
    end
end

print("Setting up Jovian...")
Jovian.setup({ python_interpreter = "python3", toggle_var = false })

-- Create dummy buffer
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, "test_vars.py")
vim.api.nvim_set_current_buf(buf)
vim.bo.filetype = "python"
local main_win = vim.api.nvim_get_current_win()

-- Start Kernel
print("Starting Kernel...")
vim.cmd("JovianOpen")
vim.cmd("JovianStart")
wait_for(function() return State.job_id ~= nil end, 5000, "Kernel start")
vim.wait(1000)

-- Toggle Vars Pane
print("Toggling Vars Pane...")
vim.cmd("JovianToggleVars")
wait_for(function() return State.win.variables and vim.api.nvim_win_is_valid(State.win.variables) end, 1000, "Vars Pane Open")
print("Vars Pane Opened")

-- Run Code
print("Running Code...")
vim.api.nvim_set_current_win(main_win)
Core.send_payload("my_var = 999", "cell1", "test_vars.py")

-- Wait for update in Vars Pane
print("Waiting for Vars Pane update...")
wait_for(function()
    if not (State.buf.variables and vim.api.nvim_buf_is_valid(State.buf.variables)) then return false end
    local lines = vim.api.nvim_buf_get_lines(State.buf.variables, 0, -1, false)
    local content = table.concat(lines, "\n")
    return content:match("my_var") and content:match("999")
end, 5000, "Vars Pane Content Update")

print("PASS: Vars Pane Updated")

-- Close Pane
print("Closing Vars Pane...")
vim.cmd("JovianToggleVars")
wait_for(function() return State.win.variables == nil end, 1000, "Vars Pane Closed")
print("Vars Pane Closed")

print("ALL TESTS PASSED")
vim.cmd("qall!")
