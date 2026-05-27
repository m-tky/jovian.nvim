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
    'x = 1',
    '',
    '# %% [markdown] id="md1"',
    '# # Heading',
    '# plain **bold** text',
    '# - item',
    '',
    '# %% id="code2"',
    'y = 2',
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
        if det.virt_text_pos == "inline" then left = true end
        if det.virt_text_pos == "right_align" then right = true end
    end
    return left, right
end

local function has_virt_lines_on(ln)
    for _, det in ipairs(by_line[ln] or {}) do
        if det.virt_lines and #det.virt_lines > 0 then return true end
    end
    return false
end

assert_true(has_overlay_on(0), "code1 header has top-border overlay")
assert_true(has_overlay_on(4), "md1 header has top-border overlay")
assert_true(has_overlay_on(9), "code2 header has top-border overlay")

local l1, r1 = has_side_bars_on(1)
assert_true(l1 and r1, "code1 source line 1 has both side bars")
local l2, r2 = has_side_bars_on(2)
assert_true(l2 and r2, "code1 source line 2 has both side bars")

-- The bottom border lives on the LAST source line of each cell.
-- code1: header=0, last source = 3 (the blank line). md1: header=4, last = 8.
-- code2: header=9, last = 10.
assert_true(has_virt_lines_on(3), "code1 has bottom virt_lines on last src line")
assert_true(has_virt_lines_on(8), "md1 has bottom virt_lines on last src line")
assert_true(has_virt_lines_on(10), "code2 has bottom virt_lines on last src line")

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
assert_eq(md_lines[10] or false, false, "code cell line 10 has no markdown extmark")

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
