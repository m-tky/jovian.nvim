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
local MarkdownTable = require("jovian.ui.markdown_table")
local Math = require("jovian.ui.math")

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
    TableDivider = "JovianMdTableDivider",
    TableHeader = "JovianMdTableHeader",
    Math = "JovianMdMath",
}

-- For each heading level, try Tree-sitter markdown groups first
-- (modern colorschemes), then the generic Tree-sitter heading groups,
-- then legacy vim-syntax `markdownH<n>`, then a safe stdlib fallback.
-- We pick whichever the active colorscheme actually defines.
local HEADING_FALLBACKS = {
    [1] = { "@markup.heading.1.markdown", "@markup.heading.1", "markdownH1", "Title" },
    [2] = { "@markup.heading.2.markdown", "@markup.heading.2", "markdownH2", "Function" },
    [3] = { "@markup.heading.3.markdown", "@markup.heading.3", "markdownH3", "Type" },
    [4] = { "@markup.heading.4.markdown", "@markup.heading.4", "markdownH4", "Constant" },
    [5] = { "@markup.heading.5.markdown", "@markup.heading.5", "markdownH5", "Statement" },
    [6] = { "@markup.heading.6.markdown", "@markup.heading.6", "markdownH6", "Identifier" },
}

-- `nvim_get_hl(..., { link = false })` resolves links and returns the
-- actual attrs. If a group exists but has no visible attrs (empty
-- table), we treat it as "not really defined".
local function group_has_styling(name)
    local h = vim.api.nvim_get_hl(0, { name = name, link = false })
    if not h then
        return false
    end
    return h.fg ~= nil or h.bg ~= nil or h.bold or h.italic or h.underline
end

local function pick_existing(candidates)
    for _, name in ipairs(candidates) do
        if group_has_styling(name) then
            return name
        end
    end
    return nil
end

-- Apply a user-config value to a highlight group. The value may be:
--   string → treat as `:hi link` target
--   table  → forwarded as `nvim_set_hl` attrs
--   nil    → use the supplied fallback (string link or table of attrs)
local function apply_hl(target, user_val, fallback)
    local val = user_val
    if val == nil then
        val = fallback
    end
    if val == nil then
        return
    end
    if type(val) == "string" then
        vim.api.nvim_set_hl(0, target, { link = val, force = true })
    elseif type(val) == "table" then
        local attrs = vim.deepcopy(val)
        attrs.force = true
        vim.api.nvim_set_hl(0, target, attrs)
    end
end

local function set_default_hl()
    local user_hl = Config.options.highlights or {}
    -- Headings: explicit config wins; otherwise pick whichever group from
    -- the fallback chain is actually defined by the colorscheme.
    for level = 1, 6 do
        local key = "md_h" .. level
        local fallback = pick_existing(HEADING_FALLBACKS[level])
        apply_hl(HL["H" .. level], user_hl[key], fallback)
    end
    apply_hl(HL.Bold, user_hl.md_bold, { bold = true })
    apply_hl(HL.Em, user_hl.md_em, { italic = true })
    apply_hl(HL.Code, user_hl.md_code, "String")
    apply_hl(HL.Bullet, user_hl.md_bullet, "Special")
    apply_hl(HL.Quote, user_hl.md_quote, "Comment")
    apply_hl(HL.TableDivider, user_hl.md_table_divider, "Special")
    apply_hl(HL.TableHeader, user_hl.md_table_header, { bold = true })
    apply_hl(HL.Math, user_hl.md_math, "Special")
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
    if not hashes then
        return false
    end
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
    local indent_end, _, body_start = content:match("^(%s*)([-*])()%s")
    if not indent_end then
        return false
    end
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
    if not prefix_end then
        return false
    end
    conceal_range(buf, lnum, offset, offset + prefix_end)
    hl_range(buf, lnum, offset + prefix_end, offset + #content, HL.Quote)
    return true
end

-- A row is a pipe-table line if it starts with `|` and has at least two
-- pipes. We don't require trailing `|` since GFM tolerates an open-ended
-- right side, and pipes inside code spans are rare enough to ignore for
-- now (no escape handling).
local function is_table_row(content)
    if content:sub(1, 1) ~= "|" then
        return false
    end
    local count = 0
    for _ in content:gmatch("|") do
        count = count + 1
        if count >= 2 then
            return true
        end
    end
    return false
end

-- Separator rows look like `|---|---|`, `|:--|:-:|--:|`, optionally with
-- spaces around the dashes. They contain only pipes, dashes, colons and
-- whitespace — no letters or digits.
local function is_separator_row(content)
    if content:sub(1, 1) ~= "|" then
        return false
    end
    if not content:match("|[%s%-:]+|") then
        return false
    end
    return content:match("[%w]") == nil
end

-- Replace a single buffer byte with the supplied glyph via a conceal
-- extmark. Requires `conceallevel >= 1` to actually hide; we set that
-- per-window in init.lua when markdown_cell_style is on.
local function conceal_replace(buf, lnum, col, glyph, hl)
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, col, {
        end_col = col + 1,
        conceal = glyph,
        hl_group = hl,
        hl_mode = "combine",
        priority = 200,
    })
