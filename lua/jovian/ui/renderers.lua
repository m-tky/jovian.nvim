local M = {}
local State = require("jovian.state")
local Windows = require("jovian.ui.windows")

local function get_var_column_widths(vars)
    local max_name_w = 4
    local max_type_w = 4
    for _, v in ipairs(vars) do
        max_name_w = math.max(max_name_w, vim.fn.strdisplaywidth(v.name))
        max_type_w = math.max(max_type_w, vim.fn.strdisplaywidth(v.type))
    end
    return max_name_w, max_type_w
end

local function pad_str(s, w, padding)
    local vis_w = vim.fn.strdisplaywidth(s)
    return string.rep(" ", padding) .. s .. string.rep(" ", w - vis_w + padding)
end

function M.render_variables_pane(vars)
    if not (State.buf.variables and vim.api.nvim_buf_is_valid(State.buf.variables)) then
        return
    end
    local buf = State.buf.variables

    local SEPARATOR = " "
    local PADDING = 1

    local max_name_w, max_type_w = get_var_column_widths(vars)

    local fmt_lines = {}

    -- Header
    local header = pad_str("NAME", max_name_w, PADDING)
        .. SEPARATOR
        .. pad_str("TYPE", max_type_w, PADDING)
        .. SEPARATOR
        .. " VALUE"
    table.insert(fmt_lines, header)

    -- Create separator line
    local sep_len_name = max_name_w + (PADDING * 2)
    local sep_len_type = max_type_w + (PADDING * 2)
    local sep_line = string.rep("─", sep_len_name)
        .. "─"
        .. string.rep("─", sep_len_type)
        .. "─"
        .. string.rep("─", 50)

    table.insert(fmt_lines, sep_line)

    if #vars == 0 then
        table.insert(fmt_lines, State.job_id and "(No variables defined)" or "(Kernel not started)")
    else
        for _, v in ipairs(vars) do
            local line = pad_str(v.name, max_name_w, PADDING)
                .. SEPARATOR
                .. pad_str(v.type, max_type_w, PADDING)
                .. SEPARATOR
                .. " "
                .. (v.info or "")
            table.insert(fmt_lines, line)
        end
    end

    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, fmt_lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    -- Highlighting
    vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, -1, "JovianHeader", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", 1, 0, -1)

    local col1_end = sep_len_name
    local col2_end = col1_end + #SEPARATOR + sep_len_type

    for i = 2, #fmt_lines - 1 do
        if #vars > 0 then
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianVariable", i, 0, col1_end)
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianType", i, col1_end + #SEPARATOR, col2_end)
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col1_end, col1_end + #SEPARATOR)
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col2_end, col2_end + #SEPARATOR)
        end
    end
end

function M.show_variables(vars, force_float)
    if State.win.variables and vim.api.nvim_win_is_valid(State.win.variables) then
        M.render_variables_pane(vars)
        if not force_float then
            return
        end
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"

    local SEPARATOR = " │ "
    local PADDING = 1

    local max_name_w, max_type_w = get_var_column_widths(vars)

    local fmt_lines = {}
    local header = pad_str("NAME", max_name_w, PADDING)
        .. SEPARATOR
        .. pad_str("TYPE", max_type_w, PADDING)
        .. SEPARATOR
        .. pad_str("VALUE/INFO", 10, PADDING)
    table.insert(fmt_lines, header)

    local max_info_w = 10
    for _, v in ipairs(vars) do
        max_info_w = math.max(max_info_w, vim.fn.strdisplaywidth(v.info))
    end

    local sep_len_name = max_name_w + (PADDING * 2)
    local sep_len_type = max_type_w + (PADDING * 2)
    local sep_len_info = max_info_w + (PADDING * 2)

    local sep_line = string.rep("─", sep_len_name)
        .. "─┼─"
        .. string.rep("─", sep_len_type)
        .. "─┼─"
        .. string.rep("─", sep_len_info)
    table.insert(fmt_lines, sep_line)

    if #vars == 0 then
        local msg = State.job_id and "(No variables defined)" or "(Kernel not started)"
        local line = pad_str("", max_name_w, PADDING)
            .. SEPARATOR
            .. pad_str("", max_type_w, PADDING)
            .. SEPARATOR
            .. " "
            .. msg
        table.insert(fmt_lines, line)
    else
        for _, v in ipairs(vars) do
            local line = pad_str(v.name, max_name_w, PADDING)
                .. SEPARATOR
                .. pad_str(v.type, max_type_w, PADDING)
                .. SEPARATOR
                .. " "
                .. (v.info or "")
            table.insert(fmt_lines, line)
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, fmt_lines)

    -- Highlight
    vim.api.nvim_buf_add_highlight(buf, -1, "JovianHeader", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", 1, 0, -1)

    local col1_end = sep_len_name
    local col2_end = col1_end + 3 + sep_len_type

    for i = 2, #fmt_lines - 1 do
        if #vars > 0 then
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianVariable", i, 0, col1_end)
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianType", i, col1_end + 3, col2_end)
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col1_end, col1_end + 3)
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col2_end, col2_end + 3)
        else
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col1_end, col1_end + 3)
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col2_end, col2_end + 3)
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianComment", i, col2_end + 3, -1)
        end
    end

    local content_width = 0
    for _, line in ipairs(fmt_lines) do
        content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
    end

    local win = Windows.create_float_window(buf, "Jovian Variables", {
        width = math.min(content_width, math.floor(vim.o.columns * 0.9)),
        height = math.min(#fmt_lines, math.floor(vim.o.lines * 0.8)),
    })
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
end

function M.show_profile_stats(text)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local lines = vim.split(text, "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    Windows.create_float_window(buf, "cProfile Stats", {
        width = math.floor(vim.o.columns * 0.8),
        height = math.floor(vim.o.lines * 0.8),
    })
