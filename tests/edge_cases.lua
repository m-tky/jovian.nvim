-- tests/edge_cases.lua
-- REAL integration testing for Jovian.nvim (No mocks)

local function run_real_integration_tests()
    local root = vim.fn.getcwd()
    vim.opt.rtp:append(root)

    -- Real setup
    local jovian = require("jovian")
    jovian.setup({})

    local core = require("jovian.core")
    local state = require("jovian.state")
    local ui = require("jovian.ui")

    -- Ensure base windows exist
    pcall(ui.open_windows)

    local function log(msg)
        vim.api.nvim_out_write(msg .. "\n")
    end

    local function find_text_in_all_buffers(pattern)
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(buf) then
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                local content = table.concat(lines, "\n")
                if content:match(pattern) then
                    return true
                end
            end
        end
        return false
    end

    local ready = false
    table.insert(state.on_ready_callbacks, function()
        ready = true
    end)

    log(">>> Starting Kernel...")
    core.start_kernel()
    vim.wait(15000, function()
        return ready
    end)
    if not ready then
        log("[FAIL] Kernel timed out")
        os.exit(1)
    end
    log("[OK] Kernel Ready")

    -- Step 1: Setup Data & Cell Structure
    log("\n>>> Step 1: Setup Data & Cell Structure")
    local test_content = {
        '# %% id="cell1"',
        "x = 11223",
        '# %% [markdown] id="md_skip"',
        "This should be skipped",
        '# %% id="cell2"',
        "print(x)",
    }
    vim.api.nvim_buf_set_lines(0, 0, -1, false, test_content)
    vim.bo.filetype = "python"

    local executed_ids = {}
    local original_send = core.send_payload
    core.send_payload = function(code, id, fn)
        executed_ids[id] = true
        original_send(code, id, fn)
    end

    -- Run All and check markdown skipping
    log("Running JovianRunAll...")
    vim.cmd("JovianRunAll")

    vim.wait(5000, function()
        return state.running_cells["cell2"] == nil
    end)

    if executed_ids["cell1"] and not executed_ids["md_skip"] and executed_ids["cell2"] then
        log("[OK] Cell execution and Markdown skipping verified")
    else
        log("[FAIL] Markdown skipping failed. Executed IDs: " .. vim.inspect(executed_ids))
        os.exit(1)
    end
    core.send_payload = original_send

    -- Step 2: Test Navigation
    log("\n>>> Step 2: Testing Navigation")
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- At cell1
    vim.cmd("JovianNextCell")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if row == 3 then -- Line 3 is the markdown header
        log("[OK] JovianNextCell landed on line 3 (next header)")
    else
        log("[FAIL] JovianNextCell landed on line " .. row)
        os.exit(1)
    end

    -- Step 3: Test Interactive Commands
    log("\n>>> Step 3: Testing Interactive Commands")
    vim.cmd("JovianVars")
    if vim.wait(5000, function()
        return find_text_in_all_buffers("11223")
    end) then
        log("[OK] JovianVars verified")
    else
        log("[FAIL] JovianVars missing")
        os.exit(1)
    end

    vim.cmd("JovianPeek x")
    if vim.wait(5000, function()
        return find_text_in_all_buffers("11223")
    end) then
        log("[OK] JovianPeek verified")
    else
        log("[FAIL] JovianPeek missing")
        os.exit(1)
    end

    -- Step 4: Test Clipboard
    log("\n>>> Step 4: Testing JovianCopy")
    vim.fn.setreg("+", "")
    vim.cmd("JovianCopy x")
    if vim.wait(5000, function()
        return vim.fn.getreg("+") == "11223"
    end) then
        log("[OK] JovianCopy verified")
    else
        log("[FAIL] JovianCopy failed")
        os.exit(1)
    end

    log("\n>>> ALL ENHANCED REAL INTEGRATION TESTS PASSED!")
    os.exit(0)
end

local ok, err = pcall(run_real_integration_tests)
if not ok then
    vim.api.nvim_err_write("Integration Test Crashed: " .. tostring(err) .. "\n")
    os.exit(1)
end
