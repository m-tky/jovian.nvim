-- LaTeX math rendering (jovian.ui.math + markdown_cell integration). Headless.

vim.opt.rtp:prepend(vim.fn.getcwd())

local pass, fail = 0, 0
local function eq(actual, expected, msg)
    if actual == expected then
        pass = pass + 1
        print("  PASS " .. msg)
    else
        fail = fail + 1
        print(string.format("  FAIL %s — want %q, got %q", msg, expected, tostring(actual)))
    end
end
local function ok(cond, msg)
    if cond then
        pass = pass + 1
        print("  PASS " .. msg)
    else
        fail = fail + 1
        print("  FAIL " .. msg)
    end
end

require("jovian").setup({ markdown_cell_style = true })
local Math = require("jovian.ui.math")

-- ---------------------------- converter ----------------------------
print("\n-- to_unicode --")
eq(Math.to_unicode("x^2"), "x²", "superscript digit")
eq(Math.to_unicode("a_1"), "a₁", "subscript digit")
eq(Math.to_unicode("x^{2n}"), "x²ⁿ", "multi-char superscript")
eq(Math.to_unicode("\\alpha + \\beta"), "α + β", "greek letters")
eq(Math.to_unicode("\\frac{1}{2}"), "(1)/(2)", "\\frac")
eq(Math.to_unicode("\\sqrt{x}"), "√(x)", "\\sqrt")
eq(Math.to_unicode("\\sqrt[3]{x}"), "³√(x)", "\\sqrt with root")
eq(Math.to_unicode("\\sum"), "∑", "\\sum symbol")
eq(Math.to_unicode("a \\leq b"), "a ≤ b", "\\leq relation")
eq(Math.to_unicode("\\left( x \\right)"), "( x )", "\\left / \\right stripped")
eq(Math.to_unicode("\\mathbb{R}"), "ℝ", "\\mathbb")
eq(Math.to_unicode("\\theta \\to \\infty"), "θ → ∞", "arrow + infinity")
ok(Math.to_unicode("\\unknownmacro x") ~= nil, "unknown macro does not error")

-- ---------------------------- inline + block rendering ----------------------------
print("\n-- markdown_cell math rendering --")
local MC = require("jovian.ui.markdown_cell")
local NS = MC._namespace
local f = vim.fn.tempname() .. ".py"
vim.cmd("edit " .. f)
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    '# %% [markdown] id="m"',
    "# energy $E=mc^2$ here", -- 1: inline math
    "# $$", -- 2..4: multi-line block
    "# \\sum_{i=1}^{n} x_i",
    "# $$",
    "# $$\\frac{a}{b}$$", -- 5: single-line block
})
MC.render(0)
local buf = vim.api.nvim_get_current_buf()

local inline_on_1, single_inline, block_above, src_concealed = false, nil, nil, false
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
    local ln, d = m[2], m[4]
    if d.virt_text and d.virt_text_pos == "inline" then
        local t = {}
        for _, ch in ipairs(d.virt_text) do
            t[#t + 1] = ch[1]
        end
        local s = table.concat(t)
        if ln == 1 and s == "E=mc²" then
            inline_on_1 = true
        elseif ln == 5 then
            single_inline = s -- single-line block overlaid in place
        end
    end
    if d.virt_lines and d.virt_lines_above then
        local t = {}
        for _, ch in ipairs(d.virt_lines[1]) do
            t[#t + 1] = ch[1]
        end
        block_above = table.concat(t)
    end
    if (ln == 2 or ln == 3 or ln == 4) and d.conceal_lines ~= nil then
        src_concealed = true
    end
end

ok(inline_on_1, "inline `$E=mc^2$` is overlaid in place as `E=mc²`")
ok(
    single_inline == "(a)/(b)",
    "single-line `$$\\frac{a}{b}$$` overlaid in place (got " .. tostring(single_inline) .. ")"
)
ok(
    block_above ~= nil and block_above:find("xᵢ", 1, true) ~= nil,
    "multi-line block drawn ABOVE as a virt_line, render-markdown style (got " .. tostring(block_above) .. ")"
)
ok(not src_concealed, "multi-line block keeps its raw `$$` source visible (not collapsed)")

-- ---------------------------- anti-conceal on the cursor line ----------------------------
-- With the cursor ON the single-line block (row 5), its in-place overlay must
-- be dropped so the raw `$$…$$` shows for editing (render-markdown anti_conceal).
vim.api.nvim_win_set_cursor(0, { 6, 0 }) -- 1-indexed; row 5 == single-line block
MC.render(0)
local single_overlay_on_cursor = false
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
    if m[2] == 5 and m[4].virt_text and m[4].virt_text_pos == "inline" then
        single_overlay_on_cursor = true
    end
end
ok(not single_overlay_on_cursor, "cursor line's single-line block overlay is dropped (anti-conceal)")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
