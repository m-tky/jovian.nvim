-- Resilience test: a broken or missing outputs.json sidecar must not
-- crash the renderer or prevent the cell frame from drawing. Users only
-- ever see the bottom border in that case; they don't see a stack trace.

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
local function assert_nil(val, msg)
    assert_true(val == nil, msg)
end

require("jovian").setup({
    cell_frame = true,
    inline_outputs = true,
})

local OutRender = require("jovian.ui.output_render")
local CellFrame = require("jovian.ui.cell_frame")

local function fresh_src()
    local p = vim.fn.tempname() .. "/scratch.py"
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    return p
end

local function write_sidecar(src_path, contents)
    local dir = vim.fn.fnamemodify(src_path, ":p:h")
    local fname = vim.fn.fnamemodify(src_path, ":t")
    local sidecar_dir = dir .. "/.jovian_cache/" .. fname
    vim.fn.mkdir(sidecar_dir, "p")
    local fh = io.open(sidecar_dir .. "/outputs.json", "w")
    fh:write(contents)
    fh:close()
end

local function load_src(src_path)
    vim.cmd("edit " .. src_path)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        '# %% id="probe"',
        'print("hi")',
    })
    vim.cmd("write")
    return buf
end

-- ---------- read_sidecar tolerates malformed inputs ----------
print("\n-- read_sidecar resilience --")

local src1 = fresh_src()
load_src(src1)
write_sidecar(src1, "{not valid json")
OutRender.invalidate(src1)
local ok1, res1 = pcall(OutRender.read_sidecar, src1)
assert_true(ok1, "malformed JSON does not raise")
assert_nil(res1, "malformed JSON yields nil sidecar")

local src2 = fresh_src()
load_src(src2)
write_sidecar(src2, "")
OutRender.invalidate(src2)
local ok2, res2 = pcall(OutRender.read_sidecar, src2)
assert_true(ok2, "empty sidecar does not raise")
assert_nil(res2, "empty sidecar yields nil")

local src3 = fresh_src()
load_src(src3)
write_sidecar(src3, "42")
OutRender.invalidate(src3)
local ok3, res3 = pcall(OutRender.read_sidecar, src3)
assert_true(ok3, "non-object JSON does not raise")
assert_nil(res3, "non-object JSON yields nil (not a table)")

-- ---------- cell_outputs handles a sidecar without `cells` ----------
print("\n-- cell_outputs on partial sidecar --")

local src4 = fresh_src()
load_src(src4)
write_sidecar(src4, '{"version": 1}')
OutRender.invalidate(src4)
local ok4, res4 = pcall(OutRender.cell_outputs, src4, "probe")
assert_true(ok4, "sidecar missing `cells` does not raise")
assert_nil(res4, "cell_outputs returns nil when cells map is absent")

-- ---------- CellFrame.render survives a corrupt sidecar ----------
print("\n-- CellFrame.render with corrupt sidecar --")

local src5 = fresh_src()
local buf5 = load_src(src5)
write_sidecar(src5, "{this is garbage")
OutRender.invalidate(src5)

local ok5, err5 = pcall(CellFrame.render, buf5, vim.api.nvim_get_current_win())
assert_true(ok5, "render does not raise on corrupt sidecar: " .. tostring(err5))

-- At minimum, the bottom border must still be drawn (no output rows, just
-- the closing `└──┘`).
local marks = vim.api.nvim_buf_get_extmarks(buf5, CellFrame._namespace, 0, -1, { details = true })
local found_bottom = false
for _, m in ipairs(marks) do
    local det = m[4]
    if det.virt_lines then
        for _, row in ipairs(det.virt_lines) do
            for _, chunk in ipairs(row) do
                if chunk[1] and (chunk[1]:match("└") or chunk[1]:match("╰")) then
                    found_bottom = true
                end
            end
        end
    end
end
assert_true(found_bottom, "bottom border still rendered despite corrupt sidecar")

-- ---------- build_virt_lines ignores unknown output_type ----------
print("\n-- build_virt_lines with unknown output_type --")

local ok6, rows6 = pcall(OutRender.build_virt_lines, {
    { output_type = "future_extension", data = {} },
    { output_type = "stream", name = "stdout", text = "after\n" },
}, 1, 40, "JovianCellBorderCode")
assert_true(ok6, "unknown output_type does not raise")
assert_true(rows6 ~= nil and #rows6 >= 2, "still produces divider + known rows")

-- Cleanup
for _, s in ipairs({ src1, src2, src3, src4, src5 }) do
    vim.fn.delete(vim.fn.fnamemodify(s, ":h"), "rf")
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
