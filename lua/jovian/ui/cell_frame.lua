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
local Highlights = require("jovian.ui.highlights")
local Debounce = require("jovian.ui.debounce")

local dw = Highlights.dw

local NS = vim.api.nvim_create_namespace("JovianCellFrame")

-- Public highlight group names so other UI modules can reference them
-- without re-typing the string literal (which would silently rot under a
-- rename). Also doubles as the contract for what `set_default_hl` defines.
M.HL = {
    BORDER_CODE = "JovianCellBorderCode",
    BORDER_MARKDOWN = "JovianCellBorderMarkdown",
}
local HL_BORDER_CODE = M.HL.BORDER_CODE
local HL_BORDER_MARKDOWN = M.HL.BORDER_MARKDOWN

local function frame_hl_for(kind)
    if kind == "Markdown" then
        return HL_BORDER_MARKDOWN
    end
    return HL_BORDER_CODE
end

-- Anything matching this is treated as a cell header line. Mirrors
-- cell.lua's regex (which uses Vim's pattern syntax; the Lua form is
-- equivalent for the leading marker only).
local HEADER_RE = "^#%s*%%%%"

-- For each cell type, walk a fallback chain of standard / Tree-sitter
-- highlight groups and pick the first one the active colorscheme actually
-- defines. This way the frame color follows the user's theme: themes that
-- give `WarningMsg` an orange-ish fg get orange markdown borders, themes
-- that give `Function` a blue-ish fg get blue code borders, etc.
local CODE_BORDER_FALLBACKS = {
    "Function",
    "@function",
    "Identifier",
    "DiagnosticInfo",
    "Type",
    "Comment",
}
local MD_BORDER_FALLBACKS = {
    "WarningMsg",
    "DiagnosticWarn",
    "@number",
    "Number",
    "Constant",
    "Special",
}

local function set_default_hl()
    local user_hl = Config.options.highlights or {}
    -- Pull from the active colorscheme so the outline tracks the theme.
    -- User overrides (string link / table attrs) still win.
    Highlights.apply(HL_BORDER_CODE, user_hl.cell_border_code, Highlights.pick_existing(CODE_BORDER_FALLBACKS))
    Highlights.apply(HL_BORDER_MARKDOWN, user_hl.cell_border_markdown, Highlights.pick_existing(MD_BORDER_FALLBACKS))
end

local function repeat_dash(n)
    if n <= 0 then
        return ""
    end
    return string.rep("─", n)
end

local CORNERS = {
    square = { tl = "┌", tr = "┐", bl = "└", br = "┘" },
    rounded = { tl = "╭", tr = "╮", bl = "╰", br = "╯" },
}

local function corners()
    local style = Config.options.cell_frame_style or "square"
    return CORNERS[style] or CORNERS.square
end

-- Build the top border as a single colored string. The label inherits
-- the same highlight as the frame so the whole outline reads as one
-- coherent box (no contrast band at the top edge).
local function top_border(width, label)
    local c = corners()
    local main = c.tl .. "─ " .. label .. " "
    local pad = width - dw(main) - 1 -- 1 for the closing corner
    return main .. repeat_dash(math.max(pad, 0)) .. c.tr
end

local function bottom_border(width)
    local c = corners()
    return c.bl .. repeat_dash(math.max(width - 2, 0)) .. c.br
end

-- Public: classify a single line as a `# %%` cell header. Returns
-- (cell_type, id) or nil. Other UI modules (markdown_cell, etc.) call this
-- so we have one source of truth for the header syntax.
function M.parse_header(line)
    if not line:match(HEADER_RE) then
        return nil
    end
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
local parse_header = M.parse_header

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

