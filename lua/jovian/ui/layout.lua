local M = {}
local Config = require("jovian.config")
local State = require("jovian.state")
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
            wfh = vim.wo[win].winfixheight,
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

local function get_effective_height()
    local h = vim.o.lines - vim.o.cmdheight
    if vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1) then
        h = h - 1
    end
    if vim.o.laststatus == 3 then
        h = h - 1
    end
    return h
end
-- Window Elements Definitions
-- These define how to open and setup specific UI components

local function create_variables_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "JovianVariables")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = "jovian_vars"
    return buf
end

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
        end,
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
        end,
    },
    variables = {
        open = function()
            if not State.buf.variables or not vim.api.nvim_buf_is_valid(State.buf.variables) then
                State.buf.variables = create_variables_buf()
            end
            return State.buf.variables
        end,
        setup = function(win)
            Windows.apply_window_options(win, { wrap = false })
            State.win.variables = win
            require("jovian.ui.renderers").render_variables_pane({})
        end,
    },
    pin = {
        open = function()
            if State.current_pin then
                if not State.buf.pin or not vim.api.nvim_buf_is_valid(State.buf.pin) then
                    State.buf.pin = Windows.get_or_create_buf("JovianPin")
                end
                return State.buf.pin
            else
                return Windows.placeholder_buf()
            end
        end,
        setup = function(win)
            Windows.apply_window_options(win, { wrap = true })
            State.win.pin = win
            if State.current_pin then
                require("jovian.ui.output_render").render_to_buffer(
                    State.buf.pin,
                    win,
                    State.current_pin.src,
                    State.current_pin.cell_id
                )
            end
        end,
    },
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
            size = math.floor(get_effective_height() * size)
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
    local total_pixels
    if is_vertical_stack then
        total_pixels = get_effective_height()
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
    -- Sort by size (descending) so larger windows are resized first, allowing smaller ones (last) to enforce size
    table.sort(created_wins, function(a, b)
        return a.size > b.size
    end)

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
            },
        }
    end

    for _, layout in ipairs(layouts) do
        M.open_layout(layout, parent_win)
    end

    -- Output window is not part of the persistent layout; open it here
    -- only when the user wants it always visible.
    if Config.options.output_window == "always" then
        M.open_output_window()
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
    local wins = { State.win.preview, State.win.output, State.win.variables, State.win.pin }

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
    if not layouts then
        return
    end

    for _, layout in ipairs(layouts) do
        local elements = layout.elements
        local active_wins = {}

        for _, el in ipairs(elements) do
            local handler = {
                preview = State.win.preview,
                output = State.win.output,
                variables = State.win.variables,
                pin = State.win.pin,
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
                    container_size = math.floor(get_effective_height() * size)
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
            if is_vertical_stack then
                total_pixels = get_effective_height()
            else
                for _, item in ipairs(active_wins) do
                    total_pixels = total_pixels + vim.api.nvim_win_get_width(item.win)
                end
                if total_pixels == 0 then
                    total_pixels = vim.o.columns
                end
            end

            local total_units = 0
            for _, item in ipairs(active_wins) do
                total_units = total_units + item.size
            end

            -- Sort by size (descending)
            table.sort(active_wins, function(a, b)
                return a.size > b.size
            end)

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
                },
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

    local height = math.floor(get_effective_height() * 0.3)
    vim.api.nvim_win_set_height(State.win.pin, height)

    Windows.apply_window_options(State.win.pin, { wrap = true })

    if cur_win and vim.api.nvim_win_is_valid(cur_win) then
        vim.api.nvim_set_current_win(cur_win)
    end

    if State.current_pin then
        Windows.pin_cell(State.current_pin.src, State.current_pin.cell_id)
    else
        vim.api.nvim_win_set_buf(State.win.pin, Windows.placeholder_buf())
        Windows.apply_window_options(State.win.pin, { wrap = true })
    end
end

-- Find the main code window: the focused window if it's not a jovian
-- panel, otherwise the first non-panel window. Used so the Output split
-- carves out of the code column rather than spanning the full width
-- (which would squish the left-side preview/pin column).
local function find_code_win()
    local panel = {}
    for _, w in ipairs({ State.win.preview, State.win.output, State.win.variables, State.win.pin }) do
        if w then
            panel[w] = true
        end
    end
    local cur = vim.api.nvim_get_current_win()
    if not panel[cur] then
        return cur
    end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if not panel[w] then
            return w
        end
    end
    return cur
end

-- Open the Output (REPL) window as a horizontal split BELOW the code
-- window — not `botright` (full width), which would shorten the left
-- preview/pin column. The buffer + term channel are created lazily by
-- the writers (ui/shared.ensure_output_term), so output produced while
-- the window was closed is already there when it opens.
function M.open_output_window()
    if Config.options.output_window == "off" then
        return
    end
    if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
        return
    end
    require("jovian.ui.shared").ensure_output_term()
    if not (State.buf.output and vim.api.nvim_buf_is_valid(State.buf.output)) then
        return
    end

    local cur_win = vim.api.nvim_get_current_win()
    local code_win = find_code_win()
    if code_win and vim.api.nvim_win_is_valid(code_win) then
        vim.api.nvim_set_current_win(code_win)
    end
    -- `belowright split` (not botright) keeps the new window within the
    -- code window's column, leaving the preview/pin column untouched.
    vim.cmd("belowright split")
    State.win.output = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(State.win.output, State.buf.output)
    -- Match the Pin window's height so the bottom row (pin on the left
    -- column, output on the code column) lines up. Fall back to 25% of
    -- the screen when the pin window isn't open.
    local height
    if State.win.pin and vim.api.nvim_win_is_valid(State.win.pin) then
        height = vim.api.nvim_win_get_height(State.win.pin)
    else
        height = math.floor(get_effective_height() * 0.25)
    end
    vim.api.nvim_win_set_height(State.win.output, math.max(height, 5))
    vim.wo[State.win.output].winfixheight = true
    Windows.apply_window_options(State.win.output, { wrap = true })

    -- In the Output window, `i` / `e` starts a continuous eval session in
    -- the kernel (prompt → run → re-prompt; empty line exits). Runs with
    -- store_history=false so nothing pollutes In/Out. (`i` would otherwise
    -- drop into terminal insert mode, useless for our read-only log.)
    local buf = State.buf.output
    local function map(lhs)
        vim.keymap.set("n", lhs, function()
            require("jovian.core").eval_repl()
        end, { buffer = buf, desc = "Jovian: eval session in kernel" })
    end
    map("i")
    map("e")

    -- Scroll to the latest output.
    local count = vim.api.nvim_buf_line_count(State.buf.output)
    pcall(vim.api.nvim_win_set_cursor, State.win.output, { count, 0 })

    if cur_win and vim.api.nvim_win_is_valid(cur_win) then
        vim.api.nvim_set_current_win(cur_win)
    end
end

function M.toggle_output_window()
    if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
        vim.api.nvim_win_close(State.win.output, true)
        State.win.output = nil
        return
    end
    M.open_output_window()
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

    -- Wipe stale buffer to avoid name conflict
    local existing = vim.fn.bufnr("JovianVariables")
    if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
    end

    State.buf.variables = create_variables_buf()
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