end

local function find_pipe_positions(content)
    local out = {}
    local s = 1
    while true do
        local p = content:find("|", s)
        if not p then
            break
        end
        table.insert(out, p)
        s = p + 1
    end
    return out
end

-- A table block is a sequence of consecutive table rows. Rendering them
-- together lets us compute per-column max widths and pad each cell with
-- inline virt_text so columns line up — independently of the user's
-- whitespace in the source. The buffer text is never edited.
local function render_table_block(buf, rows)
    if #rows == 0 then
        return
    end

    -- Parse: for each row, find pipe positions and per-cell width.
    local parsed = {}
    local n_cols = 0
    for _, info in ipairs(rows) do
        local pipes = find_pipe_positions(info.content)
        local cells = {}
        for c = 1, #pipes - 1 do
            local from = pipes[c] + 1 -- byte pos after the | (1-indexed)
            local to = pipes[c + 1] - 1 -- byte pos before next | (1-indexed)
            local width = to - from + 1
            if width < 0 then
                width = 0
            end
            cells[c] = { from = from, to = to, width = width }
        end
        table.insert(parsed, {
            info = info,
            pipes = pipes,
            cells = cells,
            is_sep = is_separator_row(info.content),
        })
        if #cells > n_cols then
            n_cols = #cells
        end
    end

    -- Per-column max width across all rows.
    local max_widths = {}
    for c = 1, n_cols do
        max_widths[c] = 0
    end
    for _, r in ipairs(parsed) do
        for c, cell in ipairs(r.cells) do
            if cell.width > max_widths[c] then
                max_widths[c] = cell.width
            end
        end
    end

    for ri, r in ipairs(parsed) do
        local info = r.info
        local is_header = false
        if not r.is_sep then
            local next_r = parsed[ri + 1]
            is_header = next_r ~= nil and next_r.is_sep
        end

        -- Conceal-replace pipes with box-drawing chars.
        for pi, p in ipairs(r.pipes) do
            local glyph
            if r.is_sep then
                if pi == 1 then
                    glyph = "├"
                elseif pi == #r.pipes then
                    glyph = "┤"
                else
                    glyph = "┼"
                end
            else
                glyph = "│"
            end
            conceal_replace(buf, info.ln, info.offset + p - 1, glyph, HL.TableDivider)
        end

        -- For separator rows: replace every non-pipe byte with `─` so the
        -- rule is continuous (no gaps around the junctions).
        if r.is_sep then
            local pipe_set = {}
            for _, p in ipairs(r.pipes) do
                pipe_set[p] = true
            end
            for col = 1, #info.content do
                if not pipe_set[col] then
                    conceal_replace(buf, info.ln, info.offset + col - 1, "─", HL.TableDivider)
                end
            end
        end

        -- Pad each cell to the column's max width with inline virt_text.
        -- The padding lands BEFORE the closing pipe so the pipe still
        -- ends the cell visually.
        for c, cell in ipairs(r.cells) do
            local pad = (max_widths[c] or 0) - cell.width
            if pad > 0 then
                local fill_char = r.is_sep and "─" or " "
                local fill = string.rep(fill_char, pad)
                local closing_pipe_pos = r.pipes[c + 1] -- 1-indexed
                -- 0-indexed buffer column of the closing pipe byte:
                local target_col = info.offset + closing_pipe_pos - 1
                pcall(vim.api.nvim_buf_set_extmark, buf, NS, info.ln, target_col, {
                    virt_text = { { fill, HL.TableDivider } },
                    virt_text_pos = "inline",
                    hl_mode = "combine",
                    priority = 199,
                })
            end
        end

        if is_header then
            hl_range(buf, info.ln, info.offset, info.offset + #info.content, HL.TableHeader)
        end
    end
end

local function style_inline(buf, lnum, content, offset)
    -- Bold **text** — concealed pairs, inner bolded
    local s = 1
    while true do
        local a, b = content:find("%*%*[^%*]+%*%*", s)
        if not a then
            break
        end
        conceal_range(buf, lnum, offset + a - 1, offset + a + 1)
        hl_range(buf, lnum, offset + a + 1, offset + b - 2, HL.Bold)
        conceal_range(buf, lnum, offset + b - 2, offset + b)
        s = b + 1
    end

    -- Inline code `text`
    s = 1
    while true do
        local a, b = content:find("`([^`]+)`", s)
        if not a then
            break
        end
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

-- Heuristic: are we on a terminal that speaks the Kitty graphics protocol?
-- Used to avoid spawning jovian-core / reading image files when no picture
-- could be drawn anyway. The core's kitty_attach still validates for real.
local function has_kitty_graphics()
    if vim.env.KITTY_WINDOW_ID and vim.env.KITTY_WINDOW_ID ~= "" then
        return true
    end
    local t = ((vim.env.TERM_PROGRAM or "") .. " " .. (vim.env.TERM or "")):lower()
    return t:find("kitty", 1, true) ~= nil or t:find("ghostty", 1, true) ~= nil or t:find("wezterm", 1, true) ~= nil
end

local function is_image_ext(target)
    local lower = target:lower()
    return lower:match("%.png$") ~= nil
        or lower:match("%.jpe?g$") ~= nil
        or lower:match("%.gif$") ~= nil
        or lower:match("%.webp$") ~= nil
end

-- Resolve a markdown image path against the buffer's file directory.
-- Returns an absolute, readable path or nil.
local function resolve_image_path(buf, target)
    local p = target
    if p:sub(1, 1) == "~" then
        p = vim.fn.expand(p)
    end
    if p:sub(1, 1) ~= "/" then
        local base = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p:h")
        if base == "" then
            return nil
        end
        p = base .. "/" .. p
    end
    p = vim.fn.fnamemodify(p, ":p")
    if vim.fn.filereadable(p) == 1 then
        return p
    end
    return nil
end

local function file_to_b64(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    if not data or data == "" or not (vim.base64 and vim.base64.encode) then
        return nil
    end
    return vim.base64.encode(data)
end

-- Whole-line conceal (conceal_lines, Neovim 0.11+) removes a line entirely.
-- A plain char-conceal only hides the glyphs — a long data-URI's bytes still
-- occupy the line, so it keeps wrapping over dozens of (blank) screen rows.
local _has_conceal_lines = vim.fn.has("nvim-0.11") == 1

-- Render a markdown image line identically for both source forms found in
-- jupytext-exported notebooks: remove the `![alt](target)` source line and, in
-- its place, show a `🖼 <name>` label with the picture directly below it.
--   * data URI:  ![alt](data:image/png;base64,<...>)
--   * file path: ![alt](figs/plot.png)
-- The label name is the alt text, falling back to the file's basename (paths)
-- or "image" (data URIs). Both forms collapse the source line with
-- conceal_lines and hang the label+picture off the line ABOVE (conceal_lines
-- also suppresses virt_lines on the same line) — so they render in the same
-- place. (`attachment:` refs carry no data after jupytext and remote URLs
-- aren't fetched, so both are left as plain markdown.) Returns true if the line
-- was a renderable image, so the caller skips normal styling.
local function render_markdown_image(buf, lnum, content, offset)
    local alt, target = content:match("!%[(.-)%]%(([^%s%)]+)%)")
    if not target then
        return false
    end

    local b64
    local is_datauri = false
    if target:match("^data:image/[%w%+%.%-]+;base64,") then
        is_datauri = true
        b64 = target:match("^data:image/[%w%+%.%-]+;base64,(.+)$")
    elseif target:match("^attachment:") or target:match("^%a[%w%+%.%-]*://") then
        return false
    elseif is_image_ext(target) and has_kitty_graphics() then
        local path = resolve_image_path(buf, target)
        if not path then
            return false
        end
        b64 = file_to_b64(path)
        if not b64 then
            return false
        end
    else
        return false
    end

    -- Virt_lines block: a `🖼 <name>` label row, then the picture (if Kitty).
    local name = alt
    if name == "" then
        name = is_datauri and "image" or vim.fn.fnamemodify(target, ":t")
    end
    local virt = { { { "🖼 " .. name, HL.Quote } } }
    if has_kitty_graphics() then
        local Kitty = require("jovian.ui.kitty")
        local OutRender = require("jovian.ui.output_render")
        local cols, rows =
            OutRender.fit_image_in_area(b64, Config.options.image_cols or 56, Config.options.image_rows or 14)
        local id = Kitty.ensure_transmitted(b64, function()
            M.schedule(buf)
        end, cols, rows)
        if id then
            for _, prow in ipairs(Kitty.build_virt_lines(id, rows, cols)) do
                table.insert(virt, prow)
            end
        end
    end

    if _has_conceal_lines then
        -- Collapse the source line and anchor the label+picture to the line
        -- above so conceal_lines doesn't also suppress the virt_lines.
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, 0, { conceal_lines = "", priority = 200 })
        local anchor = lnum > 0 and lnum - 1 or lnum
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, anchor, 0, { virt_lines = virt, priority = 200 })
    else
        -- Fallback (Neovim < 0.11, no conceal_lines): char-conceal the span and
        -- hang the block on the same line. A gap may remain for long data URIs.
        local s, e = content:find("!%[.-%]%([^%s%)]+%)")
        if s then
            conceal_range(buf, lnum, offset + s - 1, offset + e)
        end
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, 0, { virt_lines = virt, priority = 200 })
    end
    return true
