local M = {}
local Config = require("jovian.config")
local State = require("jovian.state")

function M.send_notification(msg)
    if vim.fn.executable("notify-send") == 1 then
        vim.fn.jobstart({"notify-send", "Jovian Task Finished", msg}, {detach=true})
    elseif vim.fn.executable("osascript") == 1 then
        vim.fn.jobstart({"osascript", "-e", 'display notification "'..msg..'" with title "Jovian"'}, {detach=true})
    else
        vim.notify(msg, vim.log.levels.INFO)
    end
end

function M.get_or_create_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then return existing end
    
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    
    -- Open as terminal mode here and save channel ID
    State.term_chan = vim.api.nvim_open_term(buf, {})
    
    return buf
end

function M.append_to_repl(text, hl_group)
    if not State.term_chan then return end
    
    local lines = type(text) == "table" and text or vim.split(text, "\n")
    local output = ""
    
    -- ANSI Color Code Definitions
    local RESET = "\x1b[0m"
    local BOLD  = "\x1b[1m"
    local GREEN = "\x1b[32m"
    local BLUE  = "\x1b[34m"
    local CYAN  = "\x1b[36m"
    local YELLOW = "\x1b[33m"
    local GREY  = "\x1b[90m"
    
    local color_start = ""
    local color_end = RESET
    
    if hl_group == "Type" then
        -- Prompt (In [abc]:) -> Green & Bold
        color_start = GREEN .. BOLD
        
        -- Tip: Insert a faint separator line before the prompt
        -- This makes the boundary with previous results clear
        output = output .. GREY .. string.rep("─", 40) .. RESET .. "\r\n"
        
    elseif hl_group == nil then
        -- Code body (no hl_group) -> Cyan (Distinguishable!)
        color_start = CYAN
        
    elseif hl_group == "Special" then
        -- Image save notification etc. -> Blue
        color_start = BLUE
    elseif hl_group == "WarningMsg" then
        -- Warning -> Yellow
        color_start = YELLOW
    elseif hl_group == "Comment" then
        -- Completion notification etc. -> Grey
        color_start = GREY
    end

    for _, line in ipairs(lines) do
        output = output .. color_start .. line .. color_end .. "\r\n"
    end
    
    -- Send to terminal
    vim.api.nvim_chan_send(State.term_chan, output)
    
    -- Auto-scroll
    if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
        local buf = State.buf.output
        local count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_win_set_cursor(State.win.output, {count, 0})
    end
end

-- Fix: Stream output (Simplified)
function M.append_stream_text(text, stream_type)
    if not State.term_chan then return end
    
    -- nvim_open_term handles \r and \n automatically,
    -- so just send it as is!
    
    -- However, converting Unix newline (\n) to terminal newline (\r\n) prevents display issues
    -- (IPython often sends \r\n already, but just in case)
    local clean_text = text:gsub("\n", "\r\n")
    
    -- Red for stderr
    if stream_type == "stderr" then
        local RED = "\x1b[31m"
        local RESET = "\x1b[0m"
        clean_text = RED .. clean_text .. RESET
    end
    
    vim.api.nvim_chan_send(State.term_chan, clean_text)
    
    if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
        local buf = State.buf.output
        local count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_win_set_cursor(State.win.output, {count, 0})
    end
end

function M.flash_range(start_line, end_line)
    vim.api.nvim_buf_clear_namespace(0, State.hl_ns, 0, -1)
    vim.api.nvim_buf_set_extmark(0, State.hl_ns, start_line - 1, 0, {
        end_row = end_line, hl_group = Config.options.flash_highlight_group, hl_eol = true, priority = 200,
    })
    vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(0) then vim.api.nvim_buf_clear_namespace(0, State.hl_ns, 0, -1) end
    end, Config.options.flash_duration)
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
             M.append_to_repl("[Jovian Console Ready]", "Special")
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
end

