-- VSCode-notebook-style markdown rendering for `# %% [markdown]` cells.
--
-- We don't rewrite the buffer; we use extmarks with `conceal` and `virt_text`
-- to make the source LOOK rendered. Headings get bolder fg, list bullets
-- get glyphs, **bold** / *italic* / `code` markers are hidden, etc.
--
-- The window's `concealcursor` option is left empty by default, so the
-- cursor's line reveals its raw markdown source while every other line
-- stays styled — that's the editing behavior most people want.
--
-- Scope: only lines inside cells whose header is `# %% [markdown]` (or
-- `[md]`). Code cells are untouched.

local M = {}

local Config = require("jovian.config")
local CellFrame = require("jovian.ui.cell_frame")

local NS = vim.api.nvim_create_namespace("JovianMarkdownCell")

local HL = {
    H1 = "JovianMdH1",
    H2 = "JovianMdH2",
    H3 = "JovianMdH3",
    H4 = "JovianMdH4",
    H5 = "JovianMdH5",
    H6 = "JovianMdH6",
    Bold = "JovianMdBold",
    Em = "JovianMdEm",
    Code = "JovianMdCode",
    Bullet = "JovianMdBullet",
    Quote = "JovianMdQuote",
}

local function set_default_hl()
    -- Link to existing groups so colorschemes adapt automatically. We use
    -- `default = true` so user/colorscheme overrides win.
    local set = function(name, opts)
        if vim.fn.hlexists(name) == 0 then
            vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", opts, { default = true }))
        end
    end
    set(HL.H1, { link = "Title" })
    set(HL.H2, { link = "Title" })
    set(HL.H3, { link = "Function" })
    set(HL.H4, { link = "Identifier" })
    set(HL.H5, { link = "Identifier" })
    set(HL.H6, { link = "Identifier" })
    set(HL.Bold, { bold = true })
    set(HL.Em, { italic = true })
    set(HL.Code, { link = "String" })
    set(HL.Bullet, { link = "Special" })
    set(HL.Quote, { link = "Comment" })
end

local function conceal_range(buf, lnum, start_col, end_col)
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, start_col, {
        end_col = end_col,
        conceal = "",
        hl_mode = "combine",
        priority = 200,
    })
end

local function hl_range(buf, lnum, start_col, end_col, hl)
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, start_col, {
        end_col = end_col,
        hl_group = hl,
        hl_mode = "combine",
        priority = 195,
    })
end

local function style_heading(buf, lnum, line)
    -- Match `^(#+)\s+(.*)$`. Hashes + the trailing space get concealed,
    -- the body is highlighted as the appropriate heading level.
    local hashes, rest_offset = line:match("^(#+)()%s")
    if not hashes then return false end
    local level = math.min(#hashes, 6)
    local hl = HL["H" .. level] or HL.H6
    conceal_range(buf, lnum, 0, rest_offset) -- conceal `#`s and the space after
    hl_range(buf, lnum, rest_offset, #line, hl)
    return true
end

local function style_bullet(buf, lnum, line)
    -- `^(\s*)([-*])\s+(.*)$` → keep indent, replace the dash with a glyph
    local indent_end, marker, body_start = line:match("^(%s*)([-*])()%s")
    if not indent_end then return false end
    local marker_col = #indent_end
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, marker_col, {
        end_col = marker_col + 1,
        conceal = "•",
        hl_mode = "combine",
        priority = 200,
    })
    -- Style the bullet itself
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, marker_col, {
        end_col = body_start,
        hl_group = HL.Bullet,
        hl_mode = "combine",
        priority = 195,
    })
    return true
end

local function style_quote(buf, lnum, line)
    local prefix_end = line:match("^>()%s") or line:match("^>()$")
    if not prefix_end then return false end
    conceal_range(buf, lnum, 0, prefix_end)
    hl_range(buf, lnum, prefix_end, #line, HL.Quote)
    return true
end

local function style_inline(buf, lnum, line)
    -- Bold **text** — concealed pairs, inner bolded
    local s = 1
    while true do
        local a, b = line:find("%*%*[^%*]+%*%*", s)
        if not a then break end
        conceal_range(buf, lnum, a - 1, a + 1)
        hl_range(buf, lnum, a + 1, b - 2, HL.Bold)
        conceal_range(buf, lnum, b - 2, b)
        s = b + 1
    end

    -- Italic *text* — require non-* neighbours so we don't clash with bold
    s = 1
    while true do
        local lead, ia, ib = line:find("([^%*])%*([^%*][^%*]-)%*", s)
        if not lead then break end
        local star1 = ia
        local inner_start = ia + 1
        local inner_end = ib
        conceal_range(buf, lnum, star1 - 1, star1)
        hl_range(buf, lnum, inner_start - 1, inner_end - 1, HL.Em)
        conceal_range(buf, lnum, inner_end - 1, inner_end)
        s = ib + 1
    end

    -- Inline code `text`
    s = 1
    while true do
        local a, b = line:find("`([^`]+)`", s)
        if not a then break end
        conceal_range(buf, lnum, a - 1, a)
        hl_range(buf, lnum, a, b - 1, HL.Code)
        conceal_range(buf, lnum, b - 1, b)
        s = b + 1
    end
end

local function is_markdown_header(line)
    if not line:match("^#%s*%%%%") then return false end
    local lower = line:lower()
    return lower:find("%[markdown%]", 1, false) ~= nil
        or lower:find("%[md%]", 1, false) ~= nil
end

function M.render(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    set_default_hl()

    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    if not Config.options.markdown_cell_style then return end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- Walk cells via the cell_frame parser so we agree on cell boundaries
    -- (especially the implicit "scratchpad" top-of-file region).
    local headers = CellFrame._parse_cells(bufnr)
    if #headers == 0 then return end

    for idx, h in ipairs(headers) do
        local next_line = headers[idx + 1] and headers[idx + 1].line or #lines
        local hdr_line = lines[h.line + 1] or ""
        if is_markdown_header(hdr_line) then
            -- Style each source line in this cell
            for ln = h.line + 1, next_line - 1 do
                local line = lines[ln + 1] or ""
                if line ~= "" then
                    if not style_heading(bufnr, ln, line)
                        and not style_quote(bufnr, ln, line)
                    then
                        style_bullet(bufnr, ln, line)
                    end
                    style_inline(bufnr, ln, line)
                end
            end
        end
    end
end

function M.clear(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    end
end

local _pending = {}
function M.schedule(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if _pending[bufnr] then return end
    _pending[bufnr] = true
    vim.defer_fn(function()
        _pending[bufnr] = nil
        if vim.api.nvim_buf_is_valid(bufnr) then
            M.render(bufnr)
        end
    end, 60)
end

M._namespace = NS

return M
