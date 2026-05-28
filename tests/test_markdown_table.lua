-- Box-drawn markdown table rendering (jovian.ui.markdown_table), render-markdown
-- style: each source row is overlaid in place (conceal raw + inline virt_text),
-- with top/bottom borders as virt_lines. Headless, no terminal needed.

vim.opt.rtp:prepend(vim.fn.getcwd())

local pass, fail = 0, 0
local function assert_true(cond, msg)
    if cond then
        pass = pass + 1
        print("  PASS " .. msg)
    else
        fail = fail + 1
        print("  FAIL " .. msg)
    end
end

require("jovian").setup({ markdown_cell_style = true })
local MT = require("jovian.ui.markdown_table")
local NS = require("jovian.ui.markdown_cell")._namespace

local function chunks_text(chunks)
    local t = {}
    for _, ch in ipairs(chunks) do
        t[#t + 1] = ch[1]
    end
    return table.concat(t)
end

-- Render rows; collect per-line overlay text + the border virt_lines.
local function render(rows)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        vim.tbl_map(function(r)
            return "# " .. r
        end, rows)
    )
    local block = {}
    for i, c in ipairs(rows) do
        block[i] = { ln = i - 1, content = c, offset = 2 }
    end
    local r = { ok = MT.render(buf, NS, block), inline = {}, concealed = {}, top = nil, bottom = nil }
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
        local ln, d = m[2], m[4]
        if d.conceal == "" and d.end_col and d.end_col > 2 then
            r.concealed[ln] = true
        end
        if d.virt_text and d.virt_text_pos == "inline" then
            r.inline[ln] = chunks_text(d.virt_text)
        end
        if d.virt_lines then
            local line = chunks_text(d.virt_lines[1])
            if d.virt_lines_above then
                r.top = line
            else
                r.bottom = line
            end
        end
    end
    return r
end

-- ---------------------------- in-place overlay + borders ----------------------------
print("\n-- in-place overlay --")
local r = render({ "| a | bb |", "| --- | --- |", "| 1 | 2 |" })
assert_true(r.ok, "render() succeeds")
assert_true(r.concealed[0] and r.concealed[1] and r.concealed[2], "every source row's raw text is concealed in place")
assert_true(r.inline[0] and r.inline[1] and r.inline[2], "every source row is overlaid with an inline rendered row")
assert_true(r.top ~= nil and r.bottom ~= nil, "top + bottom borders are added as virtual lines")
assert_true(
    r.top:find("╭", 1, true) and r.top:find("╮", 1, true),
    "default border is rounded (render-markdown 'round' preset)"
)
assert_true(r.bottom:find("╰", 1, true) and r.bottom:find("╯", 1, true), "bottom border has rounded corners")
-- every rendered line (borders + overlaid rows) shares one display width
local W, aligned = vim.fn.strdisplaywidth(r.top), true
for _, line in pairs(r.inline) do
    if vim.fn.strdisplaywidth(line) ~= W then
        aligned = false
    end
end
if vim.fn.strdisplaywidth(r.bottom) ~= W then
    aligned = false
end
assert_true(aligned, "all rendered lines share one display width (columns aligned)")

-- ---------------------------- CJK alignment ----------------------------
print("\n-- CJK alignment --")
local c = render({ "| 名前 | 値 |", "| --- | --- |", "| あ | x |", "| 長い名前 | yyy |" })
local cw, cjk_ok = vim.fn.strdisplaywidth(c.top), true
for _, line in pairs(c.inline) do
    if vim.fn.strdisplaywidth(line) ~= cw then
        cjk_ok = false
    end
end
assert_true(cjk_ok, "CJK rows align to a single display width (strdisplaywidth, not bytes)")

-- ---------------------------- alignment indicator ----------------------------
print("\n-- alignment indicator --")
local a = render({ "| a | b |", "| :-- | --: |", "| 1 | 2 |" })
assert_true(
    a.inline[1] and a.inline[1]:find("━", 1, true),
    "explicit `:--`/`--:` alignment marked with `━` in the delimiter row"
)

-- ---------------------------- single line per row (no <br> split) ----------------------------
print("\n-- single line per row --")
local b = render({ "| k | detail |", "| --- | --- |", "| x | first<br>second |" })
assert_true(
    b.inline[2] and b.inline[2]:find("first<br>second", 1, true),
    "`<br>` is kept literal on one row (render-markdown behavior)"
)
local rows_with_inline = 0
for _ in pairs(b.inline) do
    rows_with_inline = rows_with_inline + 1
end
assert_true(rows_with_inline == 3, "exactly one rendered row per source row (no extra lines)")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
