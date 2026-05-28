-- Markdown-cell image rendering: data-URI images (jupytext-exported) and local
-- file-path images (![alt](figs/x.png)). Both conceal the markdown, show a
-- `🖼 <name>` label, and draw the picture below. The Rust core's kitty_transmit
-- RPC is stubbed so no real terminal is needed.

vim.opt.rtp:prepend(vim.fn.getcwd())

-- has_kitty_graphics() keys off these env vars; force "yes" for the test.
vim.env.KITTY_WINDOW_ID = "test"

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

require("jovian").setup({
    markdown_cell_style = true,
    image_rows = 6,
    image_cols = 20,
})

-- Stub the core so ensure_transmitted never spawns jovian-core. Capture every
-- transmitted base64 and hand back a fresh image_id.
local Core = require("jovian.backend.core")
Core._kitty_attached = true
Core._kitty_attach_error = nil
local transmits = {}
local next_id = 500
local stub = {}
function stub.request(_self, method, params, cb)
    if method == "kitty_transmit" then
        next_id = next_id + 1
        local id = next_id
        table.insert(transmits, params.png_b64)
        vim.schedule(function()
            cb(nil, { image_id = id })
        end)
    end
end
Core.client = function()
    return stub
end
Core.ensure = function()
    return stub
end

local Kitty = require("jovian.ui.kitty")
Kitty._reset()
local MarkdownCell = require("jovian.ui.markdown_cell")
local NS = MarkdownCell._namespace

local PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

local src = vim.fn.tempname() .. "/md.py"
local dir = vim.fn.fnamemodify(src, ":h")
vim.fn.mkdir(dir, "p")
vim.cmd("edit " .. src)
local buf = vim.api.nvim_get_current_buf()

local function marks_on(lnum)
    return vim.api.nvim_buf_get_extmarks(buf, NS, { lnum, 0 }, { lnum, -1 }, { details = true })
end

-- ---------------------------- data-URI image ----------------------------
print("\n-- data-URI image --")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% [markdown] id="m1"',
    "# # Heading",
    "# ![pasted](data:image/png;base64," .. PNG .. ")",
})
vim.cmd("write")

MarkdownCell.render(buf)
-- ensure_transmitted sends the RPC on a deferred tick (gated on kitty-ready),
-- so let it fire before counting transmits.
vim.wait(200)

local img_ln = 2 -- 0-based: the data-URI line
-- The source line is collapsed with conceal_lines (so a long base64 doesn't
-- keep wrapping into blank rows); the `🖼 <name>` label + picture hang off the
-- line ABOVE as virt_lines.
local function inspect(image_lnum)
    local collapsed = false
    for _, m in ipairs(marks_on(image_lnum)) do
        if m[4].conceal_lines ~= nil then
            collapsed = true
        end
    end
    local label, has_image = nil, false
    for _, m in ipairs(marks_on(image_lnum - 1)) do
        if m[4].virt_lines then
            for _, row in ipairs(m[4].virt_lines) do
                for _, c in ipairs(row) do
                    if type(c[1]) == "string" and c[1]:find("🖼", 1, true) then
                        label = c[1]
                    end
                    if type(c[2]) == "string" and c[2]:match("^JovianKittyImg_") then
                        has_image = true
                    end
                end
            end
        end
    end
    return collapsed, label, has_image
end

local collapsed, label = inspect(img_ln)
assert_true(collapsed, "data-URI source line is collapsed (conceal_lines), no blank-wrap gap")
assert_true(
    label and label:find("pasted", 1, true) ~= nil,
    "shows a `🖼 <name>` label on the line above (got " .. tostring(label) .. ")"
)
assert_true(#transmits >= 1, "kitty_transmit was called for the data-URI image")
assert_true(transmits[1] == PNG, "the extracted base64 was transmitted verbatim")

-- After the stubbed transmit completes, a re-render should emit real Kitty
-- placeholder rows (fg-encoded image_id) in the same anchored block.
MarkdownCell.render(buf)
local _, _, has_image = inspect(img_ln)
assert_true(has_image, "after transmit, Kitty image placeholders render with the label")

-- ---------------------------- local file-path image ----------------------------
print("\n-- file-path image --")
Kitty._reset() -- clear cache so the (identical) bytes transmit again
local png_bytes = vim.base64.decode(PNG)
local pf = io.open(dir .. "/dot.png", "wb")
pf:write(png_bytes)
pf:close()

vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% [markdown] id="m2"',
    "# ![local](dot.png)",
})
vim.cmd("write")

local before = #transmits
MarkdownCell.render(buf)
vim.wait(200) -- let the deferred kitty_transmit fire

local fp_ln = 1
local fp_collapsed, fp_label = inspect(fp_ln)
assert_true(#transmits > before, "kitty_transmit was called for the file-path image")
assert_true(transmits[#transmits] == PNG, "the file's bytes were base64-transmitted")
assert_true(fp_collapsed, "file-path source line is collapsed the same way (consistent)")
assert_true(
    fp_label and fp_label:find("local", 1, true) ~= nil,
    "file-path shows the same `🖼 <name>` label (got " .. tostring(fp_label) .. ")"
)

vim.fn.delete(dir, "rf")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
