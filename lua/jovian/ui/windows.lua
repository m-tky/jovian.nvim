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

-- Helper to lock window layout to prevent shifts
local function lock_layout()
    local wins_to_lock = {}
    if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
        table.insert(wins_to_lock, State.win.output)
    end
    if State.win.variables and vim.api.nvim_win_is_valid(State.win.variables) then
        table.insert(wins_to_lock, State.win.variables)
    end
    if State.win.preview and vim.api.nvim_win_is_valid(State.win.preview) then
        table.insert(wins_to_lock, State.win.preview)
    end
    
    local original_opts = {}
    for _, win in ipairs(wins_to_lock) do
        original_opts[win] = {
            wfw = vim.wo[win].winfixwidth,
            wfh = vim.wo[win].winfixheight
        }
        vim.wo[win].winfixwidth = true
        vim.wo[win].winfixheight = true
    end
    return original_opts
end

-- Helper to unlock window layout
local function unlock_layout(original_opts)
    for win, opts in pairs(original_opts) do
        if vim.api.nvim_win_is_valid(win) then
            vim.wo[win].winfixwidth = opts.wfw
            vim.wo[win].winfixheight = opts.wfh
        end
    end
end

-- Helper to apply standard window options
local function apply_window_options(win, opts)
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

function M.toggle_windows()
    -- Check if any window is open
    local any_open = false
    local wins = {State.win.preview, State.win.output, State.win.variables, State.win.pin}
    
    for _, win in pairs(wins) do
        if win and vim.api.nvim_win_is_valid(win) then
            any_open = true
            break
        end
    end
    
    if any_open then
        M.close_windows()
    else
        M.open_windows()
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
	
	apply_window_options(State.win.preview, { wrap = true })

    -- Cleanup old buffer
    cleanup_buffer(old_buf, buf)
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

    -- Set width (default 25%)
    local width = math.floor(vim.o.columns * 0.25)
    vim.api.nvim_win_set_width(State.win.variables, width)

    -- Window options
    apply_window_options(State.win.variables, { wrap = false })
    
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

-- Element Registry
local Elements = {
    preview = {
        open = function()
            if not State.buf.preview or not vim.api.nvim_buf_is_valid(State.buf.preview) then
                State.buf.preview = M.get_or_create_buf("JovianPreview")
            end
            return State.buf.preview
        end,
        setup = function(win)
            apply_window_options(win, { wrap = true })
            State.win.preview = win
        end
    },
    output = {
        open = function()
            if not State.buf.output or not vim.api.nvim_buf_is_valid(State.buf.output) then
                State.buf.output = M.get_or_create_buf("JovianOutput")
            end
            return State.buf.output
        end,
        setup = function(win)
            apply_window_options(win, { wrap = true })
            State.win.output = win
        end
    },
    variables = {
        open = function()
            if not State.buf.variables or not vim.api.nvim_buf_is_valid(State.buf.variables) then
                State.buf.variables = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_name(State.buf.variables, "JovianVariables")
                vim.api.nvim_buf_set_option(State.buf.variables, "buftype", "nofile")
                vim.api.nvim_buf_set_option(State.buf.variables, "filetype", "jovian_vars")
            end
            return State.buf.variables
        end,
        setup = function(win)
            apply_window_options(win, { wrap = false })
            State.win.variables = win
            Renderers.render_variables_pane({})
        end
    },
    pin = {
        open = function()
            -- We don't create a specific buffer here, usually it's dynamic.
            -- But we need to return *something*.
            -- If we have a pinned file, use it.
            if State.current_pin_file then
                local buf = vim.fn.bufadd(State.current_pin_file)
                if not vim.api.nvim_buf_is_loaded(buf) then vim.fn.bufload(buf) end
                return buf
            else
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "No pinned content" })
                vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
                vim.api.nvim_buf_set_option(buf, "modifiable", false)
                return buf
            end
        end,
        setup = function(win)
            apply_window_options(win, { wrap = true })
            State.win.pin = win
        end
    }
}

