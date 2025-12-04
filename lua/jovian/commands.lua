local M = {}
local Core = require("jovian.core")
local UI = require("jovian.ui")
local Utils = require("jovian.utils")
local Hosts = require("jovian.hosts")
local Config = require("jovian.config")

-- Navigation helpers
local function goto_next_cell()
	local cursor = vim.fn.line(".")
	local total = vim.api.nvim_buf_line_count(0)
	for i = cursor + 1, total do
		local line = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1]
		if line:match("^# %%%%") then
			vim.api.nvim_win_set_cursor(0, { i, 0 })
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
			vim.api.nvim_win_set_cursor(0, { i, 0 })
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
	local lines = { "", '# %% id="' .. new_id .. '"', "" }
	vim.api.nvim_buf_set_lines(0, e, e, false, lines)
	vim.api.nvim_win_set_cursor(0, { e + 3, 0 })
	vim.cmd("startinsert")
end

local function insert_markdown_cell_below()
	local _, e = Utils.get_cell_range()
	local new_id = Utils.generate_id()
	local lines = { "", '# %% [markdown] id="' .. new_id .. '"', "" }
	vim.api.nvim_buf_set_lines(0, e, e, false, lines)
	vim.api.nvim_win_set_cursor(0, { e + 3, 0 })
	vim.cmd("startinsert")
end

local function insert_cell_above()
	local s, _ = Utils.get_cell_range()
	local new_id = Utils.generate_id()
	local lines = { '# %% id="' .. new_id .. '"', "", "" }
	vim.api.nvim_buf_set_lines(0, s - 1, s - 1, false, lines)
	vim.api.nvim_win_set_cursor(0, { s + 1, 0 })
	vim.cmd("startinsert")
end

local function merge_cell_below()
	local _, e = Utils.get_cell_range()
	local total = vim.api.nvim_buf_line_count(0)
	if e >= total then
		return vim.notify("No cell below", vim.log.levels.WARN)
	end
	local line = vim.api.nvim_buf_get_lines(0, e, e + 1, false)[1]
	if line:match("^# %%%%") then
        -- Clear status on the header line being removed
        UI.clear_status_extmarks(0, e + 1, e + 2)
		vim.api.nvim_buf_set_lines(0, e, e + 1, false, {})
		vim.notify("Cells merged", vim.log.levels.INFO)
	else
		vim.notify("Could not find cell boundary below", vim.log.levels.WARN)
	end
end

