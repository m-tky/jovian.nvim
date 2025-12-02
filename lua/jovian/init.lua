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

function M.setup(opts)
	Config.setup(opts)
    require("jovian.diagnostics").setup()

    -- TreeSitter Queries
    local plugin_root = debug.getinfo(1).source:sub(2):match("(.*/)") .. "../.."
    local queries_path = plugin_root .. "/jovian_queries"
    
    -- If using a package manager, the path might be different, but usually relative to init.lua works.
    -- A more robust way is to find where the plugin is installed.
    -- However, since we are moving files, we can just assume standard structure.
    
    -- Actually, a better way is to use vim.api.nvim_get_runtime_file if we want to be safe, 
    -- but we are adding TO the runtime path.
    
    -- Let's try to find the directory relative to this file.
    -- This file is lua/jovian/init.lua.
    -- We want jovian_queries/.
    
    -- If installed via lazy/packer, it's in the root of the repo.
    
    if Config.options.treesitter.markdown_injection or Config.options.treesitter.magic_command_highlight then
        vim.opt.rtp:prepend(queries_path)
        
        -- Register custom predicate for magic command highlighting
        local ok, err = pcall(function()
            vim.treesitter.query.add_predicate("same-line?", function(match, pattern, bufnr, predicate)
                local node1 = match[predicate[2]]
                local node2 = match[predicate[3]]
                if not node1 or not node2 then return false end
                
                if type(node1) == "table" then node1 = node1[1] end
                if type(node2) == "table" then node2 = node2[1] end
                
                local r1, _, _, _ = node1:range()
                local r2, _, _, _ = node2:range()
                return r1 == r2
            end, true) -- force=true to overwrite if exists
        end)
    end

	-- Execution
	vim.api.nvim_create_user_command("JovianStart", Core.start_kernel, {})
	vim.api.nvim_create_user_command("JovianRun", Core.send_cell, {})
	vim.api.nvim_create_user_command("JovianSendSelection", Core.send_selection, { range = true })
	vim.api.nvim_create_user_command("JovianRunAll", Core.run_all_cells, {})
	vim.api.nvim_create_user_command("JovianRestart", Core.restart_kernel, {})

	-- Host Management
    local Hosts = require("jovian.hosts")
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
	vim.api.nvim_create_user_command("JovianVars", Core.show_variables, {})
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

	-- Fold
	vim.opt.foldmethod = "expr"
	vim.opt.foldexpr = "getline(v:lnum)=~'^#\\ %%'?'0':'1'"
	vim.opt.foldlevel = 99

	-- Kernel Control
	vim.api.nvim_create_user_command("JovianInterrupt", Core.interrupt_kernel, {})

	-- Session
	vim.api.nvim_create_user_command("JovianSaveSession", Core.save_session, { nargs = "?" })
	vim.api.nvim_create_user_command("JovianLoadSession", Core.load_session, { nargs = "?" })

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

	-- Keymaps (Optional, user can define their own)
	if Config.options.keymaps then
		-- Example keymaps (user can define their own in config)
		-- vim.keymap.set("n", "<leader>jn", "<cmd>JovianNextCell<CR>", { desc = "Jovian: Next Cell" })
		-- vim.keymap.set("n", "<leader>jp", "<cmd>JovianPrevCell<CR>", { desc = "Jovian: Previous Cell" })
		-- vim.keymap.set("n", "<leader>jr", "<cmd>JovianRun<CR>", { desc = "Jovian: Run Cell" })
		-- vim.keymap.set("v", "<leader>jr", "<cmd>JovianSendSelection<CR>", { desc = "Jovian: Run Selection" })
		-- vim.keymap.set("n", "<leader>jR", "<cmd>JovianRunAll<CR>", { desc = "Jovian: Run All Cells" })
		-- vim.keymap.set("n", "<leader>ja", "<cmd>JovianNewCellAbove<CR>", { desc = "Jovian: New Cell Above" })
		-- vim.keymap.set("n", "<leader>jb", "<cmd>JovianNewCellBelow<CR>", { desc = "Jovian: New Cell Below" })
		-- vim.keymap.set("n", "<leader>jd", "<cmd>JovianDeleteCell<CR>", { desc = "Jovian: Delete Cell" })
		-- vim.keymap.set("n", "<leader>jm", "<cmd>JovianMergeBelow<CR>", { desc = "Jovian: Merge Cell Below" })
		-- vim.keymap.set("n", "<leader>js", "<cmd>JovianSplitCell<CR>", { desc = "Jovian: Split Cell" })
		-- vim.keymap.set("n", "<leader>jU", "<cmd>JovianMoveCellUp<CR>", { desc = "Jovian: Move Cell Up" })
		-- vim.keymap.set("n", "<leader>jD", "<cmd>JovianMoveCellDown<CR>", { desc = "Jovian: Move Cell Down" })
		-- vim.keymap.set("n", "<leader>jo", "<cmd>JovianOpen<CR>", { desc = "Jovian: Open UI" })
		-- vim.keymap.set("n", "<leader>jt", "<cmd>JovianToggle<CR>", { desc = "Jovian: Toggle UI" })
		-- vim.keymap.set("n", "<leader>jc", "<cmd>JovianClear<CR>", { desc = "Jovian: Clear REPL" })
		-- vim.keymap.set("n", "<leader>jv", "<cmd>JovianVars<CR>", { desc = "Jovian: Show Variables" })
		-- vim.keymap.set("n", "<leader>jV", "<cmd>JovianView<CR>", { desc = "Jovian: View Dataframe" })
		-- vim.keymap.set("n", "<leader>jC", "<cmd>JovianCopy<CR>", { desc = "Jovian: Copy Variable" })
		-- vim.keymap.set("n", "<leader>jP", "<cmd>JovianProfile<CR>", { desc = "Jovian: Profile Cell" })
		-- vim.keymap.set("n", "<leader>ji", "<cmd>JovianInterrupt<CR>", { desc = "Jovian: Interrupt Kernel" })
		-- vim.keymap.set("n", "<leader>jS", "<cmd>JovianStart<CR>", { desc = "Jovian: Start Kernel" })
		-- vim.keymap.set("n", "<leader>jX", "<cmd>JovianRestart<CR>", { desc = "Jovian: Restart Kernel" })
		-- vim.keymap.set("n", "<leader>jL", "<cmd>JovianLoadSession<CR>", { desc = "Jovian: Load Session" })
		-- vim.keymap.set("n", "<leader>jW", "<cmd>JovianSaveSession<CR>", { desc = "Jovian: Save Session" })
		-- vim.keymap.set("n", "<leader>j?", "<cmd>JovianDoc<CR>", { desc = "Jovian: Inspect Object" })
		-- vim.keymap.set("n", "<leader>j.", "<cmd>JovianPeek<CR>", { desc = "Jovian: Peek Symbol" })
		-- vim.keymap.set("n", "<leader>jn", "<cmd>JovianRunAndNext<CR>", { desc = "Jovian: Run and Next" })
		-- vim.keymap.set("n", "<leader>jl", "<cmd>JovianRunLine<CR>", { desc = "Jovian: Run Line" })
	end

	vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
		pattern = "*",
		callback = function()
			if vim.bo.filetype == "python" then
				Core.check_cursor_cell()
			end
		end,
	})

    -- Add: Clean stale cache on save, close, and exit
    vim.api.nvim_create_autocmd({ "BufWritePost", "VimLeavePre", "BufUnload" }, {
        pattern = "*.py",
        callback = function(ev)
            Core.clean_stale_cache(ev.buf)
        end,
    })

    -- Add: Debounced structure check on text change
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        pattern = "*.py",
        callback = function()
            Core.schedule_structure_check()
        end,
    })
end

return M