function M.close_windows()
    if State.win.preview and vim.api.nvim_win_is_valid(State.win.preview) then vim.api.nvim_win_close(State.win.preview, true) end
    if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then vim.api.nvim_win_close(State.win.output, true) end
    State.win.preview, State.win.output = nil, nil
    State.current_preview_file = nil
end

function M.toggle_windows()
    -- Fix: Reliably capture the window ID (code window) before execution
    local cur_win = vim.api.nvim_get_current_win()

    if (State.win.preview and vim.api.nvim_win_is_valid(State.win.preview)) or 
       (State.win.output and vim.api.nvim_win_is_valid(State.win.output)) then
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
    if not (State.win.preview and vim.api.nvim_win_is_valid(State.win.preview)) then return end
    local abs_filepath = vim.fn.fnamemodify(filepath, ":p")
    local file_dir = vim.fn.fnamemodify(abs_filepath, ":h")
    State.current_preview_file = abs_filepath
    local cur_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(State.win.preview)
    vim.cmd("lcd " .. file_dir)
    vim.cmd("edit! " .. abs_filepath)
    vim.bo.filetype = "markdown"
    vim.bo.buftype = "" 
    vim.wo.wrap = true
    vim.schedule(function()
        if vim.api.nvim_win_is_valid(cur_win) then vim.api.nvim_set_current_win(cur_win) end
    end)
end

function M.set_cell_status(bufnr, cell_id, status, msg)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
        if line:find('id="' .. cell_id .. '"', 1, true) then
            local hl_group = "Comment"
            if status == "running" then hl_group = "WarningMsg"
            elseif status == "done" then hl_group = "String"
            elseif status == "error" then hl_group = "ErrorMsg" end
            
            vim.api.nvim_buf_clear_namespace(bufnr, State.status_ns, i - 1, i)
            vim.api.nvim_buf_set_extmark(bufnr, State.status_ns, i - 1, 0, {
                virt_text = {{ "  " .. msg, hl_group }},
                virt_text_pos = "eol",
            })
            return
        end
    end
end

function M.show_variables(vars)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

    local SEPARATOR = " │ " 
    local PADDING = 1
    
    -- 1. Calculate column widths (default min widths)
    local max_name_w = 4 -- Length of "NAME"
    local max_type_w = 4 -- Length of "TYPE"
    
    for _, v in ipairs(vars) do
        max_name_w = math.max(max_name_w, vim.fn.strdisplaywidth(v.name))
        max_type_w = math.max(max_type_w, vim.fn.strdisplaywidth(v.type))
    end

    -- Padding function
    local function pad_str(s, w) 
        local vis_w = vim.fn.strdisplaywidth(s)
        return string.rep(" ", PADDING) .. s .. string.rep(" ", w - vis_w + PADDING)
    end

    local fmt_lines = {}
    
    -- Create header
    local header = pad_str("NAME", max_name_w) .. SEPARATOR ..
                   pad_str("TYPE", max_type_w) .. SEPARATOR ..
                   pad_str("VALUE/INFO", 10)
    
    table.insert(fmt_lines, header)
    
    -- Create separator line
    local sep_len_name = max_name_w + (PADDING * 2)
    local sep_len_type = max_type_w + (PADDING * 2)
    local sep_line = string.rep("─", sep_len_name) .. "─┼─" ..
                     string.rep("─", sep_len_type) .. "─┼─" ..
                     string.rep("─", 100) 
    
    table.insert(fmt_lines, sep_line)

    -- Create data lines
    if #vars == 0 then
        -- Empty state: Show message in the VALUE/INFO column
        local line = pad_str("", max_name_w) .. SEPARATOR ..
                     pad_str("", max_type_w) .. SEPARATOR ..
                     " (No variables defined)"
        table.insert(fmt_lines, line)
    else
        for _, v in ipairs(vars) do
            local line = pad_str(v.name, max_name_w) .. SEPARATOR ..
                         pad_str(v.type, max_type_w) .. SEPARATOR ..
                         " " .. v.info 
            table.insert(fmt_lines, line)
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, fmt_lines)

    -- Highlight
    vim.api.nvim_buf_add_highlight(buf, -1, "Title", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, -1, "Comment", 1, 0, -1)
    
    local col1_end = sep_len_name
    local col2_end = col1_end + 3 + sep_len_type
    
    for i = 2, #fmt_lines - 1 do
        if #vars > 0 then
            vim.api.nvim_buf_add_highlight(buf, -1, "Function", i, 0, col1_end)
            vim.api.nvim_buf_add_highlight(buf, -1, "Type", i, col1_end + 3, col2_end)
            vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i, col1_end, col1_end + 3)
            vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i, col2_end, col2_end + 3)
        else
             -- Empty state highlight (Message in Comment color)
             vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i, col1_end, col1_end + 3)
             vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i, col2_end, col2_end + 3)
             vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i, col2_end + 3, -1)
        end
    end

    -- Window settings
    local editor_width = vim.o.columns
    local content_width = 0
    for _, line in ipairs(fmt_lines) do
        content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
    end
    
    local width = math.min(content_width + 4, math.floor(editor_width * 0.9))
    local height = math.min(#fmt_lines + 2, math.floor(vim.o.lines * 0.8))
    
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor", width = width, height = height, row = row, col = col,
        style = "minimal", border = Config.options.float_border, title = " Variables ", title_pos = "center"
    })
    
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    
    local opts = { noremap = true, silent = true }
    vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
    vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

