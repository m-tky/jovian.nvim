-- test_commands.lua
-- Run with: nvim -l test_commands.lua

-- 1. Setup package path
local sep = package.config:sub(1,1)
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h")
package.path = package.path .. ";" .. project_root .. "/lua/?.lua" .. ";" .. project_root .. "/lua/?/init.lua"

-- 2. Mock Dependencies
local Mocks = {
    Core = {},
    UI = {},
    Cell = {},
    Session = {},
    Hosts = {},
    Utils = {},
    Config = { options = {} }
}

-- Helper to create spy functions
local function create_spy(name)
    return function(...)
        print("CALLED: " .. name)
        return true -- Return true/valid for most checks
    end
end

-- Populate Mocks with expected functions
Mocks.Core.start_kernel = create_spy("Core.start_kernel")
Mocks.Core.send_cell = create_spy("Core.send_cell")
Mocks.Core.send_selection = create_spy("Core.send_selection")
Mocks.Core.run_all_cells = create_spy("Core.run_all_cells")
Mocks.Core.restart_kernel = create_spy("Core.restart_kernel")
Mocks.Core.show_variables = create_spy("Core.show_variables")
Mocks.Core.view_dataframe = create_spy("Core.view_dataframe")
Mocks.Core.copy_variable = create_spy("Core.copy_variable")
Mocks.Core.run_profile_cell = create_spy("Core.run_profile_cell")
Mocks.Core.print_backend = create_spy("Core.print_backend")
Mocks.Core.interrupt_kernel = create_spy("Core.interrupt_kernel")
Mocks.Core.inspect_object = create_spy("Core.inspect_object")
Mocks.Core.peek_symbol = create_spy("Core.peek_symbol")
Mocks.Core.toggle_plot_view = create_spy("Core.toggle_plot_view")
Mocks.Core.run_and_next = create_spy("Core.run_and_next")
Mocks.Core.run_line = create_spy("Core.run_line")
Mocks.Core.run_cells_above = create_spy("Core.run_cells_above")

Mocks.UI.open_windows = create_spy("UI.open_windows")
Mocks.UI.toggle_windows = create_spy("UI.toggle_windows")
Mocks.UI.clear_repl = create_spy("UI.clear_repl")
Mocks.UI.clear_diagnostics = create_spy("UI.clear_diagnostics")
Mocks.UI.toggle_variables_pane = create_spy("UI.toggle_variables_pane")
Mocks.UI.pin_cell = create_spy("UI.pin_cell")
Mocks.UI.unpin = create_spy("UI.unpin")
Mocks.UI.toggle_pin_window = create_spy("UI.toggle_pin_window")
Mocks.UI.flash_range = create_spy("UI.flash_range")
Mocks.UI.clear_status_extmarks = create_spy("UI.clear_status_extmarks")

Mocks.Session.clean_stale_cache = create_spy("Session.clean_stale_cache")
Mocks.Session.check_structure_change = create_spy("Session.check_structure_change")
Mocks.Session.clear_current_cell_cache = create_spy("Session.clear_current_cell_cache")
Mocks.Session.clear_all_cache = create_spy("Session.clear_all_cache")
Mocks.Session.clean_orphaned_caches = create_spy("Session.clean_orphaned_caches")

Mocks.Cell.get_cell_range = function() return 1, 3 end -- Mock range
Mocks.Cell.generate_id = function() return "mock_id" end
Mocks.Cell.get_current_cell_id = function() return "mock_id" end
Mocks.Cell.get_cell_md_path = function() return "mock_path.md" end
Mocks.Cell.delete_cell = create_spy("Cell.delete_cell")
Mocks.Cell.move_cell_up = create_spy("Cell.move_cell_up")
Mocks.Cell.move_cell_down = create_spy("Cell.move_cell_down")
Mocks.Cell.split_cell = create_spy("Cell.split_cell")

Mocks.Hosts.exists = function() return false end
Mocks.Hosts.validate_connection = function() return true end
Mocks.Hosts.add_host = create_spy("Hosts.add_host")
Mocks.Hosts.use_host = create_spy("Hosts.use_host")
Mocks.Hosts.remove_host = create_spy("Hosts.remove_host")
Mocks.Hosts.load_hosts = function() return { configs = {} } end

-- Inject Mocks
package.loaded["jovian.core"] = Mocks.Core
package.loaded["jovian.ui"] = Mocks.UI
package.loaded["jovian.cell"] = Mocks.Cell
package.loaded["jovian.session"] = Mocks.Session
package.loaded["jovian.hosts"] = Mocks.Hosts
package.loaded["jovian.utils"] = Mocks.Utils
package.loaded["jovian.config"] = Mocks.Config

-- Mock Vim API
vim.api.nvim_create_user_command = function(name, callback, opts)
    _G.commands = _G.commands or {}
    _G.commands[name] = callback
