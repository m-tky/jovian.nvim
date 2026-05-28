-- test_commands.lua

local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
package.path = package.path .. ";" .. project_root .. "/lua/?.lua" .. ";" .. project_root .. "/lua/?/init.lua"

for k in pairs(package.loaded) do
    if k:match("^jovian") then
        package.loaded[k] = nil
    end
end

-- ── Mocks ────────────────────────────────────────────────────────────────────

_G.vim = _G.vim or {}
vim.api = vim.api or {}
vim.fn = vim.fn or {}
vim.cmd = function() end
vim.log = { levels = { INFO = 1, ERROR = 2, WARN = 3 } }
vim.schedule = function(cb)
    cb()
end
vim.defer_fn = function(cb)
    cb()
end
vim.diagnostic = { reset = function() end, set = function() end, severity = { ERROR = 1 } }
vim.json = {
    encode = function(t)
        local parts = {}
        for k, v in pairs(t) do
            parts[#parts + 1] = k .. "=" .. tostring(v)
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end,
    decode = function()
        return {}
    end,
}

-- mutable state reset per-test
local mock_lines = {}
local cursor_pos = { 1, 0 }
local buf_edits = {}
local chan_sends = {}
local notify_msgs = {}
local kill_calls = {}

local function reset_lines(lines)
    mock_lines = vim.deepcopy and vim.deepcopy(lines)
        or (function()
            local t = {}
            for i, v in ipairs(lines) do
                t[i] = v
            end
            return t
        end)()
end

local DEFAULT_LINES = {
    '# %% id="cell1"',
    "print('hello')",
    '# %% id="cell2"',
    "x = 1",
}
reset_lines(DEFAULT_LINES)

vim.notify = function(msg)
    table.insert(notify_msgs, tostring(msg))
end

vim.loop = {
    new_timer = function()
        return { start = function() end, close = function() end }
    end,
    fs_scandir = function()
        return nil
    end,
    kill = function(pid, sig)
        table.insert(kill_calls, { pid = pid, sig = sig })
    end,
}
vim.uv = vim.loop

-- Buffer / window API
vim.api.nvim_win_is_valid = function()
    return true
end
vim.api.nvim_buf_is_valid = function()
    return true
end
vim.api.nvim_buf_is_loaded = function()
    return true
end
vim.api.nvim_buf_line_count = function()
    return #mock_lines
end
vim.api.nvim_get_current_buf = function()
    return 0
end
vim.api.nvim_get_current_win = function()
    return 100
end
vim.api.nvim_set_current_win = function() end
vim.api.nvim_set_current_buf = function() end
vim.api.nvim_buf_get_name = function()
    return "/tmp/test.py"
end

vim.api.nvim_buf_get_lines = function(_, s, e, _)
    local res = {}
    for i = s + 1, math.min(e == -1 and #mock_lines or e, #mock_lines) do
        res[#res + 1] = mock_lines[i]
    end
    return res
end

vim.api.nvim_buf_set_lines = function(_, s, e, _, lines)
    buf_edits[#buf_edits + 1] = { start = s, end_ = e, lines = lines }
    local new = {}
    for i = 1, s do
        new[#new + 1] = mock_lines[i]
    end
    for _, l in ipairs(lines) do
        new[#new + 1] = l
    end
    for i = (e == -1 and #mock_lines + 1 or e + 1), #mock_lines do
        new[#new + 1] = mock_lines[i]
    end
    mock_lines = new
end

vim.api.nvim_win_set_cursor = function(_, pos)
    cursor_pos = pos
end
vim.api.nvim_win_get_cursor = function()
    return cursor_pos
end

vim.api.nvim_chan_send = function(_, data)
    chan_sends[#chan_sends + 1] = data
end
vim.api.nvim_buf_set_extmark = function()
    return 1
end
vim.api.nvim_buf_clear_namespace = function() end
vim.api.nvim_create_namespace = function()
    return 1
end
vim.api.nvim_buf_get_extmarks = function()
    return {}
end
vim.api.nvim_buf_get_extmark_by_id = function()
    return {}
end
vim.api.nvim_buf_del_extmark = function() end
vim.api.nvim_create_user_command = function(name, cb)
    _G.commands = _G.commands or {}
    _G.commands[name] = cb
end
vim.api.nvim_create_buf = function()
    return 99
end
vim.api.nvim_buf_set_name = function() end
vim.api.nvim_create_augroup = function()
    return 1
end
vim.api.nvim_create_autocmd = function() end
vim.api.nvim_del_augroup_by_id = function() end
vim.api.nvim_list_bufs = function()
    return {}
end
vim.api.nvim_list_wins = function()
    return {}
end
vim.api.nvim_open_term = function()
    return 1
end
vim.api.nvim_open_win = function()
    return 200
end
vim.api.nvim_win_set_buf = function() end
vim.api.nvim_win_set_height = function() end
vim.api.nvim_win_set_width = function() end
vim.api.nvim_get_current_line = function()
    return mock_lines[cursor_pos[1]] or ""
end
vim.api.nvim_buf_add_highlight = function() end
vim.api.nvim_buf_set_option = function() end
vim.api.nvim_win_get_config = function()
    return {}
end

vim.bo = setmetatable({}, {
    __index = function()
        return setmetatable({}, {
            __index = function()
                return false
            end,
            __newindex = function() end,
        })
    end,
    __newindex = function() end,
})
vim.wo = setmetatable({}, {
    __index = function()
        return setmetatable({}, { __newindex = function() end })
    end,
    __newindex = function() end,
})
vim.b = setmetatable({}, {
    __index = function()
        return nil
    end,
    __newindex = function() end,
})
vim.w = setmetatable({}, {
    __index = function()
        return nil
    end,
    __newindex = function() end,
})
vim.g = {}
vim.o = { columns = 100, lines = 50, cmdheight = 1, laststatus = 2, showtabline = 0, equalalways = true }

vim.fn.line = function(e)
    return e == "." and cursor_pos[1] or 1
end
vim.fn.expand = function(e)
    if e == "%:p:h" then
        return "/tmp"
    end
    if e == "%:t" then
        return "test.py"
    end
    if e == "<cword>" then
        return "my_var"
    end
    if e == "%:p:h:h" then
        return project_root
    end
    return ""
end
vim.fn.fnamemodify = function(p, m)
    if m == ":p:h" then
        return p:match("(.*)/") or "."
    end
    if m == ":t" then
        return p:match(".*/(.*)") or p
    end
    if m == ":p" then
        return p
    end
    if m == ":p:h:h" then
        local h = p:match("(.*)/") or "."
        return h:match("(.*)/") or "."
    end
    return p
end
vim.fn.search = function(_, flags)
    flags = flags or ""
    local cur = cursor_pos[1]
    local function is_hdr(l)
        return l and l:match("^# %%")
    end
    if flags:match("b") then
        for i = cur, 1, -1 do
            if is_hdr(mock_lines[i]) then
                return i
            end
        end
    else
        for i = cur + 1, #mock_lines do
            if is_hdr(mock_lines[i]) then
                return i
            end
        end
    end
    return 0
end
vim.fn.getpos = function(m)
    if m == "'<" then
        return { 0, 2, 0, 0 }
    end
    if m == "'>" then
        return { 0, 2, 0, 0 }
    end
    return { 0, 1, 0, 0 }
end
vim.fn.filereadable = function()
    return 0
end
vim.fn.isdirectory = function()
    return 0
end
vim.fn.readdir = function()
    return {}
end
vim.fn.mkdir = function() end
vim.fn.writefile = function() end
vim.fn.readfile = function()
    return {}
end
vim.fn.delete = function() end
vim.fn.stdpath = function()
    return "/tmp"
end
vim.fn.getcwd = function()
    return "/tmp"
end
vim.fn.system = function()
    return ""
end
vim.fn.trim = function(s)
    return s:match("^%s*(.-)%s*$")
end
vim.fn.matchadd = function()
    return 1
end
vim.fn.matchdelete = function() end
vim.fn.bufnr = function()
    return -1
end
vim.fn.bufadd = function()
    return 99
end
vim.fn.bufload = function() end
vim.fn.win_findbuf = function()
    return {}
end
vim.fn.strdisplaywidth = function(s)
    return #s
end
vim.fn.executable = function()
    return 0
end
vim.fn.jobpid = function()
    return 9999
end
vim.fn.termopen = function()
    return 1
end
vim.fn.chansend = function() end
vim.fn.chanclose = function() end
vim.fn.jobstop = function() end
vim.fn.jobstart = function(_, opts)
    if opts and opts.on_exit then
        opts.on_exit(0, 0)
    end
    return 123
end

-- ── Test Runner ──────────────────────────────────────────────────────────────

_G.commands = {}
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

local function run(name, args)
    chan_sends = {}
    buf_edits = {}
    notify_msgs = {}
    kill_calls = {}
    if not _G.commands[name] then
        print("  FAIL " .. name .. " not registered")
        fails = fails + 1
        return false
    end
    local ok_, err = pcall(_G.commands[name], { args = args or "", bang = false })
    if not ok_ then
        print("  FAIL " .. name .. " crashed: " .. tostring(err))
        fails = fails + 1
        return false
    end
    return true
end

local function has_payload(pat)
    for _, p in ipairs(chan_sends) do
        if p:match(pat) then
            return true
        end
    end
end

-- ── Load ─────────────────────────────────────────────────────────────────────

-- This file mocks vim.fn.jobstart/chansend to assert that the command
-- callbacks dispatch the expected legacy-bridge payloads. The Rust path
-- (use_rust_core=true) talks to a real jovian-core binary which the mock
-- env can't satisfy, so explicitly opt back into the legacy path.
require("jovian.config").options.use_rust_core = false

require("jovian.commands").setup()
local State = require("jovian.state")

-- ── Tests ────────────────────────────────────────────────────────────────────

section("Kernel lifecycle")

run("JovianStart")
ok("JovianStart sets job_id to 123", State.job_id == 123)

State.job_id = nil
run("JovianREPL")
ok("JovianREPL warns when kernel not running", #notify_msgs > 0 and notify_msgs[1]:lower():match("start"))

section("Cell execution")

State.job_id = 123
State.win.output = 100
cursor_pos = { 2, 0 }
reset_lines(DEFAULT_LINES)

run("JovianRun")
ok("JovianRun sends execute payload", has_payload("command=execute"))
ok("JovianRun sends cell1 id", has_payload("cell_id=cell1"))

reset_lines(DEFAULT_LINES)
cursor_pos = { 2, 0 }
run("JovianRunAndNext")
ok("JovianRunAndNext sends execute payload", has_payload("command=execute"))

reset_lines(DEFAULT_LINES)
cursor_pos = { 2, 0 }
run("JovianRunLine")
ok("JovianRunLine sends execute payload", has_payload("command=execute"))

reset_lines(DEFAULT_LINES)
cursor_pos = { 2, 0 }
run("JovianRunAll")
ok("JovianRunAll sends execute for cell1", has_payload("cell_id=cell1"))
ok("JovianRunAll sends execute for cell2", has_payload("cell_id=cell2"))

section("Kernel control")

State.job_id = 123
run("JovianInterrupt")
ok("JovianInterrupt calls kill()", #kill_calls > 0)
ok("JovianInterrupt sends SIGINT (2)", kill_calls[1] and kill_calls[1].sig == 2)
ok("JovianInterrupt targets PID 9999", kill_calls[1] and kill_calls[1].pid == 9999)

section("Variables & inspection")

State.job_id = 123

run("JovianVars")
ok("JovianVars sends get_variables", has_payload("command=get_variables"))

run("JovianView", "my_df")
ok("JovianView sends view_dataframe", has_payload("command=view_dataframe"))
ok("JovianView includes variable name", has_payload("name=my_df"))

section("Cache")

run("JovianClearCache")
ok("JovianClearCache sends remove_cache", has_payload("command=remove_cache"))

section("Cell navigation")

reset_lines(DEFAULT_LINES)
cursor_pos = { 2, 0 }
local last_cursor
vim.api.nvim_win_set_cursor = function(_, pos)
    cursor_pos = pos
    last_cursor = pos
end

run("JovianNextCell")
ok("JovianNextCell moves cursor to line 3", last_cursor and last_cursor[1] == 3)

cursor_pos = { 4, 0 }
run("JovianPrevCell")
ok("JovianPrevCell moves cursor to line 1", last_cursor and last_cursor[1] == 1)

section("Cell editing")

reset_lines(DEFAULT_LINES)
cursor_pos = { 2, 0 }
run("JovianNewCellBelow")
ok("JovianNewCellBelow inserts 3 lines", buf_edits[1] and #buf_edits[1].lines == 3)
ok(
    "JovianNewCellBelow inserts cell header",
    buf_edits[1] and buf_edits[1].lines[2] and buf_edits[1].lines[2]:match("^# %%%% id=")
)

reset_lines(DEFAULT_LINES)
cursor_pos = { 2, 0 }
run("JovianNewCellAbove")
ok(
    "JovianNewCellAbove inserts cell header",
    (function()
        for _, e in ipairs(buf_edits) do
            for _, l in ipairs(e.lines) do
                if l:match("^# %%%% id=") then
                    return true
                end
            end
        end
    end)()
)

reset_lines(DEFAULT_LINES)
cursor_pos = { 2, 0 }
run("JovianDeleteCell")
ok("JovianDeleteCell removes lines", buf_edits[1] and #buf_edits[1].lines == 0)

reset_lines(DEFAULT_LINES)
cursor_pos = { 2, 0 }
run("JovianSplitCell")
ok(
    "JovianSplitCell inserts new header",
    (function()
        for _, e in ipairs(buf_edits) do
            for _, l in ipairs(e.lines) do
                if l:match("^# %%%% id=") then
                    return true
                end
            end
        end
    end)()
)

reset_lines(DEFAULT_LINES)
cursor_pos = { 3, 0 }
run("JovianMoveCellUp")
ok("JovianMoveCellUp swaps cells: cell2 first", buf_edits[1] and buf_edits[1].lines[1]:match('id="cell2"'))
ok("JovianMoveCellUp swaps cells: cell1 second", buf_edits[1] and buf_edits[1].lines[3]:match('id="cell1"'))

reset_lines(DEFAULT_LINES)
cursor_pos = { 1, 0 }
run("JovianMoveCellDown")
ok("JovianMoveCellDown swaps cells: cell2 first", buf_edits[1] and buf_edits[1].lines[1]:match('id="cell2"'))
ok("JovianMoveCellDown swaps cells: cell1 second", buf_edits[1] and buf_edits[1].lines[3]:match('id="cell1"'))

reset_lines(DEFAULT_LINES)
cursor_pos = { 2, 0 }
run("JovianMergeBelow")
ok("JovianMergeBelow deletes cell header", buf_edits[1] and #buf_edits[1].lines == 0)

-- ── Result ───────────────────────────────────────────────────────────────────

print(string.format("\n%d test(s) failed", fails))
if fails > 0 then
    os.exit(1)
else
    print("All tests passed!")
    os.exit(0)
end
