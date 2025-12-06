-- test_resize_layout.lua
-- Run with: nvim -l test_resize_layout.lua

-- 1. Setup package path to find jovian modules
local sep = package.config:sub(1,1)
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h")
package.path = package.path .. ";" .. project_root .. "/lua/?.lua" .. ";" .. project_root .. "/lua/?/init.lua"

-- 2. Mock Vim API
-- We need to patch the global 'vim' table since we are running in nvim -l
-- But nvim -l already has a 'vim' table. We should extend/mock parts of it.

local mock_wins = {}
local mock_bufs = {}
local current_win = 1000
local win_options = {}

vim.api.nvim_win_is_valid = function(win)
    return mock_wins[win] ~= nil
end

vim.api.nvim_win_get_width = function(win)
    return mock_wins[win].width
end

vim.api.nvim_win_get_height = function(win)
    return mock_wins[win].height
end

vim.api.nvim_win_set_width = function(win, width)
    print(string.format("SET_WIDTH win=%d width=%d", win, width))
    mock_wins[win].width = width
end

vim.api.nvim_win_set_height = function(win, height)
    print(string.format("SET_HEIGHT win=%d height=%d", win, height))
    mock_wins[win].height = height
end

vim.api.nvim_get_current_win = function()
    return current_win
end

-- Mock vim.wo
vim.wo = setmetatable({}, {
    __index = function(t, win)
        if not win_options[win] then win_options[win] = {} end
        return win_options[win]
    end,
    __newindex = function(t, win, val)
        -- This path is not usually taken for vim.wo[win].opt = val
        -- It's usually vim.wo[win][opt] = val, handled by __index returning a table?
        -- No, vim.wo[win] returns a userdata/table proxy.
        -- Let's just return a table that we can set fields on.
    end
})

-- Mock vim.o
vim.o.columns = 100
vim.o.lines = 50
vim.o.cmdheight = 1

-- 3. Load Modules
local Config = require("jovian.config")
local State = require("jovian.state")
local Layout = require("jovian.ui.layout")

-- 4. Setup Test Scenario
-- Scenario: Sidebar on the right with Preview (40%), Output (30%), Variables (30%)
-- Total sidebar width = 40 (default)

Config.options = {
    ui = {
        layouts = {
            {
                position = "right",
                size = 40,
                elements = {
                    { id = "preview", size = 0.4 },
                    { id = "output", size = 0.3 },
                    { id = "variables", size = 0.3 },
                }
            }
        }
    }
}

-- Create mock windows
local win_preview = 1001
local win_output = 1002
local win_vars = 1003

mock_wins[win_preview] = { width = 40, height = 10 } -- Initial random sizes
mock_wins[win_output] = { width = 40, height = 10 }
mock_wins[win_vars] = { width = 40, height = 10 }

State.win.preview = win_preview
State.win.output = win_output
State.win.variables = win_vars

-- 5. Run Resize
print("Running resize_windows...")
Layout.resize_windows()

-- 6. Verify
-- Total height available = 50 - 1 (cmdheight) = 49
-- Preview: 0.4 * 49 = 19.6 -> 19
-- Output: 0.3 * 49 = 14.7 -> 14
-- Variables: 0.3 * 49 = 14.7 -> 14
-- Total: 47 (due to floor). Remaining 2 pixels.
-- Wait, the logic sums current heights.
-- Initial heights were 10+10+10 = 30.
-- If we rely on current heights, it will resize based on 30.
-- But wait, the logic says:
-- "Instead of assuming full screen size, we sum the CURRENT dimensions of the active windows."
-- So if current sum is 30, it will redistribute 30.
-- This is correct for resizing *within* the container.
-- But if the container itself resized (e.g. terminal grew), the windows might have grown?
-- Neovim automatically resizes windows when terminal resizes.
-- So the sum of heights should be roughly the new total height.
-- Let's simulate that Neovim resized them proportionally or somehow.
-- Say total became 60.
-- Preview=20, Output=20, Vars=20.
-- Target: 0.4*60=24, 0.3*60=18, 0.3*60=18.

-- Let's set initial sizes to sum to 60
mock_wins[win_preview] = { width = 40, height = 20 }
mock_wins[win_output] = { width = 40, height = 20 }
mock_wins[win_vars] = { width = 40, height = 20 }

print("Running resize_windows with total 60...")
Layout.resize_windows()

-- Expected output:
-- SET_WIDTH ... 40 (for all)
-- SET_HEIGHT win=1001 height=24
-- SET_HEIGHT win=1002 height=18
-- SET_HEIGHT win=1003 height=18
