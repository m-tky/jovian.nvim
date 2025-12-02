-- Mock State BEFORE loading UI
package.loaded["jovian.state"] = {
    status_ns = vim.api.nvim_create_namespace("jovian_status_test"),
    win = {},
    buf = {},
    cell_status_extmarks = {} -- Add this
}
local State = require("jovian.state")

package.loaded["jovian.ui"] = nil -- Force reload to use mocked State
local UI = require("jovian.ui")
local Core = require("jovian.core")
local Config = require("jovian.config")

-- Setup buffer
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% id="1"',
    "print(1)",
    '# %% id="2"',
    "print(2)"
})

-- Add extmarks
UI.set_cell_status(buf, "1", "done", "Done")
UI.set_cell_status(buf, "2", "done", "Done")

print("--- Initial State ---")
local marks = vim.api.nvim_buf_get_extmarks(buf, State.status_ns, 0, -1, { details = true })
print("Extmarks count: " .. #marks)
for _, m in ipairs(marks) do
    print("Line " .. m[2] .. ": " .. m[4].virt_text[1][1])
end

-- Simulate deletion of first cell header (Line 0)
print("\n--- Deleting Line 0 (Header 1) ---")
vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})

-- Check immediately (should persist or move)
marks = vim.api.nvim_buf_get_extmarks(buf, State.status_ns, 0, -1, { details = true })
print("Immediate Extmarks count: " .. #marks)
for _, m in ipairs(marks) do
    print("Line " .. m[2] .. ": " .. m[4].virt_text[1][1])
end

-- Run cleanup
print("\n--- Running Cleanup ---")
UI.clean_invalid_extmarks(buf)

marks = vim.api.nvim_buf_get_extmarks(buf, State.status_ns, 0, -1, { details = true })
print("\n--- Neovim Version ---")
print(vim.inspect(vim.version()))

print("\n--- Benchmarking Cleanup (1000 cells) ---")
local bench_buf = vim.api.nvim_create_buf(false, true)
local lines = {}
for i = 1, 1000 do
    table.insert(lines, '# %% id="' .. i .. '"')
    table.insert(lines, "print(" .. i .. ")")
end
vim.api.nvim_buf_set_lines(bench_buf, 0, -1, false, lines)

-- Add 1000 extmarks
local start_add = vim.loop.hrtime()
for i = 1, 1000 do
    -- Manually set extmark to avoid overhead of set_cell_status logic for this bench
    vim.api.nvim_buf_set_extmark(bench_buf, State.status_ns, (i-1)*2, 0, {
        virt_text = { { "  Done", "String" } },
        virt_text_pos = "eol",
    })
end
local end_add = vim.loop.hrtime()
print("Added 1000 extmarks in " .. (end_add - start_add) / 1e6 .. " ms")

-- Benchmark cleanup
local start_clean = vim.loop.hrtime()
UI.clean_invalid_extmarks(bench_buf)
local end_clean = vim.loop.hrtime()
print("Cleaned 1000 extmarks in " .. (end_clean - start_clean) / 1e6 .. " ms")
