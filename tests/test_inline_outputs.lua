-- Phase 4 unit test: write a synthetic sidecar JSON with stream / result
-- / error outputs, render the cell_frame for a `# %%` cell with the
-- matching id, assert that the cell's virt_lines include the divider
-- (├─ Out[N] ─┤), each stream line, and the error traceback.

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
    inline_outputs = true,
    use_lua_native_shell = false,
})

local CellFrame = require("jovian.ui.cell_frame")
local OutRender = require("jovian.ui.output_render")

-- Synthetic source file with a single code cell
local src_path = vim.fn.tempname() .. "/scratch.py"
local src_dir = vim.fn.fnamemodify(src_path, ":h")
vim.fn.mkdir(src_dir, "p")

vim.cmd("edit " .. src_path)
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% id="probe1"',
    'print("hello")',
})
vim.cmd("write")

-- Write the sidecar JSON the cell_frame will pick up
local sidecar_dir = src_dir .. "/.jovian_cache/" .. vim.fn.fnamemodify(src_path, ":t")
vim.fn.mkdir(sidecar_dir, "p")
local sidecar = {
    version = 1,
    cells = {
        probe1 = {
            execution_count = 7,
            outputs = {
                {
                    output_type = "stream",
                    name = "stdout",
                    text = "hello\nworld\n",
                },
                {
                    output_type = "execute_result",
                    execution_count = 7,
                    data = { ["text/plain"] = "42" },
                    metadata = {},
                },
                {
                    output_type = "error",
                    ename = "ValueError",
                    evalue = "no good",
                    traceback = { "Traceback (most recent call last):", "  ...", "ValueError: no good" },
                },
            },
        },
    },
}
local fh = io.open(sidecar_dir .. "/outputs.json", "w")
fh:write(vim.json.encode(sidecar))
fh:close()
-- Drop cached read so the renderer picks up the fresh file
OutRender.invalidate(src_path)

CellFrame.render(buf, vim.api.nvim_get_current_win())

-- Find the cell_frame's virt_lines extmark on the last source line (= line 1, 0-indexed)
local marks = vim.api.nvim_buf_get_extmarks(buf, CellFrame._namespace, 0, -1, { details = true })
local virt_lines = nil
for _, m in ipairs(marks) do
    local det = m[4]
    if det.virt_lines and #det.virt_lines > 0 and m[2] == 1 then
        virt_lines = det.virt_lines
        break
    end
