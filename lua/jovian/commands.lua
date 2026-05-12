local M = {}
local Core = require("jovian.core")
local UI = require("jovian.ui")
local Cell = require("jovian.cell")
local Hosts = require("jovian.hosts")
local Config = require("jovian.config")
local SSHConfig = require("jovian.ssh_config")
local Tunnel = require("jovian.tunnel")
local State = require("jovian.state")

-- Navigation helpers
local function goto_next_cell()
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    local total = vim.api.nvim_buf_line_count(0)
    for i = cursor + 1, total do
        local line = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1]
        if line:match("^# %%%%") then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            vim.cmd("normal! zz")
            local start_line, end_line = Cell.get_cell_range(i)
            UI.flash_range(start_line, end_line)
            return
        end
    end
    vim.notify("No next cell found", vim.log.levels.INFO)
end

local function goto_prev_cell()
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    -- Get start of current cell to ensure we jump to the *previous* cell,
    -- not the start of the current one.
    local s, _ = Cell.get_cell_range(cursor)

    for i = s - 1, 1, -1 do
        local line = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1]
        if line:match("^# %%%%") then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            vim.cmd("normal! zz")
            local start_line, end_line = Cell.get_cell_range(i)
            UI.flash_range(start_line, end_line)
            return
        end
    end
    vim.notify("No previous cell found", vim.log.levels.INFO)
end

local function insert_cell_below()
    local _, e = Cell.get_cell_range()
    local new_id = Cell.generate_id()
    local lines = { "", '# %% id="' .. new_id .. '"', "" }
    vim.api.nvim_buf_set_lines(0, e, e, false, lines)
    vim.api.nvim_win_set_cursor(0, { e + 3, 0 })
    vim.cmd("startinsert")
end

local function insert_markdown_cell_below()
    local _, e = Cell.get_cell_range()
    local new_id = Cell.generate_id()
    local lines = { "", '# %% [markdown] id="' .. new_id .. '"', "" }
    vim.api.nvim_buf_set_lines(0, e, e, false, lines)
    vim.api.nvim_win_set_cursor(0, { e + 3, 0 })
    vim.cmd("startinsert")
end

local function insert_cell_above()
    local s, _ = Cell.get_cell_range()
    local new_id = Cell.generate_id()
    local lines = { '# %% id="' .. new_id .. '"', "", "" }
    vim.api.nvim_buf_set_lines(0, s - 1, s - 1, false, lines)
    vim.api.nvim_win_set_cursor(0, { s + 1, 0 })
    vim.cmd("startinsert")
end

local function merge_cell_below()
    local _, e = Cell.get_cell_range()
    local total = vim.api.nvim_buf_line_count(0)
    if e >= total then
        return vim.notify("No cell below", vim.log.levels.WARN)
    end
    local line = vim.api.nvim_buf_get_lines(0, e, e + 1, false)[1]
    if line:match("^# %%%%") then
        -- Clear status on the header line being removed
        UI.clear_status_extmarks(0, e + 1, e + 2)
        vim.api.nvim_buf_set_lines(0, e, e + 1, false, {})
        vim.notify("Cells merged", vim.log.levels.INFO)
    else
        vim.notify("Could not find cell boundary below", vim.log.levels.WARN)
    end
end