-- Add: Show profiling results
function M.show_profile_stats(text)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
    
    local lines = vim.split(text, "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.8)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor", width = width, height = height, row = row, col = col,
        style = "minimal", border = Config.options.float_border, title = " cProfile Stats ", title_pos = "center"
    })
    local opts = { noremap = true, silent = true }
    vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
    vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

function M.show_dataframe(data)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
    local SEPARATOR = " │ " 
    local PADDING = 1
    
    local headers = { "" } 
    for _, c in ipairs(data.columns) do table.insert(headers, tostring(c)) end
    
    local col_widths = {}
    for i, h in ipairs(headers) do col_widths[i] = vim.fn.strdisplaywidth(h) end

    for i, row in ipairs(data.data) do
        local idx = tostring(data.index[i])
        col_widths[1] = math.max(col_widths[1], vim.fn.strdisplaywidth(idx))
        for j, val in ipairs(row) do
            local s = tostring(val)
            col_widths[j+1] = math.max(col_widths[j+1] or 0, vim.fn.strdisplaywidth(s))
        end
    end

    local function pad_str(s, w) 
        local vis_w = vim.fn.strdisplaywidth(s)
        return string.rep(" ", PADDING) .. s .. string.rep(" ", w - vis_w + PADDING)
    end

    local fmt_lines = {}
    local header_line = ""
    for i, h in ipairs(headers) do 
        header_line = header_line .. pad_str(h, col_widths[i]) .. (i < #headers and SEPARATOR or "")
    end
    table.insert(fmt_lines, header_line)

    local sep_line = ""
    for i, w in ipairs(col_widths) do
        local total_w = w + (PADDING * 2)
        sep_line = sep_line .. string.rep("─", total_w) .. (i < #headers and "─┼─" or "")
    end
    table.insert(fmt_lines, sep_line)

    for i, row in ipairs(data.data) do
        local line_str = pad_str(tostring(data.index[i]), col_widths[1]) .. SEPARATOR
        for j, val in ipairs(row) do
            line_str = line_str .. pad_str(tostring(val), col_widths[j+1]) .. (j < #row and SEPARATOR or "")
        end
        table.insert(fmt_lines, line_str)
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, fmt_lines)
    vim.api.nvim_buf_add_highlight(buf, -1, "Title", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, -1, "Comment", 1, 0, -1)
    
    local index_col_width = col_widths[1] + (PADDING * 2) 
    for i = 2, #fmt_lines - 1 do
        vim.api.nvim_buf_add_highlight(buf, -1, "Statement", i, 0, index_col_width)
        local current_pos = 0
        for j, w in ipairs(col_widths) do
            current_pos = current_pos + w + (PADDING * 2)
            if j < #col_widths then
                vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i, current_pos, current_pos + #SEPARATOR)
                current_pos = current_pos + #SEPARATOR
            end
        end
    end

    local width = math.floor(vim.o.columns * 0.85)
    local height = math.floor(vim.o.lines * 0.7)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor", width = width, height = height, row = row, col = col,
        style = "minimal", border = Config.options.float_border, title = " " .. data.name .. " ", title_pos = "center"
    })
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    local opts = { noremap = true, silent = true }
    vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
    vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

