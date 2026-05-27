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
    -- Distinct saturated colors per heading level so they're immediately
    -- recognizable at a glance, instead of "all bold, vaguely similar".
    -- Uses explicit fg colors (tokyonight-ish palette) under default=true
    -- so colorschemes and users still win when they define these names.
    local set = function(name, opts)
        local merged = vim.tbl_extend("force", opts, { default = true })
        vim.api.nvim_set_hl(0, name, merged)
    end
    set(HL.H1, { fg = "#7dcfff", bold = true, underline = true })
    set(HL.H2, { fg = "#bb9af7", bold = true })
    set(HL.H3, { fg = "#9ece6a", bold = true })
    set(HL.H4, { fg = "#e0af68", bold = true })
    set(HL.H5, { fg = "#f7768e", bold = true })
    set(HL.H6, { fg = "#7aa2f7", bold = true })
    set(HL.Bold, { bold = true })
    set(HL.Em, { italic = true })
    set(HL.Code, { link = "String" })
    set(HL.Bullet, { link = "Special" })
    set(HL.Quote, { link = "Comment" })
end

-- Visual badge inserted before each heading body so the eye picks up the
-- heading level even before the color registers. Heavier glyphs on bigger
-- headings; thinner ones taper down.
local HEADING_PREFIX = { "█ ", "▆ ", "▊ ", "▌ ", "▎ ", "▏ " }

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

-- Strip the Python comment prefix (`# ` or bare `#`) that every line of a
-- `# %% [markdown]` cell has to wear so the .py file stays valid Python.
-- Returns the byte length of the prefix (so we can conceal it) and the
-- remaining markdown content. Returns nil if the line isn't a `#`-prefixed
-- comment — we leave such lines alone rather than misinterpret them.
local function strip_py_md_prefix(line)
    if line:sub(1, 2) == "# " then
        return 2, line:sub(3)
    end
    if line == "#" then
        return 1, ""
    end
    return nil, nil
end

local function style_heading(buf, lnum, content, offset)
    local hashes, rest_offset = content:match("^(#+)()%s")
    if not hashes then return false end
    local level = math.min(#hashes, 6)
    local hl = HL["H" .. level] or HL.H6
    -- Conceal the `#`/`##`/... marker AND its trailing space.
    conceal_range(buf, lnum, offset, offset + rest_offset)
    -- Insert a colored level badge in their place — same color as the
    -- heading body, so the whole heading reads as one continuous block.
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, offset + rest_offset, {
        virt_text = { { HEADING_PREFIX[level] or HEADING_PREFIX[6], hl } },
        virt_text_pos = "inline",
        hl_mode = "combine",
        priority = 200,
    })
    hl_range(buf, lnum, offset + rest_offset, offset + #content, hl)
    return true
end

local function style_bullet(buf, lnum, content, offset)
    local indent_end, _marker, body_start = content:match("^(%s*)([-*])()%s")
    if not indent_end then return false end
    local marker_col = #indent_end
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, offset + marker_col, {
        end_col = offset + marker_col + 1,
        conceal = "•",
        hl_mode = "combine",
        priority = 200,
    })
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, offset + marker_col, {
        end_col = offset + body_start,
        hl_group = HL.Bullet,
        hl_mode = "combine",
        priority = 195,
    })
    return true
end

local function style_quote(buf, lnum, content, offset)
    local prefix_end = content:match("^>()%s") or content:match("^>()$")
    if not prefix_end then return false end
    conceal_range(buf, lnum, offset, offset + prefix_end)
    hl_range(buf, lnum, offset + prefix_end, offset + #content, HL.Quote)
    return true
end

local function style_inline(buf, lnum, content, offset)
    -- Bold **text** — concealed pairs, inner bolded
    local s = 1
    while true do
        local a, b = content:find("%*%*[^%*]+%*%*", s)
        if not a then break end
        conceal_range(buf, lnum, offset + a - 1, offset + a + 1)
        hl_range(buf, lnum, offset + a + 1, offset + b - 2, HL.Bold)
        conceal_range(buf, lnum, offset + b - 2, offset + b)
        s = b + 1
    end

    -- Inline code `text`
    s = 1
    while true do
        local a, b = content:find("`([^`]+)`", s)
        if not a then break end
        conceal_range(buf, lnum, offset + a - 1, offset + a)
        hl_range(buf, lnum, offset + a, offset + b - 1, HL.Code)
        conceal_range(buf, lnum, offset + b - 1, offset + b)
        s = b + 1
    end
    -- Italic intentionally skipped: distinguishing `*italic*` from list
    -- markers, multiplication operators, and runaway `**bold**` patterns
    -- requires more state than is worth carrying in Phase 2. Use the
    -- `_underscore_` form if you need it (also intentionally unhandled).
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
            for ln = h.line + 1, next_line - 1 do
                local line = lines[ln + 1] or ""
                if line ~= "" then
                    local prefix_len, content = strip_py_md_prefix(line)
                    if prefix_len then
                        -- Conceal the Python comment prefix so the line looks
                        -- like real markdown. The actual `# ` stays in the
                        -- buffer (so the file remains valid Python on disk).
                        conceal_range(bufnr, ln, 0, prefix_len)
                        if content ~= "" then
                            if not style_heading(bufnr, ln, content, prefix_len)
                                and not style_quote(bufnr, ln, content, prefix_len)
                            then
                                style_bullet(bufnr, ln, content, prefix_len)
                            end
                            style_inline(bufnr, ln, content, prefix_len)
                        end
                    end
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