end

local function math_enabled()
    local m = Config.options.math
    return m == nil or m.enabled ~= false
end

-- Backtick code-span ranges (1-based, inclusive) in `content`, so inline math
-- inside `code` isn't converted (e.g. a literal `$x$` in prose).
local function code_span_ranges(content)
    local spans, s = {}, 1
    while true do
        local a, b = content:find("`[^`]+`", s)
        if not a then
            break
        end
        spans[#spans + 1] = { a, b }
        s = b + 1
    end
    return spans
end

local function inside_any(spans, a, b)
    for _, sp in ipairs(spans) do
        if a <= sp[2] and b >= sp[1] then
            return true
        end
    end
    return false
end

-- Inline `$…$` math: conceal the span and overlay the converted Unicode.
local function style_math_inline(buf, lnum, content, offset)
    if not math_enabled() then
        return
    end
    local spans = code_span_ranges(content)
    local s = 1
    while true do
        local a, b, inner = content:find("%$([^%$\n]+)%$", s)
        if not a then
            break
        end
        if not inside_any(spans, a, b) then
            conceal_range(buf, lnum, offset + a - 1, offset + b)
            pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum, offset + a - 1, {
                virt_text = { { Math.convert(inner), HL.Math } },
                virt_text_pos = "inline",
                hl_mode = "combine",
                priority = 200,
            })
        end
        s = b + 1
    end