function M.show_inspection(data)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(buf, 'filetype', 'python') -- For syntax highlighting

    local lines = {}
    local type_str = (data.type and data.type ~= vim.NIL) and data.type or "unknown"
    table.insert(lines, "# " .. data.name .. " (" .. type_str .. ")")
    table.insert(lines, "")
    
    if data.definition and data.definition ~= vim.NIL and data.definition ~= "" then
        table.insert(lines, "## Definition:")
        table.insert(lines, data.definition)
        table.insert(lines, "")
    end
    
    if data.docstring and data.docstring ~= vim.NIL then
        table.insert(lines, "## Docstring:")
        -- Split docstring into lines and add
        for _, l in ipairs(vim.split(data.docstring, "\n")) do
            table.insert(lines, l)
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- Large window
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.8)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor", width = width, height = height, row = row, col = col,
        style = "minimal", border = Config.options.float_border, title = " Jovian Doc ", title_pos = "center"
    })
    
    local opts = { noremap = true, silent = true }
    vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
    vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
    vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
    vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

function M.show_peek(data)
    if data.error then return vim.notify(data.error, vim.log.levels.WARN) end
    
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
    
    local lines = {}
    table.insert(lines, "Name:  " .. data.name)
    table.insert(lines, "Type:  " .. data.type)
    table.insert(lines, "Size:  " .. data.size)
    if data.shape and data.shape ~= "" then
        table.insert(lines, "Shape: " .. data.shape)
    end
    table.insert(lines, "")
    table.insert(lines, "Value:")
    for _, l in ipairs(vim.split(data.repr, "\n")) do
        table.insert(lines, l)
    end
    
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    
    -- Calculate size
    local width = 0
    for _, l in ipairs(lines) do if #l > width then width = #l end end
    width = math.min(width + 4, 80)
    local height = math.min(#lines + 2, 20)
    
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor", width = width, height = height, row = 1, col = 0,
        style = "minimal", border = Config.options.float_border, title = " Jovian Peek ", title_pos = "center"
    })
    
    local opts = { noremap = true, silent = true }
    vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
    vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

function M.clear_repl()
    if State.buf.output and vim.api.nvim_buf_is_valid(State.buf.output) then
        -- Terminal buffer cannot be cleared with set_lines,
        -- so recreate the buffer (forcefully)
        vim.api.nvim_buf_delete(State.buf.output, { force = true })
        State.buf.output = nil
        State.term_chan = nil
        
        -- Redraw (if window is open)
        if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
            State.buf.output = M.get_or_create_buf("JovianConsole")
            vim.api.nvim_win_set_buf(State.win.output, State.buf.output)
            M.append_to_repl("[Jovian Console Cleared]", "Comment")
        end
    end
end

-- Add: Clear diagnostics
function M.clear_diagnostics()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.diagnostic.reset(State.diag_ns, bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, State.diag_ns, 0, -1)
    vim.notify("Jovian diagnostics cleared", vim.log.levels.INFO)
end

return M