-- Exposed so other UI modules (e.g. markdown_cell's image renderer) can
-- size content to the same cell-box width the frame uses, keeping the
-- right border aligned.
function M.text_area_width(winid)
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
    if w < 20 then
        w = 20
    end
    -- No upper cap: the right_align side bar lives at the actual text-area
    -- edge, so the top/bottom dashes must reach there too — otherwise
    -- the frame looks like ┌──── ─┐  │  with a visible gap on wide windows.
    return w
end

-- Inner content width = total text-area width minus 4 columns reserved for
-- the `│ ` left bar and the ` │` right bar. Centralised so the `-4` magic
-- number lives in one place (was scattered across markdown_table /
-- markdown_cell / output_render).
function M.inner_text_width(winid)
    return math.max(M.text_area_width(winid) - 4, 1)
end

-- Wrap an arbitrary text chunk so it fits inside the cell frame:
--   │ <text padded to inner_w> │
-- virt_lines don't honour `right_align`, so renderers that add a virt_line
-- inside a cell (output blocks, math blocks, markdown table borders, image
-- labels, …) must build the side bars themselves. This is that builder.
function M.frame_wrap(text, hl, inner_w, border_hl)
    local pad = math.max(inner_w - dw(text), 0)
    return {
        { "│ ", border_hl },
        { text, hl },
        { string.rep(" ", pad) .. " │", border_hl },
    }
end

-- Same idea as frame_wrap but for a Kitty placeholder row (already chunked
-- into one chunk per cell column by jovian.ui.kitty). `cols` is the
-- placeholder's display width; we right-pad to `inner_w`.
function M.frame_image_row(placeholder_chunks, cols, inner_w, border_hl)
    local pad = math.max(inner_w - cols, 0)
    local out = { { "│ ", border_hl } }
    for _, c in ipairs(placeholder_chunks) do
        table.insert(out, c)
    end
    table.insert(out, { string.rep(" ", pad) .. " │", border_hl })
    return out
end

-- Render all cell frames in `bufnr` against the given window's text width.
-- Safe to call on every TextChanged; the whole namespace is wiped first.
function M.render(bufnr, winid)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    winid = winid or vim.api.nvim_get_current_win()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    set_default_hl()

    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

    if not Config.options.cell_frame then
        return
    end

    local headers, total = parse_cells(bufnr)
    if #headers == 0 then
        return
    end

    local width = M.text_area_width(winid)

    for idx, h in ipairs(headers) do
        local next_line = headers[idx + 1] and headers[idx + 1].line or total
        local last_src = next_line - 1
        if last_src < h.line then
            last_src = h.line
        end

        local label = h.kind
        if h.id then
            -- Truncate IDs to keep the header tidy; full id stays in source
            label = label .. " [" .. h.id:sub(1, 8) .. "]"
        end
        local hl = frame_hl_for(h.kind)

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
            virt_text = { { top_border(width, label), hl } },
            virt_text_pos = "overlay",
            hl_mode = "combine",
            priority = 199,
        })

        -- 3. Left + right bars on each source line of the cell.
        --    `virt_text_repeat_linebreak = true` keeps the bars visible on
        --    every wrapped continuation row (Neovim 0.10+). On older
        --    versions the option is silently ignored. The priority is
        --    user-tunable so the bars can be drawn above (or yield to) an
        --    indent-guide plugin's vertical line — see `cell_frame_priority`.
        local bar_priority = Config.options.cell_frame_priority or 100
        for ln = h.line + 1, last_src do
            pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, ln, 0, {
                virt_text = { { "│ ", hl } },
                virt_text_pos = "inline",
                virt_text_repeat_linebreak = true,
                hl_mode = "combine",
                priority = bar_priority,
            })
            pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, ln, 0, {
                virt_text = { { "│", hl } },
                virt_text_pos = "right_align",
                virt_text_repeat_linebreak = true,
                hl_mode = "combine",
                priority = bar_priority,
            })
        end

        -- 4. Bottom block on the last source line via virt_lines. When
        --    inline_outputs is on and the sidecar JSON has anything for
        --    this cell, the block is:
        --       ├─ Out[N] ────────────┤
        --       │ ...output lines...  │
        --       └─────────────────────┘
        --    Otherwise it's just the closing border.
        local lines_below = {}
        if Config.options.inline_outputs and h.kind == "Code" then
            local OutRender = require("jovian.ui.output_render")
            OutRender.setup_hl(hl)
            local src_path = vim.api.nvim_buf_get_name(bufnr)
            local co = OutRender.cell_outputs(src_path, h.id)
            if co and co.outputs and #co.outputs > 0 then
                -- Pass a refresh callback so async Kitty image transmits
                -- can trigger a re-render once they land.
                local refresh = function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        M.schedule(bufnr)
                    end
                end
                local out_rows = OutRender.build_virt_lines(co.outputs, co.execution_count, width, hl, refresh, h.id)
                for _, row in ipairs(out_rows) do
                    table.insert(lines_below, row)
                end
            end
        end
        table.insert(lines_below, { { bottom_border(width), hl } })
        vim.api.nvim_buf_set_extmark(bufnr, NS, last_src, 0, {
            virt_lines = lines_below,
        })
    end
end

function M.clear(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    end
end

-- Per-buffer trailing-edge debounce around M.render. The `resolve` hook
-- runs AT FIRE TIME so the winid is re-checked against current geometry —
-- important after a resize where textoff/width may have shifted between the
-- schedule call and the actual render.
M.schedule = Debounce.make(function(bufnr, winid)
    M.render(bufnr, winid)
end, {
    resolve = function(bufnr, winid)
        if not winid or not vim.api.nvim_win_is_valid(winid) then
            local wins = vim.fn.win_findbuf(bufnr)
            winid = wins[1] or vim.api.nvim_get_current_win()
        end
        return winid
    end,
})

-- Public for tests.
M._parse_cells = parse_cells
M._namespace = NS
M._top_border = top_border
M._bottom_border = bottom_border

return M
