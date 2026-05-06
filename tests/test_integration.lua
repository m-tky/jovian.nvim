-- tests/test_integration.lua
-- Integration test for Jovian.nvim using a real Neovim environment and Python kernel.

local function run_full_test()
    local root = vim.fn.getcwd()
    vim.opt.rtp:append(root)

    local jovian = require("jovian")
    -- We assume the environment is already setup (e.g. via nix wrapper)
    -- If not, it will fallback to JOVIAN_PYTHON env var or "python3"
    jovian.setup({})

    local core = require("jovian.core")
    local state = require("jovian.state")
    local ui = require("jovian.ui")

    local test_logs = {}
    local function log(msg)
        table.insert(test_logs, msg)
        vim.api.nvim_out_write(msg .. "\n")
    end

    -- Mocks for UI (to capture output in logs)
    ui.append_to_repl = function(text, hl) log("[REPL] [" .. (hl or "None") .. "] " .. tostring(text)) end
    ui.append_stream_text = function(text, stream) log("[STREAM] [" .. stream .. "] " .. tostring(text)) end
    ui.set_cell_status = function(buf, id, status, text) log("[STATUS] [" .. id .. "] " .. status .. ": " .. text) end
    ui.flash_range = function(s, e) log("[UI] Flashing range: " .. s .. "-" .. e) end
    
    -- Mock window validity to allow command execution without real windows
    state.win.output = 1000
    state.win.preview = 1001
    vim.api.nvim_win_is_valid = function(win) return win >= 1000 end
    vim.api.nvim_buf_is_valid = function(buf) return buf >= 0 end

    local ready = false
    table.insert(state.on_ready_callbacks, function() ready = true end)

    log("Starting Kernel...")
    core.start_kernel()

    -- Wait for kernel to be ready
    vim.wait(15000, function() return ready end)
    if not ready then 
        log("[ERROR] Kernel failed to start within 15s!"); 
        os.exit(1) 
    end
    log("Kernel Ready!")

    -- Load demo file
    local demo_file = root .. "/examples/demo_jovian.py"
    if vim.fn.filereadable(demo_file) == 0 then
        demo_file = root .. "/demo_jovian.py"
    end
    
    vim.cmd("edit " .. demo_file)
    vim.bo.filetype = "python"

    local function run_cmd(name, args)
        log("\n>>> Command: " .. name .. (args and (" " .. args) or ""))
        local ok, err = pcall(function()
            vim.cmd(name .. (args and (" " .. args) or ""))
        end)
        if not ok then
            log("[ERROR] Command " .. name .. " failed: " .. tostring(err))
        else
            log("[OK] Command " .. name .. " finished")
        end
    end

    -- 1. Test Single Cell Execution (Verification of 'c' flag fix)
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- Move to first cell marker
    run_cmd("JovianRun")
    
    -- 2. Test Navigation
    run_cmd("JovianNextCell")
    run_cmd("JovianPrevCell")

    -- 3. Test All Cells Execution (with markdown and multiple cells)
    log("\n>>> Testing RunAll with Multiple Cells and Markdown")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        '# %% id="cell1"',
        'x = 10',
        '# %% [markdown] id="md_ignore"',
        'Markdown here',
        '# %% id="cell2"',
        'print(x)',
    })
    local executed_ids = {}
    local original_send = core.send_payload
    core.send_payload = function(code, id, fn)
        executed_ids[id] = true
        log("[TRACE] Sending Cell: " .. id)
        original_send(code, id, fn)
    end

    run_cmd("JovianRunAll")
    
    if not executed_ids["cell1"] then
        log("[ERROR] First cell 'cell1' was SKIPPED!")
        os.exit(1)
    end
    if executed_ids["md_ignore"] then
        log("[ERROR] Markdown cell 'md_ignore' was EXECUTED!")
        os.exit(1)
    end
    if not executed_ids["cell2"] then
        log("[ERROR] Second cell 'cell2' was SKIPPED!")
        os.exit(1)
    end
    log("[SUCCESS] All cells processed correctly.")
    core.send_payload = original_send
    
    -- 5. Test Tools
    run_cmd("JovianVars")
    run_cmd("JovianDoc", "print")
    run_cmd("JovianPeek", "x")

    -- 6. Test Kernel Control
    run_cmd("JovianInterrupt")
    run_cmd("JovianRestart")
    
    -- Wait a bit for async messages to settle
    vim.wait(3000)

    log("\nIntegration Test Completed Successfully!")
    
    -- Save log
    local log_file = io.open("integration_test.log", "w")
    if log_file then
        log_file:write(table.concat(test_logs, "\n"))
        log_file:close()
    end
    
    os.exit(0)
end

-- Run in protected mode
local ok, err = pcall(run_full_test)
if not ok then
    vim.api.nvim_err_write("Test Crashed: " .. tostring(err) .. "\n")
    os.exit(1)
end