end
vim.api.nvim_buf_line_count = function() return 10 end
vim.api.nvim_buf_get_lines = function() return {"# %% id=\"cell1\""} end
vim.api.nvim_win_set_cursor = function() end
vim.cmd = function() end
vim.notify = function(msg) print("NOTIFY: " .. msg) end
vim.fn.line = function() return 1 end
vim.fn.filereadable = function() return 1 end -- Mock file exists for Pin
vim.ui.input = function(opts, on_confirm) on_confirm("test_input") end
vim.ui.select = function(items, opts, on_choice) on_choice(items[1]) end

-- 3. Load Commands
require("jovian.commands").setup()

-- 4. Test Runner
local function test_command(name, expected_call, opts)
    print("Testing " .. name .. "...")
    if not _G.commands[name] then
        print("FAIL: Command " .. name .. " not registered")
        return
    end
    
    -- Capture print output to verify call
    local old_print = print
    local output = ""
    print = function(msg) output = output .. msg .. "\n" end
    
    local status, err = pcall(_G.commands[name], opts or {})
    
    print = old_print
    
    if not status then
        print("FAIL: Error executing " .. name .. ": " .. err)
        return
    end
    
    if expected_call == "PASS" then
        print("PASS: " .. name)
    elseif output:match("CALLED: " .. expected_call) then
        print("PASS: " .. name)
    else
        print("FAIL: " .. name .. " did not call " .. expected_call)
        print("Output: " .. output)
    end
end

-- 5. Run Tests
print("--- Verifying All Commands ---")

-- Execution
test_command("JovianStart", "Core.start_kernel")
test_command("JovianRun", "Core.send_cell")
test_command("JovianSendSelection", "Core.send_selection")
test_command("JovianRunAll", "Core.run_all_cells")
test_command("JovianRestart", "Core.restart_kernel")

-- Host Management (Mocking input for interactive)
test_command("JovianAddHost", "Hosts.add_host", { args = "name host python" })
test_command("JovianAddLocal", "Hosts.add_host", { args = "name python" }) -- Uses add_host internally
test_command("JovianUse", "Hosts.use_host", { args = "name" })
test_command("JovianRemoveHost", "Hosts.remove_host", { args = "name" })

-- UI
test_command("JovianOpen", "UI.open_windows")
test_command("JovianToggle", "UI.toggle_windows")
test_command("JovianClearREPL", "UI.clear_repl")
test_command("JovianClean", "Session.clean_stale_cache") -- Default (no bang)
test_command("JovianClean", "Session.clean_orphaned_caches", { bang = true }) -- With bang
test_command("JovianClearDiag", "UI.clear_diagnostics")
test_command("JovianToggleVars", "UI.toggle_variables_pane")

-- Data & Tools
test_command("JovianVars", "Core.show_variables")
test_command("JovianView", "Core.view_dataframe", { args = "df" })
test_command("JovianCopy", "Core.copy_variable", { args = "var" })
test_command("JovianProfile", "Core.run_profile_cell")
test_command("JovianBackend", "Core.print_backend")

-- Navigation (Local functions, check side effects like flash_range)
test_command("JovianNextCell", "UI.flash_range")
test_command("JovianPrevCell", "UI.flash_range")
-- NewCell commands use nvim API, hard to check spy, but we can check they don't crash
-- We'll assume PASS if no error, as we mocked API
test_command("JovianNewCellBelow", "PASS") -- Special handling needed?
test_command("JovianNewMarkdownCellBelow", "PASS")
test_command("JovianNewCellAbove", "PASS")
test_command("JovianMergeBelow", "PASS")

-- Kernel Control
test_command("JovianInterrupt", "Core.interrupt_kernel")

-- Plotting
test_command("JovianDoc", "Core.inspect_object", { args = "obj" })
test_command("JovianPeek", "Core.peek_symbol", { args = "sym" })
test_command("JovianTogglePlot", "Core.toggle_plot_view")

-- Pinning
test_command("JovianPin", "UI.pin_cell")
test_command("JovianUnpin", "UI.unpin")
test_command("JovianTogglePin", "UI.toggle_pin_window")

-- Cell Editing
test_command("JovianDeleteCell", "Cell.delete_cell")
test_command("JovianMoveCellUp", "Cell.move_cell_up")
test_command("JovianMoveCellDown", "Cell.move_cell_down")
test_command("JovianSplitCell", "Cell.split_cell")

-- Execution Control
test_command("JovianRunAndNext", "Core.run_and_next")
test_command("JovianRunLine", "Core.run_line")
test_command("JovianClearCache", "Session.clear_current_cell_cache") -- Default
test_command("JovianClearCache", "Session.clear_all_cache", { bang = true }) -- With bang
test_command("JovianRunAbove", "Core.run_cells_above")
