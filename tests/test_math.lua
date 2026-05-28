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
    "# energy $E=mc^2$ here",
    "# $$",
    "# \\sum_{i=1}^{n} x_i",
    "# $$",
})
MC.render(0)
local buf = vim.api.nvim_get_current_buf()

local inline_on_1, block_concealed, block_vline = false, 0, nil
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
    local ln, d = m[2], m[4]
    if ln == 1 and d.virt_text and d.virt_text_pos == "inline" then
        for _, ch in ipairs(d.virt_text) do
            if ch[1] == "E=mc²" then
                inline_on_1 = true
            end
        end
    end
    if (ln == 2 or ln == 3 or ln == 4) and d.conceal_lines ~= nil then
        block_concealed = block_concealed + 1
    end
    if d.virt_lines then
        local t = {}
        for _, ch in ipairs(d.virt_lines[1]) do
            t[#t + 1] = ch[1]
        end
        local line = table.concat(t)
        if line:find("∑", 1, true) then
            block_vline = line
        end
    end
end

ok(inline_on_1, "inline `$E=mc^2$` is overlaid as `E=mc²`")
ok(block_concealed == 3, "the `$$ … $$` block source rows are collapsed (got " .. block_concealed .. ")")
ok(
    block_vline ~= nil and block_vline:find("xᵢ", 1, true) ~= nil,
    "block math drawn as a Unicode virt_line (got " .. tostring(block_vline) .. ")"
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