function M.open_layout(layout, parent_win)
    local pos = layout.position or "right"
    local size = layout.size or 40
    
    -- Ensure we split from the parent window
    if parent_win and vim.api.nvim_win_is_valid(parent_win) then
        vim.api.nvim_set_current_win(parent_win)
    end
    
    local split_cmd = "vsplit"
    if pos == "top" or pos == "bottom" then
        split_cmd = "split"
    end
    
    -- Handle percentage size
    if type(size) == "number" and size > 0 and size < 1 then
        if pos == "top" or pos == "bottom" then
            size = math.floor(vim.o.lines * size)
        else
            size = math.floor(vim.o.columns * size)
        end
    end
    
    local split_mod = "belowright"
    if pos == "top" or pos == "left" then
        split_mod = "topleft"
    end
    
    -- Open main split
    vim.cmd(split_mod .. " " .. size .. split_cmd)
    local main_win = vim.api.nvim_get_current_win()
    
    -- Fix size to prevent resizing by other layouts
    if pos == "left" or pos == "right" then
        vim.wo[main_win].winfixwidth = true
    elseif pos == "top" or pos == "bottom" then
        vim.wo[main_win].winfixheight = true
    end
    
    -- We need to track this window to close it later?
    -- Actually, we will split inside it, so the main window becomes one of the elements.
    
    -- Calculate total size units
    local elements = layout.elements
    local total_units = 0
    for _, el in ipairs(elements) do
        total_units = total_units + (el.size or 1)
    end
    
    -- Get container size BEFORE splitting
    -- If pos is right/left, we are stacking vertically (heights)
    -- If pos is top/bottom, we are stacking horizontally (widths)
    local is_vertical_stack = (pos == "left" or pos == "right")
    local total_pixels = 0
    if is_vertical_stack then
        total_pixels = vim.api.nvim_win_get_height(main_win)
    else
        total_pixels = vim.api.nvim_win_get_width(main_win)
    end
    
    -- Iterate elements
    local current_win = main_win
    local created_wins = {} -- Store windows to resize later
    
    for i, el in ipairs(elements) do
        local handler = Elements[el.id]
        if handler then
            if i > 1 then
                -- Split the previous window
                local sub_split_cmd = "split" -- Default for side panel (stack vertically)
                if pos == "top" or pos == "bottom" then
                    sub_split_cmd = "vsplit" -- Stack horizontally for top/bottom panels
                end
                
                vim.api.nvim_set_current_win(current_win)
                vim.cmd("belowright " .. sub_split_cmd)
                current_win = vim.api.nvim_get_current_win()
            end
            
            -- Store window
            table.insert(created_wins, { win = current_win, size = el.size or 1 })
            
            -- Set buffer
            local buf = handler.open()
            vim.api.nvim_win_set_buf(current_win, buf)
            handler.setup(current_win)
        end
    end
    
    -- Resize elements
    -- Apply sizes
    for _, item in ipairs(created_wins) do
        local win = item.win
        if vim.api.nvim_win_is_valid(win) then
            local ratio = item.size / total_units
            local target_size = math.floor(total_pixels * ratio)
            
            -- Ensure minimum size of 1
            target_size = math.max(1, target_size)

            if is_vertical_stack then
                vim.api.nvim_win_set_height(win, target_size)
                vim.wo[win].winfixheight = true
            else
                vim.api.nvim_win_set_width(win, target_size)
                vim.wo[win].winfixwidth = true
            end
        end
    end
end

function M.open_windows(target_win)
    -- Get "current" if no argument, but we want the "code" window usually.
    local parent_win = target_win or vim.api.nvim_get_current_win()

    -- Save equalalways state and disable it to prevent auto-resizing
    local ea = vim.o.equalalways
    vim.o.equalalways = false

    -- Use configured layouts
    local layouts = Config.options.ui.layouts
    if not layouts then
        -- Fallback to default if not defined (should be in config)
        layouts = {
            {
                elements = {
                    { id = "preview", size = 0.35 },
                    { id = "output", size = 0.25 },
                    { id = "variables", size = 0.2 },
                    { id = "pin", size = 0.2 },
                },
                position = "right",
                size = 40,
            }
        }
    end
    
    for _, layout in ipairs(layouts) do
        M.open_layout(layout, parent_win)
    end
    
    -- Restore equalalways
    vim.o.equalalways = ea
    
    -- Restore focus to code window
    if parent_win and vim.api.nvim_win_is_valid(parent_win) then
        vim.api.nvim_set_current_win(parent_win)
    end
end

function M.open_pin_window()
    if State.win.pin and vim.api.nvim_win_is_valid(State.win.pin) then
        return
    end

    -- Capture current window to restore focus later
    local cur_win = vim.api.nvim_get_current_win()

    local target_win = State.win.preview
    if not (target_win and vim.api.nvim_win_is_valid(target_win)) then
        -- If preview is not open, open it first (it handles splitting)
        -- M.open_windows() -- This was the old call, now we use layouts
        
        -- For now, if preview is not open, we can't open pin window in it.
        -- This implies that the layout engine should be responsible for opening windows.
        -- If the user wants a pin window, they should define it in their layout.
        -- For backward compatibility, we'll try to open a default layout if no preview is found.
        local layouts = Config.options.ui.layouts
        if not layouts then
            layouts = {
                {
                    elements = {
                        { id = "preview", size = 0.4 },
                        { id = "output", size = 0.3 },
                        { id = "pin", size = 0.3 },
                    },
                    position = "right",
                    size = 40,
                }
            }
        end
        for _, layout in ipairs(layouts) do
            M.open_layout(layout)
        end

        -- Check if open_windows already opened the pin window (due to toggle_pin config)
        if State.win.pin and vim.api.nvim_win_is_valid(State.win.pin) then
            return
        end
        
        target_win = State.win.preview
    end
    
    if not (target_win and vim.api.nvim_win_is_valid(target_win)) then
        return -- Should not happen
    end
    
    vim.api.nvim_set_current_win(target_win)
    vim.cmd("belowright split")
    State.win.pin = vim.api.nvim_get_current_win()
    
    -- Set height (default 30%)
    local height = math.floor(vim.o.lines * 0.3)
    vim.api.nvim_win_set_height(State.win.pin, height)
    
    -- Window options
    apply_window_options(State.win.pin, { wrap = true })
    
    -- Restore focus to original window if possible
    if cur_win and vim.api.nvim_win_is_valid(cur_win) then
        vim.api.nvim_set_current_win(cur_win)
    end

    -- If we have a pinned file, load it. Otherwise show placeholder.
    if State.current_pin_file then
        M.pin_cell(State.current_pin_file)
    else
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "No pinned content" })
        vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
        vim.api.nvim_buf_set_option(buf, "modifiable", false)
        vim.api.nvim_win_set_buf(State.win.pin, buf)
        
        -- Apply window options again as setting buffer might reset some? No, win options persist.
        -- But let's be safe.
        apply_window_options(State.win.pin, { wrap = true })
    end
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
        
        apply_window_options(State.win.pin, { wrap = true })
        
        -- Cleanup old buffer
        cleanup_buffer(old_buf, buf)
    end