end

-- Detect a `$$ … $$` block starting at cell_lines[i]. Returns (end_index,
-- inner_latex) or nil if the line doesn't open a (terminated) block.
local function detect_math_block(cell_lines, i)
    local first = cell_lines[i].content
    -- Only a line that STARTS with `$$` opens a block — avoids matching `$$`
    -- written inside prose / code spans (e.g. a literal `$$…$$` in backticks).
    if not first:match("^%s*%$%$") then
        return nil
    end
    local single = first:match("^%s*%$%$(.-)%$%$%s*$")
    if single and single ~= "" then
        return i, single
    end
    local _, open_end = first:find("%$%$")
    local parts = {}
    local after = first:sub(open_end + 1)
    if vim.trim(after) ~= "" then
        parts[#parts + 1] = after
    end
    for j = i + 1, #cell_lines do
        local cj = cell_lines[j].content
        local close = cj:find("%$%$")
        if close then
            local before = cj:sub(1, close - 1)
            if vim.trim(before) ~= "" then
                parts[#parts + 1] = before
            end
            return j, table.concat(parts, " ")
        end
        parts[#parts + 1] = cj
    end
    return nil -- unterminated
end

-- Render a `$$ … $$` block, render-markdown.nvim style. `center` (default):
-- a single-line block is concealed and the Unicode overlaid in place; a
-- multi-line block falls back to `above`. `above`/`below`: the Unicode is drawn
-- as a virtual line and the raw LaTeX stays visible (cell-frame `│ ` prefix so
-- it lines up under the frame).
local function render_math_block(buf, cell_lines, start_i, end_i, inner)
    local uni = Math.convert(inner)
    local pos = (Config.options.math or {}).position or "center"
    if pos == "center" and start_i ~= end_i then
        pos = "above" -- center needs a single line (render-markdown semantics)
    end

    if pos == "center" then
        local first = cell_lines[start_i]
        conceal_range(buf, first.ln, first.offset, first.offset + #first.content)
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, first.ln, first.offset, {
            virt_text = { { uni, HL.Math } },
            virt_text_pos = "inline",
            hl_mode = "combine",
            priority = 201,
        })
        return
    end

    local chunks = {}
    if Config.options.cell_frame then
        chunks[1] = { "│ ", "JovianCellBorderMarkdown" }
    end
    chunks[#chunks + 1] = { uni, HL.Math }
    if pos == "below" then
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, cell_lines[end_i].ln, 0, {
            virt_lines = { chunks },
            priority = 200,
        })
    else
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, cell_lines[start_i].ln, 0, {
            virt_lines = { chunks },
            virt_lines_above = true,
            priority = 200,
        })
    end
end

local function is_markdown_header(line)
    if not line:match("^#%s*%%%%") then
        return false
    end
    local lower = line:lower()
    return lower:find("%[markdown%]", 1, false) ~= nil or lower:find("%[md%]", 1, false) ~= nil
end

function M.render(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    set_default_hl()

    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    if not Config.options.markdown_cell_style then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- Walk cells via the cell_frame parser so we agree on cell boundaries
    -- (especially the implicit "scratchpad" top-of-file region).
    local headers = CellFrame._parse_cells(bufnr)
    if #headers == 0 then
        return
    end

    for idx, h in ipairs(headers) do
        local next_line = headers[idx + 1] and headers[idx + 1].line or #lines
        local hdr_line = lines[h.line + 1] or ""
        if is_markdown_header(hdr_line) then
            -- First pass: collect prefix-stripped content for every line.
            -- The second pass needs neighbor info (table header detection
            -- looks ahead one line for the separator row).
            local cell_lines = {}
            for ln = h.line + 1, next_line - 1 do
                local line = lines[ln + 1] or ""
                if line ~= "" then
                    local prefix_len, content = strip_py_md_prefix(line)
                    if prefix_len then
                        table.insert(cell_lines, {
                            ln = ln,
                            content = content,
                            offset = prefix_len,
                        })
                    end
                end
            end

            -- Conceal the Python `#` prefix on every line up front. The
            -- buffer text is untouched (still valid Python).
            for _, info in ipairs(cell_lines) do
                conceal_range(bufnr, info.ln, 0, info.offset)
            end

            -- Walk lines, grouping consecutive table rows so we can align
            -- their columns to a shared max-width.
            local i = 1
            while i <= #cell_lines do
                local info = cell_lines[i]
                local math_end, math_inner
                if info.content ~= "" and math_enabled() and info.content:find("%$%$") then
                    math_end, math_inner = detect_math_block(cell_lines, i)
                end
                if math_end then
                    render_math_block(bufnr, cell_lines, i, math_end, math_inner)
                    i = math_end + 1
                elseif info.content ~= "" and is_table_row(info.content) then
                    local block_end = i
                    while block_end + 1 <= #cell_lines and is_table_row(cell_lines[block_end + 1].content) do
                        block_end = block_end + 1
                    end
                    local block = {}
                    for j = i, block_end do
                        table.insert(block, cell_lines[j])
                    end
                    -- Render-markdown-style in-place overlay (rows stay real,
                    -- borders added as virt_lines). Falls back to the legacy
                    -- pad renderer only if the block isn't a real table.
                    if not MarkdownTable.render(bufnr, NS, block) then
                        render_table_block(bufnr, block)
                    end
                    i = block_end + 1
                else
                    if info.content ~= "" then
                        if not render_markdown_image(bufnr, info.ln, info.content, info.offset) then
                            if
                                not style_heading(bufnr, info.ln, info.content, info.offset)
                                and not style_quote(bufnr, info.ln, info.content, info.offset)
                            then
                                style_bullet(bufnr, info.ln, info.content, info.offset)
                            end
                            style_inline(bufnr, info.ln, info.content, info.offset)
                            style_math_inline(bufnr, info.ln, info.content, info.offset)
                        end
                    end
                    i = i + 1
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

-- Trailing debounce — same rationale as cell_frame.schedule. See its
-- comment for the reasoning vs the LEADING-edge variant we used before.
local uv = vim.uv or vim.loop
local _timers = {}
function M.schedule(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local t = _timers[bufnr]
    if t then
        t:stop()
    else
        t = uv.new_timer()
        _timers[bufnr] = t
    end
    t:start(
        60,
        0,
        vim.schedule_wrap(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                M.render(bufnr)
            end
            if _timers[bufnr] then
                _timers[bufnr]:close()
                _timers[bufnr] = nil
            end
        end)
    )
end

M._namespace = NS

return M
