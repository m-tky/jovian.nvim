-- Render a markdown table block in place, render-markdown.nvim style: each
-- source `| … |` row stays a real, cursor-navigable buffer line, its raw text
-- concealed and overlaid with the rendered row; the top/bottom borders are the
-- only added (virtual) lines. Columns are padded to their max DISPLAY width
-- (CJK-aware), so one row never affects another's height — a wide table simply
-- gets wide (scroll horizontally), exactly like render-markdown.
--
-- Border glyphs / alignment indicator match render-markdown's presets. (No
-- `<br>` multi-line or window-fit wrapping — that's render-markdown's behavior.)

local M = {}

local Highlights = require("jovian.ui.highlights")
local CellFrame = require("jovian.ui.cell_frame")

local HL_DIVIDER = "JovianMdTableDivider"
local HL_HEADER = "JovianMdTableHeader"
local HL_BODY = "Normal"

local dw = Highlights.dw

-- Split a row into trimmed cell strings; optional leading/trailing `|`.
local function split_cells(content)
    local s = vim.trim(content):gsub("^|", ""):gsub("|$", "")
    local cells, start = {}, 1
    while true do
        local p = s:find("|", start, true)
        if not p then
            cells[#cells + 1] = vim.trim(s:sub(start))
            break
        end
        cells[#cells + 1] = vim.trim(s:sub(start, p - 1))
        start = p + 1
    end
    return cells
end

-- A separator row is only pipes / dashes / colons / spaces, with ≥1 dash.
local function is_sep(content)
    return content:find("-", 1, true) ~= nil and content:match("^[%s|:%-]+$") ~= nil
end

local function alignment_of(sep_cell)
    local left = sep_cell:match("^%s*:") ~= nil
    local right = sep_cell:match(":%s*$") ~= nil
    if left and right then
        return "center"
    elseif left then
        return "left"
    elseif right then
        return "right"
    end
    return "default"
end

-- Border glyph presets, matching render-markdown.nvim. Indices:
-- 1-3 top L/M/R, 4-6 delimiter L/M/R, 7-9 bottom L/M/R, 10 vertical,
-- 11 horizontal, 12 delimiter-row alignment indicator.
local BORDERS = {
    none = { "┌", "┬", "┐", "├", "┼", "┤", "└", "┴", "┘", "│", "─", "━" },
    round = { "╭", "┬", "╮", "├", "┼", "┤", "╰", "┴", "╯", "│", "─", "━" },
    double = { "╔", "╦", "╗", "╠", "╬", "╣", "╚", "╩", "╝", "║", "═", "━" },
    heavy = { "┏", "┳", "┓", "┣", "╋", "┫", "┗", "┻", "┛", "┃", "━", "─" },
}

-- One column's delimiter-row segment: fill with `h`, marking explicit
-- alignment with a single `ind` char (default alignment = no marker).
local function delim_seg(width, align, h, ind)
    if width < 3 or align == "default" then
        return string.rep(h, width)
    elseif align == "left" then
        return ind .. string.rep(h, width - 1)
    elseif align == "right" then
        return string.rep(h, width - 1) .. ind
    end -- center
    return ind .. string.rep(h, width - 2) .. ind
end

local function pad(s, width, align)
    local extra = width - dw(s)
    if extra <= 0 then
        return s
    end
    if align == "right" then
        return string.rep(" ", extra) .. s
    elseif align == "center" then
        local l = math.floor(extra / 2)
        return string.rep(" ", l) .. s .. string.rep(" ", extra - l)
    end
    return s .. string.rep(" ", extra) -- left / default
end

-- Render `block` (list of { ln, content, offset } source rows, already
-- `#`-stripped) in place. Returns true if rendered. `cursor_ln` (0-indexed, or
-- nil) is left raw — its conceal+overlay are skipped so editing that row shows
-- the source markdown instead of doubling under the rendered row (anti-conceal,
-- render-markdown.nvim style). The borders and other rows stay rendered.
function M.render(buf, ns, block, cursor_ln)
    if #block == 0 then
        return false
    end

    local rows, sep_idx, n_cols = {}, nil, 0
    for i, info in ipairs(block) do
        local sep = is_sep(info.content)
        rows[i] = { cells = split_cells(info.content), sep = sep }
        if sep then
            sep_idx = i
        end
        n_cols = math.max(n_cols, #rows[i].cells)
    end
    if n_cols == 0 then
        return false
    end

    local align = {}
    for c = 1, n_cols do
        align[c] = "default"
    end
    if sep_idx then
        for c, cell in ipairs(rows[sep_idx].cells) do
            align[c] = alignment_of(cell)
        end
    end

    -- Column widths = max display width per column (content rows only).
    local widths = {}
    for c = 1, n_cols do
        widths[c] = 1
    end
    for _, r in ipairs(rows) do
        if not r.sep then
            for c = 1, n_cols do
                widths[c] = math.max(widths[c], dw(r.cells[c] or ""))
            end
        end
    end

    local B = BORDERS[require("jovian.config").options.table_border] or BORDERS.round
    local function seg_line(left, mid, right, seg)
        local parts = { left }
        for c = 1, n_cols do
            parts[#parts + 1] = seg(c)
            parts[#parts + 1] = (c < n_cols) and mid or right
        end
        return table.concat(parts)
    end
    local function fill(c)
        return string.rep(B[11], widths[c] + 2)
    end

    local header_idx = sep_idx and (sep_idx - 1) or nil

    -- Overlay each source row in place: conceal the raw `| … |` and draw the
    -- rendered row as inline virt_text at the same column.
    for i, info in ipairs(block) do
        local r = rows[i]
        if info.ln == cursor_ln then
            goto continue -- anti-conceal: leave the cursor's row raw
        end
        local chunks
        if r.sep then
            local line = seg_line(B[4], B[5], B[6], function(c)
                return delim_seg(widths[c] + 2, align[c], B[11], B[12])
            end)
            chunks = { { line, HL_DIVIDER } }
        else
            local cell_hl = (i == header_idx) and HL_HEADER or HL_BODY
            chunks = { { B[10], HL_DIVIDER } }
            for c = 1, n_cols do
                chunks[#chunks + 1] = { " " .. pad(r.cells[c] or "", widths[c], align[c]) .. " ", cell_hl }
                chunks[#chunks + 1] = { B[10], HL_DIVIDER }
            end
        end
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, info.ln, info.offset, {
            end_col = info.offset + #info.content,
            conceal = "",
            priority = 200,
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, info.ln, info.offset, {
            virt_text = chunks,
            virt_text_pos = "inline",
            hl_mode = "combine",
            priority = 201,
        })
        ::continue::
    end

    -- Top + bottom borders as virtual lines around the block. When cell_frame
    -- is on, each source row carries inline `│ ` / right_align `│` bars (and
    -- the `#` prefix is concealed), but virtual lines don't inherit them, so
    -- wrap the border with `│ … │` padded to the frame's inner width — same
    -- trick output_render uses for inline Out[N] blocks.
    local border_line
    if require("jovian.config").options.cell_frame then
        local inner_w = CellFrame.inner_text_width(vim.api.nvim_get_current_win())
        border_line = function(s)
            return CellFrame.frame_wrap(s, HL_DIVIDER, inner_w, CellFrame.HL.BORDER_MARKDOWN)
        end
    else
        border_line = function(s)
            return { { s, HL_DIVIDER } }
        end
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, block[1].ln, 0, {
        virt_lines = { border_line(seg_line(B[1], B[2], B[3], fill)) },
        virt_lines_above = true,
        priority = 200,
    })
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, block[#block].ln, 0, {
        virt_lines = { border_line(seg_line(B[7], B[8], B[9], fill)) },
        priority = 200,
    })
    return true
end

return M