function M.setup()
	-- Execution
	vim.api.nvim_create_user_command("JovianStart", Core.start_kernel, {})
	vim.api.nvim_create_user_command("JovianRun", Core.send_cell, {})
	vim.api.nvim_create_user_command("JovianSendSelection", Core.send_selection, { range = true })
	vim.api.nvim_create_user_command("JovianRunAll", Core.run_all_cells, {})
	vim.api.nvim_create_user_command("JovianRestart", Core.restart_kernel, {})

	-- Host Management
	vim.api.nvim_create_user_command("JovianAddHost", function(opts)
        local args = vim.split(opts.args, " ")
        
        local function process_add(name, host, python)
            if Hosts.exists(name) then
                vim.notify("Host '" .. name .. "' already exists. Use a different name.", vim.log.levels.ERROR)
                return
            end
            vim.cmd("redraw")
            local config = { type = "ssh", host = host, python = python }
            local ok, err = Hosts.validate_connection(config)
            if not ok then
                vim.notify("Validation Failed: " .. err, vim.log.levels.ERROR)
                return
            end
            Hosts.add_host(name, config)
        end

        if opts.args == "" or #args < 3 then
            -- Interactive mode
            vim.ui.input({ prompt = "Host Name (e.g., my-server): " }, function(name)
                if not name or name == "" then return end
                if Hosts.exists(name) then
                    vim.notify("Host '" .. name .. "' already exists.", vim.log.levels.ERROR)
                    return
                end
                vim.ui.input({ prompt = "SSH Host (e.g., user@1.2.3.4): " }, function(host)
                    if not host or host == "" then return end
                    vim.ui.input({ prompt = "Remote Python Path (e.g., /usr/bin/python3): " }, function(python)
                        if not python or python == "" then return end
                        process_add(name, host, python)
                    end)
                end)
            end)
        else
            process_add(args[1], args[2], args[3])
        end
    end, { nargs = "*" })

    vim.api.nvim_create_user_command("JovianAddLocal", function(opts)
        local args = vim.split(opts.args, " ")

        local function process_add(name, python)
            if Hosts.exists(name) then
                vim.notify("Host '" .. name .. "' already exists. Use a different name.", vim.log.levels.ERROR)
                return
            end
            vim.cmd("redraw")
            local config = { type = "local", python = python }
            local ok, err = Hosts.validate_connection(config)
            if not ok then
                vim.notify("Validation Failed: " .. err, vim.log.levels.ERROR)
                return
            end
            Hosts.add_host(name, config)
        end

        if opts.args == "" or #args < 2 then
            -- Interactive mode
            vim.ui.input({ prompt = "Config Name (e.g., project-venv): " }, function(name)
                if not name or name == "" then return end
                if Hosts.exists(name) then
                    vim.notify("Host '" .. name .. "' already exists.", vim.log.levels.ERROR)
                    return
                end
                vim.ui.input({ prompt = "Local Python Path (e.g., ./venv/bin/python): ", default = Config.options.python_interpreter }, function(python)
                    if not python or python == "" then return end
                    process_add(name, python)
                end)
            end)
        else
            process_add(args[1], args[2])
        end
    end, { nargs = "*" })

    vim.api.nvim_create_user_command("JovianUse", function(opts)
        local name = opts.args
        if name == "" then
            -- Interactive selection
            local data = Hosts.load_hosts()
            local names = vim.tbl_keys(data.configs)
            table.sort(names)
            vim.ui.select(names, { prompt = "Select Host:" }, function(selected)
                if selected then
                    Hosts.use_host(selected)
                end
            end)
        else
            Hosts.use_host(name)
        end
    end, { nargs = "?" })

    vim.api.nvim_create_user_command("JovianRemoveHost", function(opts)
        local name = opts.args
        if name == "" then
            -- Interactive selection
            local data = Hosts.load_hosts()
            local names = {}
            for name, _ in pairs(data.configs) do
                if name ~= "local_default" then
                    table.insert(names, name)
                end
            end
            table.sort(names)
            vim.ui.select(names, { prompt = "Remove Host:" }, function(selected)
                if selected then
                    Hosts.remove_host(selected)
                end
            end)
        else
            Hosts.remove_host(name)
        end
    end, { nargs = "?" })

	-- UI
	vim.api.nvim_create_user_command("JovianOpen", function()
		UI.open_windows()
	end, {})
	vim.api.nvim_create_user_command("JovianToggle", UI.toggle_windows, {})
	vim.api.nvim_create_user_command("JovianClear", UI.clear_repl, {})
	vim.api.nvim_create_user_command("JovianClean", Core.clean_stale_cache, {})
	vim.api.nvim_create_user_command("JovianClearDiag", UI.clear_diagnostics, {})
    vim.api.nvim_create_user_command("JovianToggleVars", UI.toggle_variables_pane, {})

	-- Data & Tools
	vim.api.nvim_create_user_command("JovianVars", function()
        Core.show_variables({ force_float = true }) 
    end, {})
	vim.api.nvim_create_user_command("JovianView", Core.view_dataframe, { nargs = "?" })
	vim.api.nvim_create_user_command("JovianCopy", Core.copy_variable, { nargs = "?" })
	vim.api.nvim_create_user_command("JovianProfile", Core.run_profile_cell, {})

	-- Navigation
	vim.api.nvim_create_user_command("JovianNextCell", goto_next_cell, {})
	vim.api.nvim_create_user_command("JovianPrevCell", goto_prev_cell, {})
	vim.api.nvim_create_user_command("JovianNewCellBelow", insert_cell_below, {})
    vim.api.nvim_create_user_command("JovianNewMarkdownCellBelow", insert_markdown_cell_below, {})
	vim.api.nvim_create_user_command("JovianNewCellAbove", insert_cell_above, {})
	vim.api.nvim_create_user_command("JovianMergeBelow", merge_cell_below, {})

	-- Kernel Control
	vim.api.nvim_create_user_command("JovianInterrupt", Core.interrupt_kernel, {})

	-- Plotting
	vim.api.nvim_create_user_command("JovianDoc", function(opts)
		require("jovian.core").inspect_object(opts)
	end, { nargs = "?" })
	vim.api.nvim_create_user_command("JovianPeek", function(opts)
		require("jovian.core").peek_symbol(opts)
	end, { nargs = "?" })
    vim.api.nvim_create_user_command("JovianTogglePlot", function()
        require("jovian.core").toggle_plot_view()
    end, {})

	-- Cell Editing
	vim.api.nvim_create_user_command("JovianDeleteCell", function()
		require("jovian.utils").delete_cell()
        require("jovian.core").check_structure_change()
	end, {})
	vim.api.nvim_create_user_command("JovianMoveCellUp", function()
		require("jovian.utils").move_cell_up()
        require("jovian.core").check_structure_change()
	end, {})
	vim.api.nvim_create_user_command("JovianMoveCellDown", function()
		require("jovian.utils").move_cell_down()
        require("jovian.core").check_structure_change()
	end, {})
	vim.api.nvim_create_user_command("JovianSplitCell", function()
		require("jovian.utils").split_cell()
        require("jovian.core").check_structure_change()
	end, {})

	-- Execution Control
	vim.api.nvim_create_user_command("JovianRunAndNext", function()
		require("jovian.core").run_and_next()
	end, {})
	vim.api.nvim_create_user_command("JovianRunLine", function()
		require("jovian.core").run_line()
	end, {})

    vim.api.nvim_create_user_command("JovianClearCache", function()
        require("jovian.core").clear_current_cell_cache()
    end, {})
    vim.api.nvim_create_user_command("JovianClearAllCache", function()
        require("jovian.core").clear_all_cache()
    end, {})

    vim.api.nvim_create_user_command("JovianCleanCache", function()
        require("jovian.core").clean_orphaned_caches()
        vim.notify("Cleaned orphaned caches", vim.log.levels.INFO)
    end, {})
	vim.api.nvim_create_user_command("JovianRunAbove", function()
		require("jovian.core").run_cells_above()
	end, {})
end

return M
