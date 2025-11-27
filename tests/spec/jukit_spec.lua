local assert = require("luassert")
local jukit = require("jukit")

describe("jukit integration", function()
    -- Setup
    local fixture_path = vim.fn.fnamemodify("tests/fixtures/test_cells.py", ":p")
    
    before_each(function()
        -- Open fixture
        vim.cmd("edit " .. fixture_path)
        -- Start plugin
        jukit.setup({})
        jukit.init_windows()
        -- Wait for windows to settle
        vim.wait(100)
    end)

    it("executes text cell", function()
        -- Move to text cell
        vim.fn.cursor(2, 1) -- Line 2 is print statement
        
        -- Send cell
        jukit.send_cell()
        
        -- Wait for output
        local found = false
        vim.wait(5000, function()
            -- Check all buffers for output
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                for _, line in ipairs(lines) do
                    if line:match("Hello from Jukit") then
                        found = true
                        return true
                    end
                end
            end
            return false
        end)
        
        assert.is_true(found, "Did not find expected text output")
    end)

    it("executes plot cell", function()
        -- Move to plot cell
        vim.fn.cursor(5, 1) -- Line 5 is import
        
        -- Send cell
        jukit.send_cell()
        
        -- Wait for image file
        local found_file = false
        vim.wait(10000, function()
            -- Check if file exists in .jukit_cache
            -- ID is cell_plot
            local f = io.open(".jukit_cache/cell_plot_0.png", "r")
            if f then
                f:close()
                found_file = true
                return true
            end
            return false
        end)
        
        assert.is_true(found_file, "Image file was not created")
    end)
end)