end

function M.toggle_pin_window()
    if State.win.pin and vim.api.nvim_win_is_valid(State.win.pin) then
        -- Lock layout to prevent shifts
        local layout_lock = lock_layout()
        
        vim.api.nvim_win_close(State.win.pin, true)
        State.win.pin = nil
        
        -- Unlock layout
        unlock_layout(layout_lock)
        
        return
    end
    
    M.open_pin_window()
end

function M.resize_windows()
    -- Iterate through configured layouts and resize if active
    local layouts = Config.options.ui.layouts
    if not layouts then return end
    
    for _, layout in ipairs(layouts) do
        local elements = layout.elements
        local active_wins = {}
        
        -- Check which windows from this layout are open
        for _, el in ipairs(elements) do
            local handler = {
                preview = State.win.preview,
                output = State.win.output,
                variables = State.win.variables,
                pin = State.win.pin
            }
            local win = handler[el.id]
            if win and vim.api.nvim_win_is_valid(win) then
                table.insert(active_wins, { win = win, size = el.size or 1, id = el.id })
            end
        end
        
        if #active_wins > 0 then
            -- Calculate container size
            local pos = layout.position or "right"
            local size = layout.size or 40
            local is_vertical_stack = (pos == "left" or pos == "right")
            
            -- Recalculate container size (width or height)
            local container_size = size
            if type(size) == "number" and size > 0 and size < 1 then
                if is_vertical_stack then
                    container_size = math.floor(vim.o.columns * size)
                else
                    container_size = math.floor(vim.o.lines * size)
                end
            end
            
            -- Apply container size to ALL active windows in this layout
            -- This ensures the "column" or "row" is resized
            for _, item in ipairs(active_wins) do
                if is_vertical_stack then
                    vim.api.nvim_win_set_width(item.win, container_size)
                    vim.wo[item.win].winfixwidth = true
                else
                    vim.api.nvim_win_set_height(item.win, container_size)
                    vim.wo[item.win].winfixheight = true
                end
            end
            
            -- Now resize internal elements (heights in a vertical stack, widths in horizontal)
            -- We need to know the total available pixels for the stack
            -- Instead of assuming full screen size, we sum the CURRENT dimensions of the active windows.
            -- This accounts for other windows (like sidebars) taking up space.
            
            local total_pixels = 0
            for _, item in ipairs(active_wins) do
                if is_vertical_stack then
                    -- Vertical stack: windows are stacked vertically.
                    -- We split the HEIGHT.
                    total_pixels = total_pixels + vim.api.nvim_win_get_height(item.win)
                else
                    -- Horizontal stack: windows are stacked horizontally.
                    -- We split the WIDTH.
                    total_pixels = total_pixels + vim.api.nvim_win_get_width(item.win)
                end
            end
            
            -- If total_pixels is 0 (shouldn't happen if windows are valid), fallback
            if total_pixels == 0 then
                 if is_vertical_stack then
                    total_pixels = vim.o.lines - vim.o.cmdheight - 1
                 else
                    total_pixels = vim.o.columns
                 end
            end
            
            -- Calculate total units of ACTIVE windows
            
            -- Calculate total units of ACTIVE windows
            local total_units = 0
            for _, item in ipairs(active_wins) do
                total_units = total_units + item.size
            end
            
            -- Apply sizes
            for _, item in ipairs(active_wins) do
                local ratio = item.size / total_units
                local target_size = math.floor(total_pixels * ratio)
                target_size = math.max(1, target_size)
                
                if is_vertical_stack then
                    -- Set HEIGHT
                    vim.api.nvim_win_set_height(item.win, target_size)
                    vim.wo[item.win].winfixheight = true
                else
                    -- Set WIDTH
                    vim.api.nvim_win_set_width(item.win, target_size)
                    vim.wo[item.win].winfixwidth = true
                end
            end
        end
    end
end

return M
