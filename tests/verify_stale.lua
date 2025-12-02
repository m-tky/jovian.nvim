
-- Mock Vim API
_G.vim = {
    api = {
        nvim_create_namespace = function() return 1 end,
        nvim_buf_get_lines = function() return {} end,
        nvim_buf_set_extmark = function() return 1 end,
        nvim_buf_get_extmarks = function() return {} end,
        nvim_buf_clear_namespace = function() end,
        nvim_buf_is_valid = function() return true end,
        nvim_get_current_buf = function() return 0 end,
    },
    fn = {
        expand = function() return "" end,
        json_encode = function() return "" end,
        chansend = function() end,
    },
    loop = {
        new_timer = function() return { start = function() end, close = function() end } end,
    },
    schedule = function(cb) cb() end,
    schedule_wrap = function(cb) return cb end,
    split = function(s, sep) 
        local t = {}
        for str in string.gmatch(s, "([^"..sep.."]+)") do
            table.insert(t, str)
        end
        return t
    end,
    tbl_keys = function() return {} end,
    notify = function() end,
    log = { levels = { WARN = 1, INFO = 2, ERROR = 3 } }
}

-- Load Modules
package.path = package.path .. ";./lua/?.lua"
local Utils = require("jovian.utils")
local State = require("jovian.state")
local UI = require("jovian.ui")
local Core = require("jovian.core")

-- Setup State
State.status_ns = 1
local cell_id = "test_cell"
local original_code = "print('hello')\nprint('world')"
local original_hash = Utils.get_cell_hash(original_code)
State.cell_hashes[cell_id] = original_hash
State.cell_start_line[cell_id] = 1

-- Mock Buffer Content (Modified)
local buffer_lines = {
    "# %% id=\"" .. cell_id .. "\"",
    "print('hello')",
    -- "print('world')" -- DELETED LINE
}

vim.api.nvim_buf_get_lines = function() return buffer_lines end

-- Mock Extmark (Status: Done)
vim.api.nvim_buf_get_extmarks = function(bufnr, ns, start, end_, opts)
    -- Return a mock extmark at line 0 (header)
    -- Structure: {id, row, col, details}
    local row = start[1]
    if row == 0 then
        return { { 1, 0, 0, { virt_text = { { "  Done", "String" } } } } }
    end
    return {}
end

-- Mock set_cell_status to capture result
local status_set = nil
UI.set_cell_status = function(bufnr, id, status, msg)
    print("set_cell_status called: " .. id .. " -> " .. status)
    status_set = status
end

-- Run Check
print("--- Running check_structure_change ---")
Core.check_structure_change()

if status_set == "stale" then
    print("SUCCESS: Status set to stale")
else
    print("FAILURE: Status not set to stale (was " .. tostring(status_set) .. ")")
end
