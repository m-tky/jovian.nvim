local M = {}
local Config = require("jovian.config")
local Core = require("jovian.core")
local UI = require("jovian.ui")
local Utils = require("jovian.utils")

-- Navigation helpers... (No changes needed here, keeping it brief)
local function goto_next_cell()
    local cursor = vim.fn.line(".")
    local total = vim.api.nvim_buf_line_count(0)
    for i = cursor + 1, total do
        local line = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1]
        if line:match("^# %%%%") then
            vim.api.nvim_win_set_cursor(0, {i, 0})
            vim.cmd("normal! zz")
            local s, e = Utils.get_cell_range(i)
            UI.flash_range(s, e)
            return
        end
    end
    vim.notify("No next cell found", vim.log.levels.INFO)
end

local function goto_prev_cell()
    local cursor = vim.fn.line(".")
    for i = cursor - 1, 1, -1 do
        local line = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1]
        if line:match("^# %%%%") then
            vim.api.nvim_win_set_cursor(0, {i, 0})
            vim.cmd("normal! zz")
            local s, e = Utils.get_cell_range(i)
            UI.flash_range(s, e)
            return
        end
    end
    vim.notify("No previous cell found", vim.log.levels.INFO)
end

local function insert_cell_below()
    local _, e = Utils.get_cell_range()
    local new_id = Utils.generate_id()
    local lines = { "", "# %% id=\"" .. new_id .. "\"", "" }
    vim.api.nvim_buf_set_lines(0, e, e, false, lines)
    vim.api.nvim_win_set_cursor(0, {e + 3, 0})
    vim.cmd("startinsert") 
end

local function insert_cell_above()
    local s, _ = Utils.get_cell_range()
    local new_id = Utils.generate_id()
    local lines = { "# %% id=\"" .. new_id .. "\"", "", "" }
    vim.api.nvim_buf_set_lines(0, s - 1, s - 1, false, lines)
    vim.api.nvim_win_set_cursor(0, {s + 1, 0})
    vim.cmd("startinsert")
end

local function merge_cell_below()
    local _, e = Utils.get_cell_range()
    local total = vim.api.nvim_buf_line_count(0)
    if e >= total then return vim.notify("No cell below", vim.log.levels.WARN) end
    local line = vim.api.nvim_buf_get_lines(0, e, e + 1, false)[1]
    if line:match("^# %%%%") then
        vim.api.nvim_buf_set_lines(0, e, e + 1, false, {})
        vim.notify("Cells merged", vim.log.levels.INFO)
    else
        vim.notify("Could not find cell boundary below", vim.log.levels.WARN)
    end
end

function M.setup(opts)
    Config.setup(opts)
    
    -- Execution
    vim.api.nvim_create_user_command("JovianStart", Core.start_kernel, {})
    vim.api.nvim_create_user_command("JovianRun", Core.send_cell, {})
    vim.api.nvim_create_user_command("JovianSendSelection", Core.send_selection, { range = true })
    vim.api.nvim_create_user_command("JovianRunAll", Core.run_all_cells, {})
    vim.api.nvim_create_user_command("JovianRestart", Core.restart_kernel, {})
    
    -- UI
    vim.api.nvim_create_user_command("JovianOpen", function() UI.open_windows() end, {})
    vim.api.nvim_create_user_command("JovianToggle", UI.toggle_windows, {})
    vim.api.nvim_create_user_command("JovianClear", UI.clear_repl, {})
    vim.api.nvim_create_user_command("JovianClean", Core.clean_stale_cache, {})
    vim.api.nvim_create_user_command("JovianClearDiag", UI.clear_diagnostics, {})

    -- Data & Tools
    vim.api.nvim_create_user_command("JovianVars", Core.show_variables, {})
    vim.api.nvim_create_user_command("JovianView", Core.view_dataframe, { nargs = "?" })
    vim.api.nvim_create_user_command("JovianCopy", Core.copy_variable, { nargs = "?" }) -- ★追加
    vim.api.nvim_create_user_command("JovianProfile", Core.run_profile_cell, {})      -- ★追加

    -- Navigation
    vim.api.nvim_create_user_command("JovianNextCell", goto_next_cell, {})
    vim.api.nvim_create_user_command("JovianPrevCell", goto_prev_cell, {})
    vim.api.nvim_create_user_command("JovianNewCellBelow", insert_cell_below, {})
    vim.api.nvim_create_user_command("JovianNewCellAbove", insert_cell_above, {})
    vim.api.nvim_create_user_command("JovianMergeBelow", merge_cell_below, {})
    
    -- Fold
    vim.opt.foldmethod = "expr"
    vim.opt.foldexpr = "getline(v:lnum)=~'^#\\ %%'?'0':'1'"
    vim.opt.foldlevel = 99

    --kernel Control
    vim.api.nvim_create_user_command("JovianInterrupt", Core.interrupt_kernel, {}) -- ★重要
    
    -- Session
    vim.api.nvim_create_user_command("JovianSaveSession", Core.save_session, { nargs = "?" })
    vim.api.nvim_create_user_command("JovianLoadSession", Core.load_session, { nargs = "?" })
    
    -- Plotting


    vim.api.nvim_create_user_command("JovianDoc", Core.inspect_object, { nargs = "?" })

    vim.api.nvim_create_autocmd({"CursorHold", "CursorHoldI"}, {
        pattern = "*",
        callback = function() 
            if vim.bo.filetype == "python" then Core.check_cursor_cell() end 
        end
    })
end

return M
