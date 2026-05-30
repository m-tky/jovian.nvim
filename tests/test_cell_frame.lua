-- Phase 2 unit test for cell frame + markdown styling extmarks.
-- Renders a fixture buffer with code + markdown cells, then asserts that:
--   1. The expected number of cells is detected
--   2. Cell headers get a top-border virt_text overlay extmark
--   3. Source lines get inline + right_align side-bar extmarks
--   4. The last source line of each cell gets a bottom-border virt_lines
--   5. Markdown styling extmarks only land inside the markdown cell
--
-- No nvim-jovian wrapper needed — pure Lua + extmark inspection.

vim.opt.rtp:prepend(vim.fn.getcwd())

local pass, fail = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        pass = pass + 1
        print("  PASS " .. msg)
    else
        fail = fail + 1
        print(string.format("  FAIL %s — expected %s, got %s", msg, tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg)
    if cond then
        pass = pass + 1
        print("  PASS " .. msg)
    else
        fail = fail + 1
        print("  FAIL " .. msg)
    end
end

require("jovian").setup({
    cell_frame = true,
    markdown_cell_style = true,
    use_lua_native_shell = false,
})

local CellFrame = require("jovian.ui.cell_frame")
local MarkdownCell = require("jovian.ui.markdown_cell")

-- Build a fixture buffer
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_option(buf, "filetype", "python")
-- Note: markdown cell lines wear a Python `# ` prefix so the file stays
-- valid Python on disk. The renderer conceals that prefix at display time.
local lines = {
    '# %% id="code1"',
    'print("hello")',
    "x = 1",
    "",
    '# %% [markdown] id="md1"',
    "# # Heading",
    "# plain **bold** text",
    "# - item",
    "# | Name | Age |",
    "# |------|-----|",
    "# | Alice | 30 |",
    "",
    '# %% id="code2"',
    "y = 2",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

-- Open a window for the buffer so width-derived rendering has a real winid
vim.api.nvim_set_current_buf(buf)
local winid = vim.api.nvim_get_current_win()

-- ---------------------------- parser ----------------------------
print("\n-- parse_cells --")
local headers = CellFrame._parse_cells(buf)
assert_eq(#headers, 3, "three cells detected")
assert_eq(headers[1].kind, "Code", "cell 1 is Code")
assert_eq(headers[1].id, "code1", "cell 1 id captured")
assert_eq(headers[2].kind, "Markdown", "cell 2 is Markdown")
assert_eq(headers[2].id, "md1", "cell 2 id captured")
assert_eq(headers[3].kind, "Code", "cell 3 is Code")

-- ---------------------------- frame ------------------------------
print("\n-- cell_frame.render --")
CellFrame.render(buf, winid)
local marks = vim.api.nvim_buf_get_extmarks(buf, CellFrame._namespace, 0, -1, { details = true })

-- Helper: collect extmarks per line
local by_line = {}
for _, m in ipairs(marks) do
    local _, ln, _, det = unpack(m)
    by_line[ln] = by_line[ln] or {}
    table.insert(by_line[ln], det)
end

local function has_overlay_on(ln)
    for _, det in ipairs(by_line[ln] or {}) do
        if det.virt_text_pos == "overlay" and det.virt_text then
            return true
        end
    end
    return false
end

local function has_side_bars_on(ln)
    local left, right = false, false
    for _, det in ipairs(by_line[ln] or {}) do
        if det.virt_text_pos == "inline" then
            left = true
        end
        if det.virt_text_pos == "right_align" then
            right = true
        end
    end
    return left, right
end

local function has_virt_lines_on(ln)
    for _, det in ipairs(by_line[ln] or {}) do
        if det.virt_lines and #det.virt_lines > 0 then
            return true
        end
    end
    return false
end

assert_true(has_overlay_on(0), "code1 header has top-border overlay")
assert_true(has_overlay_on(4), "md1 header has top-border overlay")
assert_true(has_overlay_on(12), "code2 header has top-border overlay")

local l1, r1 = has_side_bars_on(1)
assert_true(l1 and r1, "code1 source line 1 has both side bars")
local l2, r2 = has_side_bars_on(2)
assert_true(l2 and r2, "code1 source line 2 has both side bars")

-- The bottom border lives on the LAST source line of each cell.
-- code1: header=0, last source = 3 (the blank line).
-- md1: header=4, last source = 11 (blank line after the table).
-- code2: header=12, last source = 13.
assert_true(has_virt_lines_on(3), "code1 has bottom virt_lines on last src line")
assert_true(has_virt_lines_on(11), "md1 has bottom virt_lines on last src line")
assert_true(has_virt_lines_on(13), "code2 has bottom virt_lines on last src line")

-- Header lines should NOT have side bars (only overlay)
local l0, r0 = has_side_bars_on(0)
assert_eq(l0, false, "code1 header line has no left bar")
assert_eq(r0, false, "code1 header line has no right bar")

-- ---------------------------- markdown ----------------------------
print("\n-- markdown_cell.render --")
MarkdownCell.render(buf)
local md_marks = vim.api.nvim_buf_get_extmarks(buf, MarkdownCell._namespace, 0, -1, { details = true })

local md_lines = {}
for _, m in ipairs(md_marks) do
    md_lines[m[2]] = true
end

-- Markdown extmarks should land on lines 5/6/7 (heading, bold, list) — NOT on
-- lines inside the code cells.
assert_true(md_lines[5], "heading line has markdown extmark")
assert_true(md_lines[6], "bold line has markdown extmark")
assert_true(md_lines[7], "bullet line has markdown extmark")
assert_eq(md_lines[1] or false, false, "code cell line 1 has no markdown extmark")
assert_eq(md_lines[2] or false, false, "code cell line 2 has no markdown extmark")
assert_eq(md_lines[13] or false, false, "code cell line 13 has no markdown extmark")

-- Each markdown line should have at least one extmark concealing the
-- Python `# ` prefix at columns 0..1 (so visually the line starts with
-- the markdown content, not the `#` comment marker).
local function has_prefix_conceal(lnum)
    for _, m in ipairs(md_marks) do
        if m[2] == lnum then
            local det = m[4]
            if det.conceal == "" and m[3] == 0 and det.end_col == 2 then
                return true
            end
        end
    end
    return false
end
-- Update our test fixture: line index 5 = "# # Heading" — needs prefix conceal
-- but we wrote it as "# # Heading" which already has `# ` then `# Heading`.
-- So col 0..1 should be concealed (the Python `# `), then the inner `# `
-- markdown marker is a separate conceal at cols 2..3.
assert_true(has_prefix_conceal(5), "heading line conceals python `# ` prefix")
assert_true(has_prefix_conceal(6), "bold line conceals python `# ` prefix")
assert_true(has_prefix_conceal(7), "bullet line conceals python `# ` prefix")

-- Table block (lines 8/9/10): rendered render-markdown style — each source row
-- is overlaid in place with an inline rendered row (carrying the table-divider
-- highlight). (The table layout itself is covered by test_markdown_table.)
local function has_table_overlay(ln)
    for _, m in ipairs(md_marks) do
        if m[2] == ln and m[4].virt_text and m[4].virt_text_pos == "inline" then
            for _, ch in ipairs(m[4].virt_text) do
                if ch[2] == "JovianMdTableDivider" then
                    return true
                end
            end
        end
    end
    return false
end
assert_true(has_table_overlay(8), "table header row is overlaid in place")
assert_true(has_table_overlay(9), "table separator row is overlaid in place")
assert_true(has_table_overlay(10), "table data row is overlaid in place")

-- ---------------------------- wrap chrome follows cell type ----------------------------
-- showbreak is window-global, so the wrap bar color has to chase the
-- cursor between cell types. Verify the NonText mapping in winhighlight
-- swaps between code and markdown border groups as the cursor moves.
print("\n-- wrap chrome follows cell type --")
local wrap_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_option(wrap_buf, "filetype", "python")
vim.api.nvim_buf_set_lines(wrap_buf, 0, -1, false, {
    '# %% id="wc1"',
    'x = 1',
    '# %% [markdown] id="wm1"',
    "# # heading",
    '# %% id="wc2"',
    'y = 2',
})
local wrap_win = vim.api.nvim_open_win(wrap_buf, true, {
    relative = "editor", row = 0, col = 0, width = 40, height = 10,
})

local function wrap_winhl_for(cursor_line)
    vim.api.nvim_win_set_cursor(wrap_win, { cursor_line, 0 })
    CellFrame.refresh_wrap_chrome(wrap_buf, wrap_win)
    return vim.api.nvim_get_option_value("winhighlight", { win = wrap_win })
end

-- cursor in a code cell → NonText linked to the code border
assert_true(
    wrap_winhl_for(2):find("NonText:JovianCellBorderCode", 1, true) ~= nil,
    "code-cell cursor → NonText:JovianCellBorderCode"
)
-- cursor in a markdown cell → NonText linked to the markdown border
assert_true(
    wrap_winhl_for(4):find("NonText:JovianCellBorderMarkdown", 1, true) ~= nil,
    "markdown-cell cursor → NonText:JovianCellBorderMarkdown"
)
-- moving back to a code cell flips it back (the stale Markdown entry must
-- be stripped, not just appended after)
local back = wrap_winhl_for(6)
assert_true(
    back:find("NonText:JovianCellBorderCode", 1, true) ~= nil,
    "back to code cell → NonText:JovianCellBorderCode again"
)
assert_true(
    not back:find("NonText:JovianCellBorderMarkdown", 1, true),
    "stale markdown entry stripped from winhighlight"
)

-- showbreak and breakindentopt sbr should be set window-locally
assert_eq(
    vim.api.nvim_get_option_value("showbreak", { win = wrap_win }),
    "│ ",
    "showbreak is `│ ` (wrap continuation marker)"
)
assert_true(
    vim.api.nvim_get_option_value("breakindentopt", { win = wrap_win }):find("sbr", 1, true) ~= nil,
    "breakindentopt includes `sbr` so showbreak shows before the indent"
)

vim.api.nvim_win_close(wrap_win, true)

-- ---------------------------- clear ----------------------------
print("\n-- clear --")
CellFrame.clear(buf)
local after_clear = vim.api.nvim_buf_get_extmarks(buf, CellFrame._namespace, 0, -1, {})
assert_eq(#after_clear, 0, "all cell_frame extmarks cleared")
MarkdownCell.clear(buf)
local md_after_clear = vim.api.nvim_buf_get_extmarks(buf, MarkdownCell._namespace, 0, -1, {})
assert_eq(#md_after_clear, 0, "all markdown extmarks cleared")

-- ---------------------------- disabled gate ----------------------------
print("\n-- disabled gate --")
require("jovian.config").options.cell_frame = false
CellFrame.render(buf, winid)
local marks_off = vim.api.nvim_buf_get_extmarks(buf, CellFrame._namespace, 0, -1, {})
assert_eq(#marks_off, 0, "cell_frame=false produces no extmarks")
require("jovian.config").options.markdown_cell_style = false
MarkdownCell.render(buf)
local md_off = vim.api.nvim_buf_get_extmarks(buf, MarkdownCell._namespace, 0, -1, {})
assert_eq(#md_off, 0, "markdown_cell_style=false produces no extmarks")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
