-- jupynvim-style card frames for `# %%` cells, rendered entirely via
-- extmarks. The buffer text is never modified.
--
-- Visual layout per cell:
--   ┌─ Code [abc123] ────────────┐
--   │ print("hello")             │
--   │ x = 1                      │
--   └────────────────────────────┘
--
-- Implementation:
--   • `# %% id="..."` header lines are concealed AND overlaid with the top
--     border (overlay alone bleeds the source through on narrow windows;
--     conceal alone disappears entirely without a styled replacement).
--   • Each source line inside the cell gets two extmarks: an `inline`
--     left bar at col 0 and a `right_align` right bar.
--   • The last source line carries a `virt_lines` extmark for the bottom
--     border, so the next cell's header still lands at its real buffer row.
--
-- The render is debounced and gated on the `cell_frame` config flag.

local M = {}

local Config = require("jovian.config")

local NS = vim.api.nvim_create_namespace("JovianCellFrame")

local HL_BORDER = "JovianCellBorder"
local HL_HEADER = "JovianCellHeader"

-- Anything matching this is treated as a cell header line. Mirrors
-- cell.lua's regex (which uses Vim's pattern syntax; the Lua form is
-- equivalent for the leading marker only).
local HEADER_RE = "^#%s*%%%%"

local function set_default_hl()
    -- Use linked groups so colorschemes can override. We fall back to
    -- subdued blue/comment-y colors that look reasonable on dark themes
    -- without committing to a specific palette.
    if vim.fn.hlexists(HL_BORDER) == 0 then
        vim.api.nvim_set_hl(0, HL_BORDER, { link = "Comment", default = true })
    end
    if vim.fn.hlexists(HL_HEADER) == 0 then
        vim.api.nvim_set_hl(0, HL_HEADER, { link = "Function", default = true })
    end
end

local function dw(s)
    return vim.fn.strdisplaywidth(s)
end

local function repeat_dash(n)
    if n <= 0 then return "" end
    return string.rep("─", n)
end

local function top_border(width, label)
    local main = "┌─ " .. label .. " "
    local pad = width - dw(main) - 1
    return main .. repeat_dash(pad) .. "┐"
end

local function bottom_border(width)
    return "└" .. repeat_dash(math.max(width - 2, 0)) .. "┘"
end

local function parse_header(line)
    -- Returns (cell_type, id) or nil if not a header line.
    if not line:match(HEADER_RE) then return nil end
    local lower = line:lower()
    local kind = "Code"
    if lower:find("%[markdown%]", 1, false) or lower:find("%[md%]", 1, false) then
        kind = "Markdown"
    elseif lower:find("%[raw%]", 1, false) then
        kind = "Raw"
    end
    local id = line:match('id="([%w%-_]+)"')
    return kind, id
end

local function parse_cells(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local headers = {}
    for i, line in ipairs(lines) do
        local kind, id = parse_header(line)
        if kind then
            table.insert(headers, {
                line = i - 1, -- 0-based
                kind = kind,
                id = id,
                raw_len = #line,
            })
        end
    end
    return headers, #lines
end

local function text_area_width(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return 80
    end
    local total = vim.api.nvim_win_get_width(winid)
    -- signcolumn / numbercolumn / foldcolumn reduce the text area. We
    -- under-estimate slightly (capping at 100) because right_align extmarks
    -- already adapt to the actual edge; the dashes in the top/bottom
    -- borders just need to be wide enough that they don't look stubby.
    local nu_w = 0
    if vim.api.nvim_get_option_value("number", { win = winid })
        or vim.api.nvim_get_option_value("relativenumber", { win = winid })
    then
        nu_w = vim.api.nvim_get_option_value("numberwidth", { win = winid })
    end
    local sc = vim.api.nvim_get_option_value("signcolumn", { win = winid })
    local sc_w = (sc == "no" or sc == "") and 0 or 2
    local fc_raw = vim.api.nvim_get_option_value("foldcolumn", { win = winid })
    local fc_w = tonumber(fc_raw) or 0
    local w = total - nu_w - sc_w - fc_w
    if w < 20 then w = 20 end
    if w > 100 then w = 100 end
    return w
end

-- Render all cell frames in `bufnr` against the given window's text width.
-- Safe to call on every TextChanged; the whole namespace is wiped first.
function M.render(bufnr, winid)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    winid = winid or vim.api.nvim_get_current_win()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    set_default_hl()

    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

    if not Config.options.cell_frame then return end

    local headers, total = parse_cells(bufnr)
    if #headers == 0 then return end

    local width = text_area_width(winid)

    for idx, h in ipairs(headers) do
        local next_line = headers[idx + 1] and headers[idx + 1].line or total
        local last_src = next_line - 1
        if last_src < h.line then last_src = h.line end

        local label = h.kind
        if h.id then
            -- Truncate IDs to keep the header tidy; full id stays in source
            label = label .. " [" .. h.id:sub(1, 8) .. "]"
        end

        -- 1. Conceal the header source chars. The plain-conceal approach
        --    (without a virt_text overlay below) hides the line entirely
        --    when conceallevel >= 1; pair it with the overlay so the line
        --    visually becomes the top border at any conceallevel.
        if h.raw_len > 0 then
            vim.api.nvim_buf_set_extmark(bufnr, NS, h.line, 0, {
                end_col = h.raw_len,
                conceal = "",
                priority = 200,
            })
        end

        -- 2. Top border overlay at col 0. virt_text_pos="overlay" replaces
        --    the underlying chars visually; conceal handles any tail that
        --    sticks out past the overlay (rare unless the source header is
        --    longer than the window).
        vim.api.nvim_buf_set_extmark(bufnr, NS, h.line, 0, {
            virt_text = { { top_border(width, label), HL_HEADER } },
            virt_text_pos = "overlay",
            hl_mode = "combine",
            priority = 199,
        })

        -- 3. Left + right bars on each source line of the cell.
        for ln = h.line + 1, last_src do
            vim.api.nvim_buf_set_extmark(bufnr, NS, ln, 0, {
                virt_text = { { "│ ", HL_BORDER } },
                virt_text_pos = "inline",
                hl_mode = "combine",
                priority = 100,
            })
            vim.api.nvim_buf_set_extmark(bufnr, NS, ln, 0, {
                virt_text = { { "│", HL_BORDER } },
                virt_text_pos = "right_align",
                hl_mode = "combine",
                priority = 100,
            })
        end

        -- 4. Bottom border on the last source line via virt_lines.
        vim.api.nvim_buf_set_extmark(bufnr, NS, last_src, 0, {
            virt_lines = { { { bottom_border(width), HL_BORDER } } },
        })
    end
end

function M.clear(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    end
end

-- Debounced refresh: rate-limit re-render to ~16fps under heavy typing.
local _pending = {}
function M.schedule(bufnr, winid)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if _pending[bufnr] then return end
    _pending[bufnr] = true
    vim.defer_fn(function()
        _pending[bufnr] = nil
        if vim.api.nvim_buf_is_valid(bufnr) then
            local w = winid
            if not w or not vim.api.nvim_win_is_valid(w) then
                local wins = vim.fn.win_findbuf(bufnr)
                w = wins[1] or vim.api.nvim_get_current_win()
            end
            M.render(bufnr, w)
        end
    end, 60)
end

-- Public for tests.
M._parse_cells = parse_cells
M._namespace = NS
M._top_border = top_border
M._bottom_border = bottom_border

return M
