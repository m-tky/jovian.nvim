local M = {}

---@class JovianCell
---@field title string
---@field start_line number
---@field end_line number
---@field text string

---Parse the current buffer to find cells
---@return JovianCell[]
local function get_cells()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local cells = {}
    local current_cell = nil

    for i, line in ipairs(lines) do
        if line:match("^# %%%%") then
            if current_cell then
                current_cell.end_line = i - 1
                table.insert(cells, current_cell)
            end
            
            local title = line:match("^# %%%% (.*)")
            if title then
                -- Strip id="..."
                title = title:gsub('id="[^"]*"', ""):gsub("id='[^']*'", "")
                -- Strip [markdown]
                title = title:gsub("%[markdown%]", "")
                -- Trim whitespace
                title = title:match("^%s*(.-)%s*$")
                if title == "" then title = nil end
            end
            current_cell = {
                title = title, -- can be nil or empty
                start_line = i,
                text = line
            }
        elseif current_cell then
            -- Capture first non-empty line as part of text/description if needed
            if current_cell.text == line and line ~= "" then
                current_cell.text = current_cell.text .. " " .. line
            end
        end
    end

    if current_cell then
        current_cell.end_line = #lines
        table.insert(cells, current_cell)
    end

    return cells
end

---Open Snacks picker for cells
function M.cells()
    local snacks_ok, Snacks = pcall(require, "snacks")
    if not snacks_ok then
        vim.notify("Snacks.nvim is not installed. Please install 'folke/snacks.nvim' to use this feature.", vim.log.levels.ERROR)
        return
    end

    local cells = get_cells()
    local current_file = vim.api.nvim_buf_get_name(0)
    
    local items = {}
    for i, cell in ipairs(cells) do
        local display_title = cell.title
        if not display_title or display_title == "" then
            display_title = "Cell " .. i
        end

        -- Add the cell header itself as an item
        table.insert(items, {
            text = display_title,
            pos = { cell.start_line, 0 },
            file = current_file,
            type = "header",
            cell_title = display_title
        })

        -- Add each line of the cell as an item
        local cell_lines = vim.api.nvim_buf_get_lines(0, cell.start_line, cell.end_line, false)
        for offset, line in ipairs(cell_lines) do
            if not line:match("^# %%%%") and line ~= "" then
                -- Strip leading whitespace for cleaner display, but keep original for context if needed?
                -- For grep, usually we show the line as is.
                table.insert(items, {
                    text = line,
                    pos = { cell.start_line + offset - 1, 0 },
                    file = current_file,
                    type = "code",
                    cell_title = display_title
                })
            end
        end
    end

    Snacks.picker.pick({
        source = "jovian_cells",
        items = items,
        format = function(item, picker)
            local ret = {}
            -- Icon
            if item.type == "header" then
                table.insert(ret, { " ", "SnacksPickerIcon" })
                table.insert(ret, { item.text, "SnacksPickerLabel" })
            else
                table.insert(ret, { "  ", "SnacksPickerIcon" }) -- Indent code
                table.insert(ret, { item.text, "Normal" })
                -- Optional: Show cell title faintly at the end if searching? 
                -- For now, keep it clean as requested.
            end
            return ret
        end,
        title = "Jovian Cells",
        layout = {
            preview = true,
        },
        actions = {
            confirm = function(picker, item)
                picker:close()
                if item then
                    vim.api.nvim_win_set_cursor(0, { item.pos[1], item.pos[2] })
                    vim.cmd("normal! zz") -- Center
                end
            end
        }
    })
end

return M
