-- test_cell.lua — unit tests for lua/jovian/cell.lua
-- Uses real Neovim buffers (nvim -l provides full vim API).

local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
package.path = package.path .. ";" .. project_root .. "/lua/?.lua" .. ";" .. project_root .. "/lua/?/init.lua"

for k in pairs(package.loaded) do
    if k:match("^jovian") then
        package.loaded[k] = nil
    end
end

-- cell.lua only needs jovian.ui for status extmarks; stub it out.
package.loaded["jovian.ui"] = {
    clear_status_extmarks = function() end,
    flash_range = function() end,
    set_cell_status = function() end,
}

local Cell = require("jovian.cell")

-- ── Test runner ───────────────────────────────────────────────────────────────

local fails = 0
local function section(name)
    print("\n-- " .. name .. " --")
end
local function ok(desc, cond)
    if cond then
        print("  PASS " .. desc)
    else
        print("  FAIL " .. desc)
        fails = fails + 1
    end
end

-- Create a scratch buffer, set its lines, and make it current.
local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buf)
    return buf
end

-- ── get_cell_hash ────────────────────────────────────────────────────────────

section("get_cell_hash")

local h = Cell.get_cell_hash
local base = h("x = 1\ny = 2")

ok("same code → same hash", base == h("x = 1\ny = 2"))
ok("blank lines are ignored", base == h("x = 1\n\ny = 2"))
ok("whitespace-only lines ignored", base == h("x = 1\n   \ny = 2"))
ok("inline comments stripped", base == h("x = 1  # note\ny = 2"))
ok("different code → different hash", base ~= h("x = 99\ny = 2"))

local empty = h("")
ok("empty string is consistent", empty == h(""))
ok("whitespace-only normalises to empty", empty == h("  \n\n  "))

-- ── generate_id ──────────────────────────────────────────────────────────────

section("generate_id")

local id = Cell.generate_id()
ok("ID is 12 characters", #id == 12)
ok("ID uses allowed charset", id:match("^[%w%-_]+$") ~= nil)

-- Collision avoidance: generate 60 unique IDs against an accumulating set.
local seen = {}
local collisions = 0
for _ = 1, 60 do
    local new = Cell.generate_id(seen)
    if seen[new] then
        collisions = collisions + 1
    end
    seen[new] = true
end
ok("no collisions across 60 generated IDs", collisions == 0)

-- ── get_all_ids ───────────────────────────────────────────────────────────────

section("get_all_ids")

make_buf({
    '# %% id="alpha1"',
    "x = 1",
    '# %% id="beta22"',
    "y = 2",
    "z = 3", -- no ID
})

local ids = Cell.get_all_ids(0)
ok("finds first ID", ids["alpha1"] == true)
ok("finds second ID", ids["beta22"] == true)
ok("correct count (2 IDs)", vim.tbl_count(ids) == 2)
ok("non-header line ignored", ids["z"] == nil)

-- ── fix_duplicate_ids ────────────────────────────────────────────────────────

section("fix_duplicate_ids")

make_buf({
    '# %% id="dup"',
    "x = 1",
    '# %% id="dup"', -- duplicate
    "y = 2",
    '# %% id="unique"',
    "z = 3",
})

Cell.fix_duplicate_ids(0)
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local id_a = lines[1]:match('id="([%w%-_]+)"')
local id_b = lines[3]:match('id="([%w%-_]+)"')
local id_c = lines[5]:match('id="([%w%-_]+)"')

ok("first ID unchanged", id_a == "dup")
ok("duplicate renamed", id_b ~= "dup")
ok("renamed ID is 12 chars", id_b and #id_b == 12)
ok("third ID untouched", id_c == "unique")
ok("all three IDs now unique", id_a ~= id_b and id_b ~= id_c and id_a ~= id_c)

-- ── get_cell_range ────────────────────────────────────────────────────────────

section("get_cell_range")

make_buf({
    '# %% id="c1"', -- 1
    "line a", -- 2
    "line b", -- 3
    '# %% id="c2"', -- 4
    "line c", -- 5
})

vim.api.nvim_win_set_cursor(0, { 2, 0 })
local s, e = Cell.get_cell_range()
ok("start of cell1 is line 1", s == 1)
ok("end of cell1 is line 3", e == 3)

vim.api.nvim_win_set_cursor(0, { 5, 0 })
local s2, e2 = Cell.get_cell_range()
ok("start of last cell is line 4", s2 == 4)
ok("last cell extends to end", e2 == 5)

-- Called with explicit lnum (cursor must not move permanently)
vim.api.nvim_win_set_cursor(0, { 5, 0 })
local s3, _ = Cell.get_cell_range(2)
ok("explicit lnum finds correct start", s3 == 1)
ok("cursor restored after lnum call", vim.api.nvim_win_get_cursor(0)[1] == 5)

-- ── delete_cell ───────────────────────────────────────────────────────────────

section("delete_cell")

make_buf({
    '# %% id="c1"',
    "print('hello')",
    '# %% id="c2"',
    "x = 1",
})
vim.api.nvim_win_set_cursor(0, { 2, 0 })
Cell.delete_cell()
local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
ok("cell1 lines removed", #after == 2)
ok("cell2 header still present", after[1] and after[1]:match('id="c2"'))

-- ── move_cell_up / move_cell_down ─────────────────────────────────────────────

section("move_cell_up")

make_buf({
    '# %% id="c1"',
    "x = 1",
    '# %% id="c2"',
    "y = 2",
})
vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- on c2 header
Cell.move_cell_up()
local up = vim.api.nvim_buf_get_lines(0, 0, -1, false)
ok("c2 moved to first position", up[1] and up[1]:match('id="c2"'))
ok("c1 moved to second position", up[3] and up[3]:match('id="c1"'))

section("move_cell_down")

make_buf({
    '# %% id="c1"',
    "x = 1",
    '# %% id="c2"',
    "y = 2",
})
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on c1 header
Cell.move_cell_down()
local down = vim.api.nvim_buf_get_lines(0, 0, -1, false)
ok("c2 moved to first position", down[1] and down[1]:match('id="c2"'))
ok("c1 moved to second position", down[3] and down[3]:match('id="c1"'))

-- ── split_cell ────────────────────────────────────────────────────────────────

section("split_cell")

make_buf({
    '# %% id="orig"',
    "x = 1",
    "y = 2",
})
vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- split after "x = 1"
Cell.split_cell()
local split = vim.api.nvim_buf_get_lines(0, 0, -1, false)
ok("buffer grows by 2 lines", #split == 5)
ok("original header intact", split[1]:match('id="orig"'))
ok(
    "new header inserted",
    (function()
        for _, l in ipairs(split) do
            if l:match("^# %%%%") and not l:match('id="orig"') then
                return true
            end
        end
    end)()
)

-- ── ensure_cell_id ───────────────────────────────────────────────────────────

section("ensure_cell_id")

make_buf({ "# %%", "code here" }) -- header without id

local new_id = Cell.ensure_cell_id(1, "# %%")
ok("ensure_cell_id generates an id", new_id and #new_id == 12)

local updated = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
ok("ensure_cell_id writes id to buffer", updated and updated:find('id="' .. new_id .. '"', 1, true))

-- Calling again returns the same id (idempotent)
local same_id = Cell.ensure_cell_id(1, updated)
ok("ensure_cell_id is idempotent", same_id == new_id)

-- ── Result ────────────────────────────────────────────────────────────────────

print(string.format("\n%d test(s) failed", fails))
if fails > 0 then
    os.exit(1)
else
    print("All tests passed!")
    os.exit(0)
end
