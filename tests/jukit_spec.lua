local jukit = require("jukit.init")
local assert = require("luassert")
local stub = require("luassert.stub")

describe("jukit-minimal", function()
    -- Mock image.nvim
    package.loaded["image"] = {
        from_file = function() 
            return { render = function() end } 
        end
    }

    before_each(function()
        -- Reset state if needed
        -- For simplicity, we might restart kernel or just assume clean state
    end)

    it("starts the kernel", function()
        jukit.start_kernel()
        -- Wait a bit for startup
        vim.wait(1000)
        -- We can't easily check internal job_id without exposing it, 
        -- but we can check if we can send a command without error.
        -- Or we can check stdout if we add a print in start_kernel (which we did).
        -- Ideally we'd expose is_running() in the API.
    end)

    it("executes code and captures output", function()
        -- Setup buffers
        jukit.init_windows()
        
        -- Create a cell
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "# %% id=\"test_cell\"",
            "print('hello world')"
        })
        
        -- Run it
        jukit.send_cell()
        
        -- Wait for output
        local found = false
        vim.wait(2000, function()
            -- Check output buffer
            -- We need to find the output buffer handle. 
            -- Since we don't expose it, we have to iterate buffers or check the split.
            -- jukit.init_windows creates splits.
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                for _, line in ipairs(lines) do
                    if line == "hello world" then
                        found = true
                        return true
                    end
                end
            end
            return false
        end)
        
        assert.is_true(found, "Did not find 'hello world' in any buffer")
    end)

    it("handles matplotlib images", function()
        -- Setup buffers
        jukit.init_windows()
        
        -- Create a cell that generates an image
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "# %% id=\"img_cell\"",
            "import matplotlib.pyplot as plt",
            "plt.plot([1, 2, 3])",
            "plt.show()"
        })
        
        -- Run it
        jukit.send_cell()
        
        -- Wait for image file creation
        local found_file = false
        vim.wait(5000, function()
            local f = io.open(".jukit_cache/img_cell_0.png", "r")
            if f then
                f:close()
                found_file = true
                return true
            end
            return false
        end)
        
        assert.is_true(found_file, "Image file was not created")
    end)
    
    it("injects cell id if missing", function()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "# %%",
            "print('no id')"
        })
        
        -- We need to mock the random/time to be deterministic or just check pattern
        -- But let's just run it and check if the line changed
        jukit.send_cell()
        
        local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
        assert.is_not_nil(line:match("id=\"cell_"))
    end)
end)
