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

-- Helper to cleanup old buffer if not used elsewhere
local function cleanup_buffer(old_buf, current_buf)
    if old_buf and old_buf ~= current_buf and vim.api.nvim_buf_is_valid(old_buf) then
        -- Safety Check 1: Do not delete modified buffers
        if vim.api.nvim_buf_get_option(old_buf, "modified") then
            return
        end

        -- Safety Check 2: Only delete Jovian-managed buffers
        local buf_name = vim.api.nvim_buf_get_name(old_buf)
        -- Check if it's a file in .jovian_cache
        local is_jovian_cache = buf_name:find(".jovian_cache", 1, true)
        
        -- Check if it's a special buffer (like placeholder or terminal)
        -- We allow deleting nofile/terminal buffers as they are usually ephemeral
        local buftype = vim.api.nvim_buf_get_option(old_buf, "buftype")
        local is_ephemeral = (buftype == "nofile" or buftype == "terminal")

        if not (is_jovian_cache or is_ephemeral) then
            return
        end

        local wins = vim.fn.win_findbuf(old_buf)
        if #wins == 0 then
            vim.api.nvim_buf_delete(old_buf, { force = true })
        end
    end
end



-- Helper to apply standard window options
-- Helper to apply standard window options
function M.apply_window_options(win, opts)
    if not vim.api.nvim_win_is_valid(win) then return end
    
    local defaults = {
        number = false,
        relativenumber = false,
        signcolumn = "no",
        foldcolumn = "0",
        wrap = true,
        fillchars = "eob: "
    }
    
    opts = vim.tbl_extend("force", defaults, opts or {})
    
    for k, v in pairs(opts) do
        vim.wo[win][k] = v
    end
end

-- Legacy open_windows removed

function M.close_windows()
    -- Close all known windows
    local wins = {State.win.preview, State.win.output, State.win.variables, State.win.pin}
    for _, win in pairs(wins) do
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
    
    State.win.preview = nil
    State.win.output = nil
    State.win.variables = nil
    State.win.pin = nil
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
    else
        -- Force reload from disk to pick up changes
        vim.cmd("checktime " .. buf)
    end
    
    -- Set buffer to preview window
    vim.api.nvim_win_set_buf(State.win.preview, buf)
	
	-- Set read-only and non-modifiable
	vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
    -- Keep buftype empty (normal file) but set readonly
    vim.api.nvim_buf_set_option(buf, "buftype", "")
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    vim.api.nvim_buf_set_option(buf, "readonly", true)
	
	M.apply_window_options(State.win.preview, { wrap = true })

    -- Cleanup old buffer
    cleanup_buffer(old_buf, buf)
end





function M.pin_cell(filepath)
    local abs_filepath = vim.fn.fnamemodify(filepath, ":p")
    State.current_pin_file = abs_filepath
    
    -- Only update buffer if window is ALREADY open
    if not (State.win.pin and vim.api.nvim_win_is_valid(State.win.pin)) then
        return
    end
    
    -- Capture old buffer
    local old_buf = vim.api.nvim_win_get_buf(State.win.pin)
    
    -- Create/Get buffer
    local buf = vim.fn.bufadd(abs_filepath)
    if buf == 0 then return end
    
    if not vim.api.nvim_buf_is_loaded(buf) then
        vim.fn.bufload(buf)
    else
        vim.cmd("checktime " .. buf)
    end
    
    vim.api.nvim_win_set_buf(State.win.pin, buf)
    
    vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
    vim.api.nvim_buf_set_option(buf, "buftype", "")
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    vim.api.nvim_buf_set_option(buf, "readonly", true)
    
    -- Cleanup old buffer
    cleanup_buffer(old_buf, buf)
end

function M.unpin()
    State.current_pin_file = nil
    
    if State.win.pin and vim.api.nvim_win_is_valid(State.win.pin) then
        -- Capture old buffer
        local old_buf = vim.api.nvim_win_get_buf(State.win.pin)
        
        -- Show placeholder
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "No pinned content" })
        vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
        vim.api.nvim_buf_set_option(buf, "modifiable", false)
        vim.api.nvim_win_set_buf(State.win.pin, buf)
        
        M.apply_window_options(State.win.pin, { wrap = true })
        
        -- Cleanup old buffer
        cleanup_buffer(old_buf, buf)
    end
end





return M
