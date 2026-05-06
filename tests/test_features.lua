-- tests/test_features.lua
-- REAL integration testing for new features (No mocks)

local function run_tests()
    local root = vim.fn.getcwd()
    vim.opt.rtp:append(root)

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
                if content:find(pattern, 1, true) then
                    return true, buf
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
        log("[FAIL] Kernel timeout")
        os.exit(1)
    end
    log("[OK] Kernel Ready")

    -- Test Feature 1: DataFrame Pagination
    log("\n>>> Testing Feature 1: DataFrame Pagination")
    local df_code = "import pandas as pd; df = pd.DataFrame({'a': range(200)})"
    core.send_payload(df_code, "df_setup", "test.py")
    vim.wait(5000, function()
        return state.running_cells["df_setup"] == nil
    end)

    vim.cmd("JovianView df")
    local ok, df_buf, df_win
    vim.wait(5000, function()
        -- Check for help text which IS in the buffer
        ok, df_buf = find_text_in_all_buffers("PageUp/Down: Prev/Next")
        if ok then
            -- Find the window showing this buffer
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_buf(win) == df_buf then
                    local config = vim.api.nvim_win_get_config(win)
                    -- config.title is a table in Neovim 0.9+
                    if config.title and config.title[1] and config.title[1][1]:find("df [1-50 / 200]", 1, true) then
                        df_win = win
                        return true
                    end
                end
            end
        end
        return false
    end)

    if ok then
        log("[OK] DataFrame first page verified (50 rows + title)")
    else
        log("[FAIL] DataFrame first page missing or title incorrect")
        os.exit(1)
    end

    -- Test paging
    log("Testing PageDown (direct call)...")
    require("jovian.core").view_dataframe_page("df", 50, 50)

    local paging_ok = vim.wait(5000, function()
        local config = vim.api.nvim_win_get_config(df_win)
        -- In headless mode/some environments, config.title might be a string or a table of chunks
        local title_str = ""
        if type(config.title) == "string" then
            title_str = config.title
        elseif type(config.title) == "table" and config.title[1] then
            title_str = config.title[1][1]
        end
        return title_str:find("df [51-100 / 200]", 1, true)
    end)

    if paging_ok then
        log("[OK] DataFrame PageDown verified (Title updated)")
    else
        local config = vim.api.nvim_win_get_config(df_win)
        log("[FAIL] DataFrame PageDown failed to update title. Current config: " .. vim.inspect(config))
        os.exit(1)
    end

    -- Test Feature 2: Virtual Text Toggle
    log("\n>>> Testing Feature 2: Virtual Text Toggle")
    local bufnr = vim.api.nvim_get_current_buf()
    local cell_id = "test_toggle"

    -- MUST have a header line with the ID for set_cell_status to work
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '# %% id="' .. cell_id .. '"', "print('hi')" })

    core.send_payload("print('hi')", cell_id, "test.py")
    vim.wait(5000, function()
        return state.running_cells[cell_id] == nil
    end)

    local function has_status()
        -- clean_invalid_extmarks might be needed if lines changed, but here we just check
        local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, state.status_ns, 0, -1, { details = true })
        for _, m in ipairs(extmarks) do
            local vt = m[4].virt_text
            if vt and vt[1] and vt[1][1]:match("Done") then
                return true
            end
        end
        return false
    end

    if has_status() then
        log("[OK] Status virtual text present")
    else
        log("[FAIL] Status virtual text missing")
        os.exit(1)
    end

    log("Toggling status hidden...")
    vim.cmd("JovianToggleStatus")
    if not has_status() then
        log("[OK] Status virtual text hidden")
    else
        log("[FAIL] Status virtual text still visible after toggle")
        os.exit(1)
    end

    log("Toggling status shown...")
    vim.cmd("JovianToggleStatus")
    if has_status() then
        log("[OK] Status virtual text restored")
    else
        log("[FAIL] Status virtual text failed to restore")
        os.exit(1)
    end

    -- Test Feature 3: SSH Config Parser
    log("\n>>> Testing Feature 3: SSH Config Parser")
    local ssh_config_path = "/tmp/jovian_ssh_test"
    local ssh_content = {
        "Host test-host",
        "  HostName 1.2.3.4",
        "  User myuser",
        "Host another-host",
        "  Port 2222",
    }
    vim.fn.writefile(ssh_content, ssh_config_path)

    local ssh_config = require("jovian.ssh_config")
    local hosts = ssh_config.parse(ssh_config_path)

    if #hosts == 2 and hosts[1].name == "test-host" and hosts[1].hostname == "1.2.3.4" and hosts[2].port == 2222 then
        log("[OK] SSH Config Parser verified")
    else
        log("[FAIL] SSH Config Parser incorrect: " .. vim.inspect(hosts))
        os.exit(1)
    end

    log("\n>>> ALL NEW FEATURE TESTS PASSED!")
    os.exit(0)
end

local ok, err = pcall(run_tests)
if not ok then
    vim.api.nvim_err_write("Test Crashed: " .. tostring(err) .. "\n")
    os.exit(1)
end
