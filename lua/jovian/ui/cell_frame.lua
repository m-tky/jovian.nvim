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

-- See markdown_cell.apply_hl for the value contract. We replicate the
-- helper here to keep ui/cell_frame.lua independent of ui/markdown_cell.lua.
local function apply_hl(target, user_val, fallback)
    local val = user_val
    if val == nil then val = fallback end
    if val == nil then return end
    if type(val) == "string" then
        vim.api.nvim_set_hl(0, target, { link = val, force = true })
    elseif type(val) == "table" then
        local attrs = vim.deepcopy(val)
        attrs.force = true
        vim.api.nvim_set_hl(0, target, attrs)
    end
end

local function set_default_hl()
    local user_hl = (Config.options.highlights) or {}
    -- Both default to Comment so the entire frame reads as one continuous
    -- subdued outline. Users who want the label text inside the top border
    -- to stand out set `highlights.cell_header = "Function"` (or any other
    -- group / attrs table) in setup().
    apply_hl(HL_BORDER, user_hl.cell_border, "Comment")
    apply_hl(HL_HEADER, user_hl.cell_header, "Comment")
end

local function dw(s)
    return vim.fn.strdisplaywidth(s)
end

local function repeat_dash(n)
    if n <= 0 then return "" end
    return string.rep("─", n)
end

-- Build the top border as a virt_text chunk list, so we can colour the
-- frame dashes with HL_BORDER and the label text with HL_HEADER. The two
-- groups default to the same colour (Comment) for a uniform frame; users
-- who want the label to pop set `highlights.cell_header = "Function"` or
-- similar in setup().
local function top_border_chunks(width, label)
    local prefix = "┌─ "
    local label_text = label .. " "
    local prefix_w = dw(prefix)
    local label_w = dw(label_text)
    local pad = width - prefix_w - label_w - 1 -- 1 for the closing "┐"
    local suffix = repeat_dash(math.max(pad, 0)) .. "┐"
    return {
        { prefix, HL_BORDER },
        { label_text, HL_HEADER },
        { suffix, HL_BORDER },
    }
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
    -- `textoff` is the authoritative answer for "how many columns are
    -- consumed by the gutter (signcolumn + foldcolumn + number column,
    -- including its auto-growth based on buffer line count)". Computing
    -- this from individual options misses the auto-growth case.
    local info = vim.fn.getwininfo(winid)[1] or {}
    local textoff = info.textoff or 0
    local w = total - textoff
    if w < 20 then w = 20 end
    -- No upper cap: the right_align side bar lives at the actual text-area
    -- edge, so the top/bottom dashes must reach there too — otherwise
    -- the frame looks like ┌──── ─┐  │  with a visible gap on wide windows.
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
            virt_text = top_border_chunks(width, label),
            virt_text_pos = "overlay",
            hl_mode = "combine",
            priority = 199,
        })

        -- 3. Left + right bars on each source line of the cell.
        --    `virt_text_repeat_linebreak = true` keeps the bars visible on
        --    every wrapped continuation row (Neovim 0.10+). On older
        --    versions the option is silently ignored.
        for ln = h.line + 1, last_src do
            pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, ln, 0, {
                virt_text = { { "│ ", HL_BORDER } },
                virt_text_pos = "inline",
                virt_text_repeat_linebreak = true,
                hl_mode = "combine",
                priority = 100,
            })
            pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, ln, 0, {
                virt_text = { { "│", HL_BORDER } },
                virt_text_pos = "right_align",
                virt_text_repeat_linebreak = true,
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

-- Trailing debounce: each schedule call resets a 60 ms timer per buffer.
-- The render fires once, after the last event in a burst. The previous
-- LEADING-edge guard (`_pending = true`, ignore subsequent calls) meant a
-- fast resize drag rendered at an intermediate width and then dropped
-- events; trailing-edge fires at the FINAL width.
local uv = vim.uv or vim.loop
local _timers = {}
function M.schedule(bufnr, winid)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local t = _timers[bufnr]
    if t then
        t:stop()
    else
        t = uv.new_timer()
        _timers[bufnr] = t
    end
    t:start(60, 0, vim.schedule_wrap(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
            if _timers[bufnr] then
                _timers[bufnr]:close()
                _timers[bufnr] = nil
            end
            return
        end
        -- Resolve the winid AT FIRE TIME, not at schedule time. After a
        -- resize the window's textoff/width can shift; using the live
        -- winid means we render against the final geometry.
        local w = winid
        if not w or not vim.api.nvim_win_is_valid(w) then
            local wins = vim.fn.win_findbuf(bufnr)
            w = wins[1] or vim.api.nvim_get_current_win()
        end
        M.render(bufnr, w)
        if _timers[bufnr] then
            _timers[bufnr]:close()
            _timers[bufnr] = nil
        end
    end))
end

-- Public for tests.
M._parse_cells = parse_cells
M._namespace = NS
M._top_border_chunks = top_border_chunks
M._bottom_border = bottom_border

return M