end

function M.show_dataframe(data)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local SEPARATOR = " │ "
    local PADDING = 1

    local headers = { "" }
    for _, c in ipairs(data.columns) do
        table.insert(headers, tostring(c))
    end

    local col_widths = {}
    for i, h in ipairs(headers) do
        col_widths[i] = vim.fn.strdisplaywidth(h)
    end

    for i, row in ipairs(data.data) do
        col_widths[1] = math.max(col_widths[1], vim.fn.strdisplaywidth(tostring(data.index[i])))
        for j, val in ipairs(row) do
            col_widths[j + 1] = math.max(col_widths[j + 1] or 0, vim.fn.strdisplaywidth(tostring(val)))
        end
    end

    local fmt_lines = {}
    local header_line = ""
    for i, h in ipairs(headers) do
        header_line = header_line .. pad_str(h, col_widths[i], PADDING) .. (i < #headers and SEPARATOR or "")
    end
    table.insert(fmt_lines, header_line)

    local sep_line = ""
    for i, w in ipairs(col_widths) do
        sep_line = sep_line .. string.rep("─", w + (PADDING * 2)) .. (i < #headers and "─┼─" or "")
    end
    table.insert(fmt_lines, sep_line)

    for i, row in ipairs(data.data) do
        local line_str = pad_str(tostring(data.index[i]), col_widths[1], PADDING) .. SEPARATOR
        for j, val in ipairs(row) do
            line_str = line_str .. pad_str(tostring(val), col_widths[j + 1], PADDING) .. (j < #row and SEPARATOR or "")
        end
        table.insert(fmt_lines, line_str)
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, fmt_lines)
    vim.api.nvim_buf_add_highlight(buf, -1, "JovianHeader", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", 1, 0, -1)

    local index_col_width = col_widths[1] + (PADDING * 2)
    for i = 2, #fmt_lines - 1 do
        vim.api.nvim_buf_add_highlight(buf, -1, "JovianIndex", i, 0, index_col_width)
        local current_pos = index_col_width
        for j = 2, #col_widths do
            vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, current_pos, current_pos + #SEPARATOR)
            current_pos = current_pos + #SEPARATOR + col_widths[j] + (PADDING * 2)
        end
    end

    local content_width = 0
    for _, line in ipairs(fmt_lines) do
        content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
    end

    local win = Windows.create_float_window(buf, data.name, {
        width = math.min(content_width, math.floor(vim.o.columns * 0.9)),
        height = math.min(#fmt_lines, math.floor(vim.o.lines * 0.8)),
    })
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
end

function M.show_inspection(data)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "python"

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
        for _, l in ipairs(vim.split(data.docstring, "\n")) do
            table.insert(lines, l)
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local content_width = 0
    for _, l in ipairs(lines) do
        content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
    end

    Windows.create_float_window(buf, "Jovian Doc", {
        width = math.max(40, math.min(content_width + 4, math.floor(vim.o.columns * 0.8))),
        height = math.max(5, math.min(#lines + 2, math.floor(vim.o.lines * 0.8))),
    })
end

function M.show_peek(data)
    if data.error then
        return vim.notify(data.error, vim.log.levels.WARN)
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"

    local lines = {
        "Name:  " .. data.name,
        "Type:  " .. data.type,
        "Size:  " .. data.size,
    }
    if data.shape and data.shape ~= "" then
        table.insert(lines, "Shape: " .. data.shape)
    end
    table.insert(lines, "")
    table.insert(lines, "Value:")
    for _, l in ipairs(vim.split(data.repr, "\n")) do
        table.insert(lines, l)
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, #l)
    end

    Windows.create_float_window(buf, "Jovian Peek", {
        width = math.min(width + 4, 80),
        height = math.min(#lines + 2, 20),
        relative = "cursor",
        row = 1,
        col = 0,
    })
end

return M