end
assert_true(virt_lines ~= nil, "cell has a virt_lines extmark on its last source line")
assert_true(
    #virt_lines >= 6,
    "virt_lines >= divider+2 stream+1 result+3 trace+bottom (got " .. tostring(#virt_lines) .. ")"
)

local function joined_line(line_idx)
    if not virt_lines[line_idx] then
        return nil
    end
    local parts = {}
    for _, chunk in ipairs(virt_lines[line_idx]) do
        table.insert(parts, chunk[1])
    end
    return table.concat(parts, "")
end

local divider = joined_line(1)
assert_true(divider and divider:match("├") and divider:match("Out%[7%]"), "first virt_line is the Out[7] divider")

-- Lookup the highlight group on the stream/result/error rows.
local function row_has_hl(line_idx, hl_name)
    if not virt_lines[line_idx] then
        return false
    end
    for _, chunk in ipairs(virt_lines[line_idx]) do
        if chunk[2] == hl_name then
            return true
        end
    end
    return false
end

assert_true(row_has_hl(2, "JovianOutStdout"), "stream rows tagged JovianOutStdout")
-- result row position: divider + 2 stream lines = 3 → result at index 4
local result_row = joined_line(4)
assert_true(result_row and result_row:find("42", 1, true), "result row contains text/plain payload")
assert_true(row_has_hl(4, "JovianOutResult"), "result row tagged JovianOutResult")

-- Error rows: ename:evalue header + 3 traceback lines → indices 5..8
local err_head = joined_line(5)
assert_true(err_head and err_head:find("ValueError: no good", 1, true), "error header has ename: evalue")
assert_true(row_has_hl(5, "JovianOutError"), "error row tagged JovianOutError")

-- The final virt_line is the bottom border
local last = joined_line(#virt_lines)
assert_true(last and last:match("└"), "last virt_line is the bottom border")

-- Toggling inline_outputs off should drop the output block but keep the
-- bottom border alone.
require("jovian.config").options.inline_outputs = false
CellFrame.render(buf, vim.api.nvim_get_current_win())
marks = vim.api.nvim_buf_get_extmarks(buf, CellFrame._namespace, 0, -1, { details = true })
local off_lines = nil
for _, m in ipairs(marks) do
    local det = m[4]
    if det.virt_lines and #det.virt_lines > 0 and m[2] == 1 then
        off_lines = det.virt_lines
        break
    end
end
assert_eq(#(off_lines or {}), 1, "with inline_outputs=false the virt_lines is just the bottom border")

-- ---------------------------- preview buffer render ----------------------------
print("\n-- output_render.render_to_buffer (preview path) --")
require("jovian.config").options.inline_outputs = true

-- A fresh buffer stands in for State.buf.preview here. We don't need an
-- actual window — render_to_buffer scrolls only when one is supplied.
local preview_buf = vim.api.nvim_create_buf(false, true)
OutRender.render_to_buffer(preview_buf, nil, src_path, "probe1")

local preview_lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
assert_true(preview_lines[1]:match("Out%[7%]"), "preview header is Out[7]")
-- The underline is a row of `─` (3-byte UTF-8 each). Lua patterns are
-- byte-oriented, so check via find + no other content.
assert_true(
    preview_lines[2]:find("─", 1, true) ~= nil and not preview_lines[2]:match("[%w]"),
    "second line is a `─` underline (no other content)"
)

local joined_preview = table.concat(preview_lines, "\n")
assert_true(joined_preview:find("hello", 1, true), "preview includes stdout line")
assert_true(joined_preview:find("world", 1, true), "preview includes second stdout line")
assert_true(joined_preview:find("42", 1, true), "preview includes execute_result text/plain")
assert_true(joined_preview:find("ValueError: no good", 1, true), "preview includes error header")

-- An empty cell (no entry in sidecar) should still produce a "no output" placeholder.
local empty_buf = vim.api.nvim_create_buf(false, true)
OutRender.render_to_buffer(empty_buf, nil, src_path, "does_not_exist")
local empty_lines = vim.api.nvim_buf_get_lines(empty_buf, 0, -1, false)
assert_true(
    empty_lines[3] and empty_lines[3]:match("no output"),
    "preview shows '(no output)' placeholder for an empty cell"
)

-- ---------------------------- carriage-return (tqdm) handling ----------------------------
print("\n-- process_cr (tqdm \\r overwrite) --")
local pc = OutRender._process_cr
assert_eq(pc("plain text"), "plain text", "no \\r passes through unchanged")
-- Progress bar: each \r reprints; only the final frame should survive.
assert_eq(pc(" 0%|  |\r 50%|## |\r100%|####|"), "100%|####|", "carriage returns collapse to the last frame")
-- Multi-line with \r on one of them.
assert_eq(pc("start\rgo\nfinal\n"), "go\nfinal", "\\r overwrite is per logical line; trailing blank dropped")
-- A real tqdm cell renders ONE progress row, not many.
local tqdm_rows = OutRender.build_virt_lines({
    { output_type = "stream", name = "stderr", text = " 10%|#   | 2/20\r 50%|##  | 10/20\r100%|####| 20/20\n" },
}, 3, 40, "JovianCellBorderCode")
-- divider + exactly one stream row + ... (no per-frame rows)
local stream_row_count = 0
for i = 2, #tqdm_rows do
    local parts = {}
    for _, c in ipairs(tqdm_rows[i]) do
        parts[#parts + 1] = c[1]
    end
    if table.concat(parts):find("%d+/20") then
        stream_row_count = stream_row_count + 1
    end
end
assert_eq(stream_row_count, 1, "tqdm renders a single (final) progress row inline")

-- ---------------------------- long-output elision ----------------------------
print("\n-- long output capping --")
require("jovian.config").options.inline_output_max_lines = 10
local big = {}
for i = 1, 100 do
    big[#big + 1] = "line " .. i
end
local long_rows = OutRender.build_virt_lines({
    { output_type = "stream", name = "stdout", text = table.concat(big, "\n") .. "\n" },
}, 1, 40, "JovianCellBorderCode")
-- divider + at most 10 capped rows
assert_true(#long_rows <= 1 + 10, "100-line output capped to <= max+divider (got " .. #long_rows .. ")")
local joined_long = ""
for _, row in ipairs(long_rows) do
    for _, c in ipairs(row) do
        joined_long = joined_long .. c[1]
    end
    joined_long = joined_long .. "\n"
end
assert_true(joined_long:find("more line", 1, true), "shows a '… N more …' notice")
assert_true(joined_long:find("line 1", 1, true), "keeps head lines")
assert_true(joined_long:find("line 100", 1, true), "keeps tail lines")

-- A cell with an image is NOT capped (plots are bounded).
require("jovian.config").options.inline_output_max_lines = 2
local img_rows = OutRender.build_virt_lines({
    { output_type = "stream", name = "stdout", text = "a\nb\nc\nd\ne\n" },
    { output_type = "display_data", data = { ["image/png"] = "AAAA" }, metadata = {} },
}, 1, 40, "JovianCellBorderCode")
-- The 5 stream lines survive (not capped to 2) because an image is present.
-- Look for a row whose Result-highlighted chunk text is exactly "e".
local function has_text_row(rows, want)
    for _, row in ipairs(rows) do
        for _, c in ipairs(row) do
            if c[1] == want then
                return true
            end
        end
    end
    return false
end
assert_true(
    has_text_row(img_rows, "a") and has_text_row(img_rows, "e"),
    "image cell keeps all text rows (no cap when an image is present)"
)

vim.fn.delete(src_dir, "rf")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
