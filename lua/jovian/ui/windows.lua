local M = {}
local Config = require("jovian.config")
local State = require("jovian.state")
local Shared = require("jovian.ui.shared")
local Renderers = require("jovian.ui.renderers")

function M.get_or_create_buf(name)
	local existing = vim.fn.bufnr(name)
	if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
		return existing
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, name)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(buf, "modifiable", false)

	-- Open as terminal mode here and save channel ID
	State.term_chan = vim.api.nvim_open_term(buf, {})

	return buf
end

function M.open_windows(target_win)
	-- Get "current" if no argument,
	-- but ensure target_win is passed if called from toggle_windows
	local return_to = target_win or vim.api.nvim_get_current_win()

	-- Preview Window
	if not (State.win.preview and vim.api.nvim_win_is_valid(State.win.preview)) then
		vim.cmd("vsplit")
		vim.cmd("wincmd L")
		State.win.preview = vim.api.nvim_get_current_win()
		local width = math.floor(vim.o.columns * (Config.options.preview_width_percent / 100))
		vim.api.nvim_win_set_width(State.win.preview, width)
		local pbuf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(State.win.preview, pbuf)

		-- Appearance settings
		local win = State.win.preview
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].foldcolumn = "0"
		vim.wo[win].fillchars = "eob: "
	end

	-- REPL Window
	if not (State.win.output and vim.api.nvim_win_is_valid(State.win.output)) then
		-- Return focus to "code" before splitting
		-- Otherwise it might split from the Preview window
		if vim.api.nvim_win_is_valid(return_to) then
			vim.api.nvim_set_current_win(return_to)
		end

		vim.cmd("belowright split")
		-- vim.cmd("wincmd j") -- belowright puts us in the new bottom window
		State.win.output = vim.api.nvim_get_current_win()
		State.buf.output = M.get_or_create_buf("JovianConsole")

		if vim.api.nvim_buf_line_count(State.buf.output) <= 1 then
			Shared.append_to_repl("[Jovian Console Ready]", "Special")
		end

		vim.api.nvim_win_set_buf(State.win.output, State.buf.output)
		local height = math.floor(vim.o.lines * (Config.options.repl_height_percent / 100))
		vim.api.nvim_win_set_height(State.win.output, height)

		-- Appearance settings
		local win = State.win.output
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].scrolloff = 0
		vim.wo[win].fillchars = "eob: "
	end

	-- Fix: Return synchronously once, and also via schedule as a backup
	if return_to and vim.api.nvim_win_is_valid(return_to) then
		vim.api.nvim_set_current_win(return_to)
	end

	vim.defer_fn(function()
		if return_to and vim.api.nvim_win_is_valid(return_to) then
			vim.api.nvim_set_current_win(return_to)
			-- Call stopinsert just in case we entered terminal mode
			vim.cmd("stopinsert")
		end
	end, 50)

    -- Auto-open Vars pane if configured
    if Config.options.toggle_var then
        if not (State.win.variables and vim.api.nvim_win_is_valid(State.win.variables)) then
            M.toggle_variables_pane()
        end
    end

    -- Trigger preview check immediately
    require("jovian.core").check_cursor_cell()
end

function M.close_windows()
	if State.win.preview and vim.api.nvim_win_is_valid(State.win.preview) then
		vim.api.nvim_win_close(State.win.preview, true)
	end
	if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
		vim.api.nvim_win_close(State.win.output, true)
	end
    
    -- Auto-close Vars pane if configured
    if Config.options.toggle_var then
        if State.win.variables and vim.api.nvim_win_is_valid(State.win.variables) then
            vim.api.nvim_win_close(State.win.variables, true)
            State.win.variables = nil
        end
    end

	State.win.preview, State.win.output = nil, nil
	State.current_preview_file = nil
end

function M.toggle_windows()
	-- Fix: Reliably capture the window ID (code window) before execution
	local cur_win = vim.api.nvim_get_current_win()

	if
		(State.win.preview and vim.api.nvim_win_is_valid(State.win.preview))
		or (State.win.output and vim.api.nvim_win_is_valid(State.win.output))
	then
		-- Closing
		M.close_windows()

		-- After closing, return to original window if it still exists
		if vim.api.nvim_win_is_valid(cur_win) then
			vim.api.nvim_set_current_win(cur_win)
		end
	else
		-- Opening: Pass captured cur_win as "return destination"
		M.open_windows(cur_win)
	end
end

function M.open_markdown_preview(filepath)
	if not (State.win.preview and vim.api.nvim_win_is_valid(State.win.preview)) then
		return
	end

	-- Capture the old buffer *before* switching
	local old_buf = vim.api.nvim_win_get_buf(State.win.preview)

	local abs_filepath = vim.fn.fnamemodify(filepath, ":p")
	State.current_preview_file = abs_filepath
    
    -- Use bufadd to create/get buffer without switching windows
    local buf = vim.fn.bufadd(abs_filepath)
    if buf == 0 then return end -- Failed
    
    -- Load the buffer if not loaded
    if not vim.api.nvim_buf_is_loaded(buf) then
        vim.fn.bufload(buf)
    end
    
    -- Set buffer to preview window
    vim.api.nvim_win_set_buf(State.win.preview, buf)
	
	-- Set read-only and non-modifiable
	vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
    -- Keep buftype empty (normal file) but set readonly
    vim.api.nvim_buf_set_option(buf, "buftype", "")
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    vim.api.nvim_buf_set_option(buf, "readonly", true)
	
	vim.wo[State.win.preview].wrap = true

    -- Cleanup old buffer if it's different and valid
    if old_buf and old_buf ~= buf and vim.api.nvim_buf_is_valid(old_buf) then
        -- Check if it was a jovian preview buffer (optional, but safer)
        -- For now, we assume anything in the preview window was a preview buffer.
        vim.api.nvim_buf_delete(old_buf, { force = true })
    end
end

function M.toggle_variables_pane()
    if State.win.variables and vim.api.nvim_win_is_valid(State.win.variables) then
        vim.api.nvim_win_close(State.win.variables, true)
        State.win.variables = nil
        return
    end

    -- Target REPL window if it exists, otherwise current
    local target_win = vim.api.nvim_get_current_win()
    if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
        target_win = State.win.output
    end
    
    -- Switch to target window to ensure split happens there
    vim.api.nvim_set_current_win(target_win)

    -- Open persistent split to the right
    vim.cmd("rightbelow vsplit")
    State.win.variables = vim.api.nvim_get_current_win()
    
    -- Check for existing buffer and wipe it to avoid name conflict
    local existing = vim.fn.bufnr("JovianVariables")
    if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
    end

    -- Create buffer
    State.buf.variables = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(State.buf.variables, "JovianVariables")
    vim.api.nvim_buf_set_option(State.buf.variables, "buftype", "nofile")
    vim.api.nvim_buf_set_option(State.buf.variables, "filetype", "jovian_vars")
    vim.api.nvim_win_set_buf(State.win.variables, State.buf.variables)

    -- Set width
    local width_percent = Config.options.vars_pane_width_percent or 20
    local width = math.floor(vim.o.columns * (width_percent / 100))
    vim.api.nvim_win_set_width(State.win.variables, width)

    -- Window options
    local win = State.win.variables
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false
    
    -- Initial render
    Renderers.render_variables_pane({})
    
    -- If kernel is running, request update
    if State.job_id then
        require("jovian.core").show_variables()
    end
end

function M.update_variables_pane()
    if State.win.variables and vim.api.nvim_win_is_valid(State.win.variables) then
        require("jovian.core").show_variables()
    end
end

return M