function M.setup()
    -- Execution
    vim.api.nvim_create_user_command("JovianStart", Core.start_kernel, {})
    vim.api.nvim_create_user_command("JovianRun", Core.send_cell, {})
    vim.api.nvim_create_user_command("JovianSendSelection", Core.send_selection, { range = true })
    vim.api.nvim_create_user_command("JovianRunAll", Core.run_all_cells, {})
    vim.api.nvim_create_user_command("JovianRestart", Core.restart_kernel, {})
    vim.api.nvim_create_user_command("JovianREPL", Core.open_repl, {
        desc = "Open interactive IPython REPL connected to the running kernel",
    })

    -- Host Management
    vim.api.nvim_create_user_command("JovianAddHost", function(opts)
        local args = vim.split(opts.args, " ")

        local function process_add(name, host, python)
            if Hosts.exists(name) then
                vim.notify("Host '" .. name .. "' already exists. Use a different name.", vim.log.levels.ERROR)
                return
            end
            vim.cmd("redraw")
            local config = { type = "ssh", host = host, python = python }

            Hosts.validate_connection(config, function()
                Hosts.add_host(name, config)
            end, function(err)
                vim.notify("Validation Failed: " .. err, vim.log.levels.ERROR)
            end)
        end

        if opts.args == "" or #args < 3 then
            -- Interactive mode
            vim.ui.input({ prompt = "Host Name (e.g., my-server): " }, function(name)
                if not name or name == "" then
                    return
                end
                if Hosts.exists(name) then
                    vim.notify("Host '" .. name .. "' already exists.", vim.log.levels.ERROR)
                    return
                end
                vim.ui.input({ prompt = "SSH Host (e.g., user@1.2.3.4): " }, function(host)
                    if not host or host == "" then
                        return
                    end
                    vim.ui.input({ prompt = "Remote Python Path (e.g., /usr/bin/python3): " }, function(python)
                        if not python or python == "" then
                            return
                        end
                        process_add(name, host, python)
                    end)
                end)
            end)
        else
            process_add(args[1], args[2], args[3])
        end
    end, { nargs = "*" })

    vim.api.nvim_create_user_command("JovianAddLocal", function(opts)
        local args = vim.split(opts.args, " ")

        local function process_add(name, python)
            if Hosts.exists(name) then
                vim.notify("Host '" .. name .. "' already exists. Use a different name.", vim.log.levels.ERROR)
                return
            end
            vim.cmd("redraw")
            local config = { type = "local", python = python }

            Hosts.validate_connection(config, function()
                Hosts.add_host(name, config)
            end, function(err)
                vim.notify("Validation Failed: " .. err, vim.log.levels.ERROR)
            end)
        end

        if opts.args == "" or #args < 2 then
            -- Interactive mode
            vim.ui.input({ prompt = "Config Name (e.g., project-venv): " }, function(name)
                if not name or name == "" then
                    return
                end
                if Hosts.exists(name) then
                    vim.notify("Host '" .. name .. "' already exists.", vim.log.levels.ERROR)
                    return
                end
                vim.ui.input({
                    prompt = "Local Python Path (e.g., ./venv/bin/python): ",
                    default = Config.options.python_interpreter,
                }, function(python)
                    if not python or python == "" then
                        return
                    end
                    process_add(name, python)
                end)
            end)
        else
            process_add(args[1], args[2])
        end
    end, { nargs = "*" })

    vim.api.nvim_create_user_command("JovianUse", function(opts)
        local name = opts.args
        if name == "" then
            -- Interactive selection
            local data = Hosts.load_hosts()
            local names = vim.tbl_keys(data.configs)
            table.sort(names)
            vim.ui.select(names, { prompt = "Select Host:" }, function(selected)
                if selected then
                    Hosts.use_host(selected)
                end
            end)
        else
            Hosts.use_host(name)
        end
    end, { nargs = "?" })

    vim.api.nvim_create_user_command("JovianRemoveHost", function(opts)
        local name = opts.args
        if name == "" then
            -- Interactive selection
            local data = Hosts.load_hosts()
            local names = {}
            for host_name, _ in pairs(data.configs) do
                if host_name ~= "local_default" then
                    table.insert(names, host_name)
                end
            end
            table.sort(names)
            vim.ui.select(names, { prompt = "Remove Host:" }, function(selected)
                if selected then
                    Hosts.remove_host(selected)
                end
            end)
        else
            Hosts.remove_host(name)
        end
    end, { nargs = "?" })

    vim.api.nvim_create_user_command("JovianConnect", function()
        local hosts = SSHConfig.get_all_hosts()
        if #hosts == 0 then
            return vim.notify("No hosts found in ~/.ssh/config or tailscale", vim.log.levels.WARN)
        end

        local names = {}
        for _, h in ipairs(hosts) do
            table.insert(names, h.name)
        end
        table.sort(names)

        vim.ui.select(names, { prompt = "Select Host from ssh_config:" }, function(selected_name)
            if not selected_name then
                return
            end

            vim.ui.select({ "SSH Direct", "Auto-Tunnel (Jupyter)" }, { prompt = "Connection Mode:" }, function(mode)
                if not mode then
                    return
                end

                vim.ui.input({ prompt = "Python Path: ", default = "python3" }, function(python)
                    if not python or python == "" then
                        return
                    end

                    if mode == "SSH Direct" then
                        vim.ui.input({ prompt = "Remote Directory (Optional): ", default = "." }, function(remote_cwd)
                            local config =
                                { type = "ssh", host = selected_name, python = python, remote_cwd = remote_cwd }
                            Hosts.add_host(selected_name, config)
                            Hosts.use_host(selected_name)
                        end)
                    else
                        -- Tunnel Mode
                        vim.ui.input({ prompt = "Remote Directory (Optional): ", default = "." }, function(remote_cwd)
                            Tunnel.start(selected_name, python, remote_cwd, function()
                                -- On success, start kernel
                                Core.start_kernel()
                            end, function(err)
                                vim.notify("Tunnel Error: " .. err, vim.log.levels.ERROR)
                            end)
                        end)
                    end
                end)
            end)
        end)
    end, {})

    vim.api.nvim_create_user_command("JovianTunnelStatus", function()
        if State.tunnel_host then
            local msg = string.format(
                "Tunneled to %s (Remote PID: %s)",
                State.tunnel_host,
                State.remote_kernel_pid or "unknown"
            )
            vim.notify(msg, vim.log.levels.INFO)
        else
            vim.notify("No active tunnel", vim.log.levels.INFO)
        end
    end, {})

    vim.api.nvim_create_user_command("JovianSync", function(opts)
        local host = Config.options.ssh_host or State.tunnel_host
        if not host then
            return vim.notify("Jovian: No remote host active. Use :JovianConnect first.", vim.log.levels.ERROR)
        end

        local remote_dir = Config.options.remote_cwd or "."
        local target = opts.args ~= "" and opts.args or "."

        -- Build rsync command
        -- -a: archive, -v: verbose, -z: compress
        local cmd = { "rsync", "-avz" }

        -- Exclusions
        table.insert(cmd, "--exclude=.jovian_cache")
        table.insert(cmd, "--exclude=.git")
        table.insert(cmd, "--exclude=__pycache__")
        table.insert(cmd, "--exclude=.ipynb_checkpoints")

        -- Source (trailing slash matters for directories)
        local source = target
        if vim.fn.isdirectory(source) == 1 and not source:match("/$") then
            source = source .. "/"
        end
        table.insert(cmd, source)

        -- Destination
        local dest_dir = remote_dir
        if not dest_dir:match("/$") then
            dest_dir = dest_dir .. "/"
        end
        table.insert(cmd, string.format("%s:%s", host, dest_dir))

        vim.notify(string.format("[Jovian] Syncing %s to %s:%s...", source, host, dest_dir), vim.log.levels.INFO)

        vim.fn.jobstart(cmd, {
            stdout_buffered = true,
            on_stdout = function(_, data)
                if data and #data > 1 then
                    -- Show summary of synced files
                    vim.notify(
                        "Jovian Sync: " .. #data .. " lines of output. Last: " .. data[#data - 1],
                        vim.log.levels.INFO
                    )
                end
            end,
            on_stderr = function(_, data)
                if data and #data > 0 and data[1] ~= "" then
                    vim.notify("Jovian Sync Error: " .. table.concat(data, "\n"), vim.log.levels.ERROR)
                end
            end,
            on_exit = function(_, code)
                if code == 0 then
                    vim.notify("Jovian: Sync completed successfully.", vim.log.levels.INFO)
                else
                    vim.notify("Jovian: Sync failed with code " .. code, vim.log.levels.ERROR)
                end
            end,
        })
    end, { nargs = "?", complete = "file" })

    -- UI
    vim.api.nvim_create_user_command("JovianOpen", function()
        UI.open_windows()
    end, {})
    vim.api.nvim_create_user_command("JovianToggle", UI.toggle_windows, {})
    vim.api.nvim_create_user_command("JovianClearREPL", UI.clear_repl, {})
    vim.api.nvim_create_user_command("JovianClean", function(opts)
        if opts.bang then
            require("jovian.session").clean_orphaned_caches()
            vim.notify("Cleaned orphaned caches", vim.log.levels.INFO)
        end
        -- Always clean stale cache for current buffer as well
        require("jovian.session").clean_stale_cache(0)
    end, { bang = true })
    vim.api.nvim_create_user_command("JovianClearDiag", UI.clear_diagnostics, {})
    vim.api.nvim_create_user_command("JovianToggleVars", UI.toggle_variables_pane, {})
    vim.api.nvim_create_user_command("JovianToggleStatus", function()
        UI.toggle_status_visibility(vim.api.nvim_get_current_buf())
    end, { desc = "Jovian: Toggle cell status virtual text for current buffer" })

    -- Data & Tools
    vim.api.nvim_create_user_command("JovianVars", function()
        Core.show_variables({ force_float = true })
    end, {})
    vim.api.nvim_create_user_command("JovianView", Core.view_dataframe, { nargs = "?" })
    vim.api.nvim_create_user_command("JovianCopy", Core.copy_variable, { nargs = "?" })

    vim.api.nvim_create_user_command("JovianBackend", Core.print_backend, {})

    -- Navigation
    vim.api.nvim_create_user_command("JovianNextCell", goto_next_cell, {})
    vim.api.nvim_create_user_command("JovianPrevCell", goto_prev_cell, {})
    vim.api.nvim_create_user_command("JovianNewCellBelow", insert_cell_below, {})
    vim.api.nvim_create_user_command("JovianNewMarkdownCellBelow", insert_markdown_cell_below, {})
    vim.api.nvim_create_user_command("JovianNewCellAbove", insert_cell_above, {})
    vim.api.nvim_create_user_command("JovianMergeBelow", merge_cell_below, {})

    -- Kernel Control
    vim.api.nvim_create_user_command("JovianInterrupt", Core.interrupt_kernel, {})

    -- Plotting
    vim.api.nvim_create_user_command("JovianDoc", function(opts)
        require("jovian.core").inspect_object(opts)
    end, { nargs = "?" })
    vim.api.nvim_create_user_command("JovianPeek", function(opts)
        require("jovian.core").peek_symbol(opts)
    end, { nargs = "?" })
    vim.api.nvim_create_user_command("JovianTogglePlot", function()
        require("jovian.core").toggle_plot_view()
    end, {})

    if Config.options.inline_images then
        vim.api.nvim_create_user_command("JovianRenderImages", function()
            require("jovian.inline_images").render_for_buffer(vim.api.nvim_get_current_buf())
        end, { desc = "Jovian: Force Render Inline Notebook Images" })
    end

    -- Pinning
    vim.api.nvim_create_user_command("JovianPin", function()
        local id = Cell.get_current_cell_id(nil, false)
        if not id then
            return vim.notify("No cell found", vim.log.levels.WARN)
        end

        local md_path = Cell.get_cell_md_path(id)

        if vim.fn.filereadable(md_path) == 0 then
            return vim.notify("No output found for cell " .. id, vim.log.levels.WARN)
        end

        UI.pin_cell(md_path)
    end, {})

    vim.api.nvim_create_user_command("JovianUnpin", function()
        UI.unpin()
    end, {})

    vim.api.nvim_create_user_command("JovianTogglePin", function()
        UI.toggle_pin_window()
    end, {})

    local function cell_edit(action)
        return function()
            action()
            require("jovian.session").check_structure_change()
        end
    end

    -- Cell Editing
    vim.api.nvim_create_user_command("JovianDeleteCell", cell_edit(Cell.delete_cell), {})
    vim.api.nvim_create_user_command("JovianMoveCellUp", cell_edit(Cell.move_cell_up), {})
    vim.api.nvim_create_user_command("JovianMoveCellDown", cell_edit(Cell.move_cell_down), {})
    vim.api.nvim_create_user_command("JovianSplitCell", cell_edit(Cell.split_cell), {})

    -- Execution Control
    vim.api.nvim_create_user_command("JovianRunAndNext", function()
        require("jovian.core").run_and_next()
    end, {})
    vim.api.nvim_create_user_command("JovianRunLine", function()
        require("jovian.core").run_line()
    end, {})

    vim.api.nvim_create_user_command("JovianClearCache", function(opts)
        if opts.bang then
            require("jovian.session").clear_all_cache()
        else
            require("jovian.session").clear_current_cell_cache()
        end
    end, { bang = true })
    vim.api.nvim_create_user_command("JovianRunAbove", function()
        require("jovian.core").run_cells_above()
    end, {})
end

return M
