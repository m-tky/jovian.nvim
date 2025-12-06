local M = {}
local Config = require("jovian.config")
local State = require("jovian.state")
local Windows = require("jovian.ui.windows")
local Windows = require("jovian.ui.windows")
local Renderers = require("jovian.ui.renderers")

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
-- We need to access Elements from Windows module, or define them here.
-- Since Elements use Windows functions, and Windows functions use Elements (in open_layout),
-- we have a circular dependency if we are not careful.
-- `open_layout` was in `windows.lua`.
-- `Elements` was local in `windows.lua`.
-- Let's redefine Elements here but use Windows functions.
-- Or better, expose Elements in Windows?
-- Actually, `open_layout` is the main user of `Elements`.
-- `open_windows` calls `open_layout`.
-- If `open_windows` stays in `windows.lua`, it needs `open_layout`.
-- So `windows.lua` depends on `layout.lua`.
-- `layout.lua` depends on `windows.lua` (for `get_or_create_buf` etc).
-- This is circular.

-- Solution:
-- Move `Elements` and `open_layout` and `resize_windows` to `layout.lua`.
-- `open_windows` moves to `layout.lua` too?
-- `open_windows` is high level.
-- `windows.lua` should be low level (buffer/window creation).
-- `layout.lua` should be high level (orchestration).
-- So `open_windows`, `toggle_windows`, `open_pin_window` should move to `layout.lua`.
-- `windows.lua` keeps `get_or_create_buf`, `cleanup_buffer`, `lock_layout`, `apply_window_options`, `close_windows`?
-- `close_windows` iterates State.win.
-- `toggle_windows` calls `close_windows` or `open_windows`.

-- Let's move high-level logic to `layout.lua`.

local Elements = {
    preview = {
        open = function()
            if not State.buf.preview or not vim.api.nvim_buf_is_valid(State.buf.preview) then
                State.buf.preview = Windows.get_or_create_buf("JovianPreview")
            end
            return State.buf.preview
        end,
        setup = function(win)
            Windows.apply_window_options(win, { wrap = true })
            State.win.preview = win
        end
    },
    output = {
        open = function()
            if not State.buf.output or not vim.api.nvim_buf_is_valid(State.buf.output) then
                State.buf.output = Windows.get_or_create_buf("JovianOutput")
            end
            return State.buf.output
        end,
        setup = function(win)
            Windows.apply_window_options(win, { wrap = true })
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
            Windows.apply_window_options(win, { wrap = false })
            State.win.variables = win
            require("jovian.ui.renderers").render_variables_pane({})
        end
    },
    pin = {
        open = function()
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
            Windows.apply_window_options(win, { wrap = true })
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
    
    -- Calculate total size units
    local elements = layout.elements
    local total_units = 0
    for _, el in ipairs(elements) do
        total_units = total_units + (el.size or 1)
    end
    
    -- Get container size BEFORE splitting
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
    for _, item in ipairs(created_wins) do
        local win = item.win
        if vim.api.nvim_win_is_valid(win) then
            local ratio = item.size / total_units
            local target_size = math.floor(total_pixels * ratio)
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
    local parent_win = target_win or vim.api.nvim_get_current_win()

    -- Save equalalways state
    local ea = vim.o.equalalways
    vim.o.equalalways = false

    -- Use configured layouts
    local layouts = Config.options.ui.layouts
    if not layouts then
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

function M.toggle_windows()
    local any_open = false
    local wins = {State.win.preview, State.win.output, State.win.variables, State.win.pin}
    
    for _, win in pairs(wins) do
        if win and vim.api.nvim_win_is_valid(win) then
            any_open = true
            break
        end
    end
    
    if any_open then
        Windows.close_windows()
    else
        M.open_windows()
    end
end

function M.resize_windows()
    local layouts = Config.options.ui.layouts
    if not layouts then return end
    
    for _, layout in ipairs(layouts) do
        local elements = layout.elements
        local active_wins = {}
        
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
            local pos = layout.position or "right"
            local size = layout.size or 40
            local is_vertical_stack = (pos == "left" or pos == "right")
            
            local container_size = size
            if type(size) == "number" and size > 0 and size < 1 then
                if is_vertical_stack then
                    container_size = math.floor(vim.o.columns * size)
                else
                    container_size = math.floor(vim.o.lines * size)
                end
            end
            
            for _, item in ipairs(active_wins) do
                if is_vertical_stack then
                    vim.api.nvim_win_set_width(item.win, container_size)
                    vim.wo[item.win].winfixwidth = true
                else
                    vim.api.nvim_win_set_height(item.win, container_size)
                    vim.wo[item.win].winfixheight = true
                end
            end
            
            local total_pixels = 0
            for _, item in ipairs(active_wins) do
                if is_vertical_stack then
                    total_pixels = total_pixels + vim.api.nvim_win_get_height(item.win)
                else
                    total_pixels = total_pixels + vim.api.nvim_win_get_width(item.win)
                end
            end
            
            if total_pixels == 0 then
                 if is_vertical_stack then
                    total_pixels = vim.o.lines - vim.o.cmdheight - 1
                 else
                    total_pixels = vim.o.columns
                 end
            end
            
            local total_units = 0
            for _, item in ipairs(active_wins) do
                total_units = total_units + item.size
            end
            
            for _, item in ipairs(active_wins) do
                local ratio = item.size / total_units
                local target_size = math.floor(total_pixels * ratio)
                target_size = math.max(1, target_size)
                
                if is_vertical_stack then
                    vim.api.nvim_win_set_height(item.win, target_size)
                    vim.wo[item.win].winfixheight = true
                else
                    vim.api.nvim_win_set_width(item.win, target_size)
                    vim.wo[item.win].winfixwidth = true
                end
            end
        end
    end
end

function M.open_pin_window()
    if State.win.pin and vim.api.nvim_win_is_valid(State.win.pin) then
        return
    end

    local cur_win = vim.api.nvim_get_current_win()

    local target_win = State.win.preview
    if not (target_win and vim.api.nvim_win_is_valid(target_win)) then
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

        if State.win.pin and vim.api.nvim_win_is_valid(State.win.pin) then
            return
        end
        
        target_win = State.win.preview
    end
    
    if not (target_win and vim.api.nvim_win_is_valid(target_win)) then
        return 
    end
    
    vim.api.nvim_set_current_win(target_win)
    vim.cmd("belowright split")
    State.win.pin = vim.api.nvim_get_current_win()
    
    local height = math.floor(vim.o.lines * 0.3)
    vim.api.nvim_win_set_height(State.win.pin, height)
    
    Windows.apply_window_options(State.win.pin, { wrap = true })
    
    if cur_win and vim.api.nvim_win_is_valid(cur_win) then
        vim.api.nvim_set_current_win(cur_win)
    end

    if State.current_pin_file then
        Windows.pin_cell(State.current_pin_file)
    else
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "No pinned content" })
        vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
        vim.api.nvim_buf_set_option(buf, "modifiable", false)
        vim.api.nvim_win_set_buf(State.win.pin, buf)
        
        Windows.apply_window_options(State.win.pin, { wrap = true })
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

    -- Set width (default 25%)
    local width = math.floor(vim.o.columns * 0.25)
    vim.api.nvim_win_set_width(State.win.variables, width)

    -- Window options
    Windows.apply_window_options(State.win.variables, { wrap = false })
    
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

return M
