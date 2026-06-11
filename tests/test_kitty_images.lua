-- Phase 3 unit test: Kitty placeholder generation + image-output path.
-- We stub the Rust core's kitty_transmit RPC so the test doesn't need
-- a real terminal; what we verify is:
--   1. kitty.build_virt_lines(id, rows, cols) returns the expected shape
--   2. output_render notices an image/png in display_data, asks for an
--      image_id via ensure_transmitted, and once one is supplied, emits
--      placeholder rows in the cell's virt_lines block.

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
local function assert_eq(actual, expected, msg)
    assert_true(actual == expected, msg .. " (got " .. tostring(actual) .. ", want " .. tostring(expected) .. ")")
end

require("jovian").setup({
    cell_frame = true,
    inline_outputs = true,
    image_rows = 6,
    image_cols = 20,
})

local Kitty = require("jovian.ui.kitty")
Kitty._reset()

-- ---------------------------- placeholder geometry ----------------------------
print("\n-- kitty.build_virt_lines --")
local vlines = Kitty.build_virt_lines(42, 4, 10)
assert_eq(#vlines, 4, "build_virt_lines produces `rows` rows")
assert_eq(#vlines[1], 10, "each row has `cols` chunks")
-- Every chunk should be { placeholder_text, JovianKittyImg_<id> }
assert_eq(vlines[1][1][2], "JovianKittyImg_42", "chunks carry the per-image hl group")

-- ---------------------------- ensure_transmitted (stubbed RPC) ----------------------------
print("\n-- ensure_transmitted with stubbed core --")

-- Replace Core.client()/Core.ensure() so the test never spawns jovian-core.
-- Pre-mark the attach as completed; ensure_transmitted gates on this.
local Core = require("jovian.backend.core")
Core._kitty_attached = true
Core._kitty_attach_error = nil
local stub_client = {}
function stub_client.request(_self, method, params, cb)
    assert_eq(method, "kitty_transmit", "ensure_transmitted calls kitty_transmit")
    assert_true(params.png_b64 == "AAAA", "png_b64 forwarded verbatim")
    vim.schedule(function()
        cb(nil, { image_id = 999 })
    end)
end
Core.client = function()
    return stub_client
end
Core.ensure = function()
    return stub_client
end

local cb_fired = false
local first = Kitty.ensure_transmitted("AAAA", function(id)
    assert_eq(id, 999, "callback receives image_id from RPC")
    cb_fired = true
end)
assert_true(first == nil, "first call returns nil (transmission in flight)")
vim.wait(200, function()
    return cb_fired
end)
assert_true(cb_fired, "callback fired")

local second = Kitty.ensure_transmitted("AAAA")
assert_eq(second, 999, "subsequent call returns the cached image_id synchronously")

-- ---------------------------- end-to-end via output_render ----------------------------
print("\n-- output_render with image/png output --")
Kitty._reset()
Core.client = function()
    return stub_client
end
Core.ensure = function()
    return stub_client
end

local OutRender = require("jovian.ui.output_render")

-- Synthetic source + sidecar with an image-bearing execute_result
local src_path = vim.fn.tempname() .. "/scratch.py"
local src_dir = vim.fn.fnamemodify(src_path, ":h")
vim.fn.mkdir(src_dir, "p")
vim.cmd("edit " .. src_path)
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% id="img1"',
    "plt.show()",
})
vim.cmd("write")

local sidecar_dir = src_dir .. "/.jovian_cache/" .. vim.fn.fnamemodify(src_path, ":t")
vim.fn.mkdir(sidecar_dir, "p")
local sidecar = {
    version = 1,
    cells = {
        img1 = {
            execution_count = 1,
            outputs = {
                {
                    output_type = "execute_result",
                    execution_count = 1,
                    data = {
                        ["text/plain"] = "<Figure size 800x400 with 1 Axes>",
                        ["image/png"] = "AAAA",
                    },
                    metadata = {},
                },
            },
        },
    },
}
local fh = io.open(sidecar_dir .. "/outputs.json", "w")
fh:write(vim.json.encode(sidecar))
fh:close()
OutRender.invalidate(src_path)

-- Restub for the second image. `_self` absorbs the `:`-call receiver.
function stub_client.request(_self, _method, _params, cb)
    vim.schedule(function()
        cb(nil, { image_id = 777 })
    end)
end

-- First render: image transmit is still in-flight, expect reserved blank rows
local CellFrame = require("jovian.ui.cell_frame")
CellFrame.render(buf, vim.api.nvim_get_current_win())
local marks = vim.api.nvim_buf_get_extmarks(buf, CellFrame._namespace, 0, -1, { details = true })
local virt_lines
for _, m in ipairs(marks) do
    if m[4].virt_lines and m[2] == 1 then
        virt_lines = m[4].virt_lines
    end
end
assert_true(virt_lines ~= nil, "cell has virt_lines block")
-- divider + 6 (reserved blank for image) + bottom = 8 minimum
assert_true(#virt_lines >= 7, "reserved space for image during transmission")

-- Wait (with a predicate, not a fixed sleep) for the stubbed transmit to
-- complete: re-render until a placeholder row with image_id=777 appears.
local function collect_virt_lines()
    local ms = vim.api.nvim_buf_get_extmarks(buf, CellFrame._namespace, 0, -1, { details = true })
    local vl
    for _, m in ipairs(ms) do
        if m[4].virt_lines and m[2] == 1 then
            vl = m[4].virt_lines
        end
    end
    return vl
end
local function has_777(vl)
    for _, row in ipairs(vl or {}) do
        for _, chunk in ipairs(row) do
            if chunk[2] == "JovianKittyImg_777" then
                return true
            end
        end
    end
    return false
end
vim.wait(2000, function()
    CellFrame.render(buf, vim.api.nvim_get_current_win())
    return has_777(collect_virt_lines())
end, 20)
virt_lines = collect_virt_lines()

local has_placeholder_hl = false
for _, row in ipairs(virt_lines) do
    for _, chunk in ipairs(row) do
        if chunk[2] == "JovianKittyImg_777" then
            has_placeholder_hl = true
            break
        end
    end
    if has_placeholder_hl then
        break
    end
end
assert_true(has_placeholder_hl, "rendered virt_lines include Kitty placeholders for image_id=777")

vim.fn.delete(src_dir, "rf")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
