local M = {}
local Core = require("jovian.core")
local UI = require("jovian.ui")
local Cell = require("jovian.cell")
local Hosts = require("jovian.hosts")
local Config = require("jovian.config")
local SSHConfig = require("jovian.ssh_config")
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

local function merge_cell_above()
    local s, _ = Cell.get_cell_range()
    if s <= 1 then
        return vim.notify("No cell above", vim.log.levels.WARN)
    end
    -- s is the line of THIS cell's header. Drop it; the cell content
    -- now flows into the previous cell.
    local hdr = vim.api.nvim_buf_get_lines(0, s - 1, s, false)[1]
    if not hdr or not hdr:match("^# %%%%") then
        return vim.notify("Could not find cell header to drop", vim.log.levels.WARN)
    end
    UI.clear_status_extmarks(0, s, s + 1)
    vim.api.nvim_buf_set_lines(0, s - 1, s, false, {})
    vim.notify("Cells merged", vim.log.levels.INFO)
end

function M.setup()
    -- Execution
    vim.api.nvim_create_user_command("JovianStart", Core.start_kernel, {})
    vim.api.nvim_create_user_command("JovianRun", Core.send_cell, {})
    vim.api.nvim_create_user_command("JovianSendSelection", Core.send_selection, { range = true })
    vim.api.nvim_create_user_command("JovianRunAll", Core.run_all_cells, {})
    vim.api.nvim_create_user_command("JovianRestart", Core.restart_kernel, {})
    vim.api.nvim_create_user_command("JovianREPL", function()
        require("jovian.core").eval_repl()
    end, {
        desc = "Continuous eval session in the kernel (replaces jupyter console)",
    })

    -- Pick a python interpreter or a registered Jupyter kernelspec
    -- interactively. Lists every detected python (with an [ipykernel] tag
    -- when usable) plus every kernel.json discovered by jovian-core, then
    -- restarts the running kernel so the new choice takes effect.
    vim.api.nvim_create_user_command("JovianPickPython", function()
        local Python = require("jovian.python")
        local candidates = Python.candidates()
        Python.list_kernelspecs(function(specs, err)
            specs = specs or {}
            if err then
                vim.notify("kernelspec discovery failed: " .. tostring(err), vim.log.levels.WARN)
            end

            local entries = {}
            for _, c in ipairs(candidates) do
                local usable = Python.has_ipykernel(c.path)
                local tag = usable and "[ipykernel]" or "[missing ipykernel]"
                table.insert(entries, {
                    label = ("%s  %s  %s"):format(tag, c.source, c.path),
                    kind = "python",
                    path = c.path,
                    usable = usable,
                })
            end
            for _, s in ipairs(specs) do
                table.insert(entries, {
                    label = ("[kernelspec] %s  (%s)"):format(s.name, s.display_name or s.name),
                    kind = "kernelspec",
                    name = s.name,
                    usable = true,
                })
            end

            if #entries == 0 then
                vim.notify("No python or kernelspec found.", vim.log.levels.WARN)
                return
            end

            vim.ui.select(entries, {
                prompt = "Jovian: pick python / kernel",
                format_item = function(e)
                    return e.label
                end,
            }, function(choice)
                if not choice then
                    return
                end
                if choice.kind == "python" then
                    if not choice.usable then
                        vim.notify(
                            ("'%s' has no ipykernel — pick a usable entry."):format(choice.path),
                            vim.log.levels.ERROR
                        )
                        return
                    end
                    Config.options.python_interpreter = choice.path
                    Config.configured_python = choice.path
                    Config.options.kernel_name = nil
                    vim.notify("jovian: python set to " .. choice.path, vim.log.levels.INFO)
                else
                    Config.options.kernel_name = choice.name
                    Config.options.python_interpreter = nil
                    Config.configured_python = nil
                    vim.notify("jovian: kernelspec set to " .. choice.name, vim.log.levels.INFO)
                end

                if State.rust_active then
                    Core.restart_kernel()
                end
            end)
        end)
    end, { desc = "Pick the python interpreter or Jupyter kernelspec to use" })

    -- Host Management
    vim.api.nvim_create_user_command("JovianAddHost", function(opts)
        local args = vim.split(opts.args, " ")

        local function process_add(name, host, python)
            if Hosts.exists(name) then
                vim.notify("Host '" .. name .. "' already exists. Use a different name.", vim.log.levels.ERROR)
                return
            end
            -- No pre-flight validation: the Rust core's start_kernel does
            -- the real SSH + python probe on first :JovianRun, and failure
            -- surfaces as a kernel_died notification with the actual error.
            -- Validating here used to add 200ms-5s to every :JovianAddHost
            -- and could disagree with what the actual launch does later.
            Hosts.add_host(name, { type = "ssh", host = host, python = python })
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
            Hosts.add_host(name, { type = "local", python = python })
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

            -- jovian-core owns the SSH tunnel + remote kernel launch, so
            -- connecting is just: record the remote python/cwd, activate the
            -- host, and let the next :JovianRun start the kernel there.
            vim.ui.input({ prompt = "Remote Python: ", default = "python3" }, function(python)
                if not python or python == "" then
                    return
                end
                vim.ui.input({ prompt = "Remote Directory (Optional): ", default = "." }, function(remote_cwd)
                    local config = { type = "ssh", host = selected_name, python = python, remote_cwd = remote_cwd }
                    Hosts.add_host(selected_name, config)
                    Hosts.use_host(selected_name)
                    vim.notify(
                        ("jovian: remote host '%s' active — next :JovianRun starts the kernel there"):format(
                            selected_name
                        ),
                        vim.log.levels.INFO
                    )
                end)
            end)
        end)
    end, {})

    vim.api.nvim_create_user_command("JovianTunnelStatus", function()
        local host = Config.options.ssh_host
        if host and host ~= "" then
            local running = State.rust_active and "running" or "not started"
            vim.notify(("jovian: remote host '%s' via SSH (kernel %s)"):format(host, running), vim.log.levels.INFO)
        else
            vim.notify("jovian: no remote host active (local kernel)", vim.log.levels.INFO)
        end
    end, {})

    vim.api.nvim_create_user_command("JovianSync", function(opts)
        local host = Config.options.ssh_host
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
    vim.api.nvim_create_user_command("JovianToggleOutput", UI.toggle_output_window, {
        desc = "Jovian: Toggle the Output (REPL) window",
    })
    vim.api.nvim_create_user_command("JovianEval", function(opts)
        require("jovian.core").eval(opts.args)
    end, {
        nargs = "?",
        desc = "Jovian: Quick-eval code in the kernel (not recorded in history)",
    })
    vim.api.nvim_create_user_command("JovianToggleStatus", function()
        UI.toggle_status_visibility(vim.api.nvim_get_current_buf())
    end, { desc = "Jovian: Toggle cell status virtual text for current buffer" })

    -- Phase 2 visual toggles. These flip the config flag, re-render
    -- immediately, AND bump window conceallevel so concealed prefixes
    -- (`# ` on markdown lines, `# %% id="..."` on cell headers) actually
    -- vanish at toggle-on time. Without the conceallevel bump the
    -- conceal extmark is a no-op.
    local function ensure_conceallevel()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.bo[buf].filetype == "python" then
                local cur = vim.api.nvim_get_option_value("conceallevel", { win = win })
                if cur < 2 then
                    vim.api.nvim_set_option_value("conceallevel", 2, { win = win })
                end
                vim.api.nvim_set_option_value("concealcursor", "", { win = win })
            end
        end
    end

    vim.api.nvim_create_user_command("JovianToggleCellFrame", function()
        Config.options.cell_frame = not Config.options.cell_frame
        local CellFrame = require("jovian.ui.cell_frame")
        if Config.options.cell_frame then
            ensure_conceallevel()
        end
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "python" then
                if Config.options.cell_frame then
                    local wins = vim.fn.win_findbuf(buf)
                    CellFrame.render(buf, wins[1])
                else
                    CellFrame.clear(buf)
                end
            end
        end
        vim.notify("Cell frame: " .. (Config.options.cell_frame and "ON" or "OFF"), vim.log.levels.INFO)
    end, { desc = "Jovian: Toggle cell card frame" })

    vim.api.nvim_create_user_command("JovianToggleMarkdownStyle", function()
        Config.options.markdown_cell_style = not Config.options.markdown_cell_style
        local MarkdownCell = require("jovian.ui.markdown_cell")
        if Config.options.markdown_cell_style then
            ensure_conceallevel()
        end
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "python" then
                if Config.options.markdown_cell_style then
                    MarkdownCell.render(buf)
                else
                    MarkdownCell.clear(buf)
                end
            end
        end
        vim.notify(
            "Markdown cell styling: " .. (Config.options.markdown_cell_style and "ON" or "OFF"),
            vim.log.levels.INFO
        )
    end, { desc = "Jovian: Toggle markdown cell styling" })

    -- Data & Tools — only Vars + View are kept. Doc/Peek (LSP duplicates),
    -- Backend (one-line workaround), TogglePlot (Phase 3 makes inline the
    -- only mode), and Copy (low-value niche) were deleted; pylsp / pyright
    -- hover and `:JovianRun` on a one-off cell cover those needs.
    vim.api.nvim_create_user_command("JovianVars", function()
        Core.show_variables({ force_float = true })
    end, {})
    vim.api.nvim_create_user_command("JovianView", Core.view_dataframe, { nargs = "?" })

    -- Navigation
    vim.api.nvim_create_user_command("JovianNextCell", goto_next_cell, {})
    vim.api.nvim_create_user_command("JovianPrevCell", goto_prev_cell, {})
    vim.api.nvim_create_user_command("JovianNewCellBelow", insert_cell_below, {})
    vim.api.nvim_create_user_command("JovianNewMarkdownCellBelow", insert_markdown_cell_below, {})
    vim.api.nvim_create_user_command("JovianNewCellAbove", insert_cell_above, {})
    vim.api.nvim_create_user_command("JovianMergeBelow", merge_cell_below, {})

    -- Kernel Control
    vim.api.nvim_create_user_command("JovianInterrupt", Core.interrupt_kernel, {})

    -- Diagnostic: probe the Kitty image pipeline by transmitting a 1x1
    -- PNG and reporting whether the round-trip succeeds. Surfaces the
    -- exact RPC error so users can see "kitty_attach not called" vs a
    -- terminal that just doesn't support graphics.
    vim.api.nvim_create_user_command("JovianDebugImages", function()
        local BackendCore = require("jovian.backend.core")
        local client = BackendCore.client() or BackendCore.ensure()
        -- 1x1 transparent PNG, base64-encoded
        local one_px = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
        vim.notify("jovian: probing kitty pipeline...", vim.log.levels.INFO)
        BackendCore.on_kitty_ready(function(ok, attach_err)
            if not ok then
                vim.notify(
                    "jovian image pipeline FAILED at kitty_attach: "
                        .. (attach_err or "unknown")
                        .. "\n  TERM="
                        .. (vim.env.TERM or "?")
                        .. " TERM_PROGRAM="
                        .. (vim.env.TERM_PROGRAM or "?")
                        .. " TMUX="
                        .. (vim.env.TMUX and "set" or "unset"),
                    vim.log.levels.ERROR
                )
                return
            end
            client:request("kitty_transmit", { png_b64 = one_px }, function(err, result)
                vim.schedule(function()
                    if err then
                        vim.notify(
                            "jovian image pipeline FAILED at kitty_transmit: "
                                .. err
                                .. "\n  TERM="
                                .. (vim.env.TERM or "?")
                                .. " TERM_PROGRAM="
                                .. (vim.env.TERM_PROGRAM or "?")
                                .. " TMUX="
                                .. (vim.env.TMUX and "set" or "unset"),
                            vim.log.levels.ERROR
                        )
                    else
                        vim.notify(
                            "jovian image pipeline OK (image_id=" .. tostring(result and result.image_id) .. ")",
                            vim.log.levels.INFO
                        )
                    end
                end)
            end)
        end)
    end, { desc = "Jovian: probe the Kitty image transmit RPC" })

    -- Pinning
    vim.api.nvim_create_user_command("JovianPin", function()
        local id = Cell.get_current_cell_id(nil, false)
        if not id then
            return vim.notify("No cell found", vim.log.levels.WARN)
        end
        local src = vim.api.nvim_buf_get_name(0)
        if src == "" then
            return vim.notify("Save the buffer first; pin needs a source path", vim.log.levels.WARN)
        end
        UI.pin_cell(src, id)
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
    vim.api.nvim_create_user_command("JovianMergeAbove", cell_edit(merge_cell_above), {})

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

    -- Tag-based execution. Tags are declared in cell headers via
    -- `# %% id="..." tags=["slow","skip"]`. Both commands accept one or
    -- more space-separated tags, e.g. `:JovianRunAllExcept slow skip`.
    local function parse_tag_args(args)
        local set = {}
        for tag in (args or ""):gmatch("%S+") do
            set[tag] = true
        end
        return set
    end
    vim.api.nvim_create_user_command("JovianRunOnly", function(opts)
        local set = parse_tag_args(opts.args)
        if next(set) == nil then
            return vim.notify("Usage: :JovianRunOnly <tag> [<tag> ...]", vim.log.levels.WARN)
        end
        require("jovian.core").run_only_tagged(set)
    end, { nargs = "+", desc = "Run only cells with any of the given tags" })

    vim.api.nvim_create_user_command("JovianRunAllExcept", function(opts)
        local set = parse_tag_args(opts.args)
        if next(set) == nil then
            return vim.notify("Usage: :JovianRunAllExcept <tag> [<tag> ...]", vim.log.levels.WARN)
        end
        require("jovian.core").run_all_except_tagged(set)
    end, { nargs = "+", desc = "Run all cells except those tagged with any of the given tags" })

    -- Restart kernel, then run every cell once it's ready. Standard "I
    -- changed something fundamental, redo the notebook from scratch"
    -- workflow from JupyterLab / VS Code.
    vim.api.nvim_create_user_command("JovianRestartAndRunAll", function()
        local rust = require("jovian.backend.rust_kernel")
        UI.append_to_repl("[Kernel Restarting...]", "WarningMsg")
        UI.clear_status_extmarks(0)
        rust.restart(function()
            Core.run_all_cells()
        end)
    end, { desc = "Restart the kernel and run every cell" })

    -- :JovianInspect — runs the kernel's inspect_request on the symbol
    -- under the cursor (or :JovianInspect <expr>) and shows the rendered
    -- docstring in a float. Mirrors `?foo` from a Jupyter notebook; pylsp
    -- hover gives you static signatures, inspect gives you the runtime
    -- object's docstring as the kernel sees it.
    vim.api.nvim_create_user_command("JovianInspect", function(opts)
        local BackendCore = require("jovian.backend.core")
        local client = BackendCore.client()
        if not client or not State.rust_session_id then
            return vim.notify("Jovian: kernel not started", vim.log.levels.WARN)
        end
        local code, cursor_pos
        if opts.args ~= "" then
            code = opts.args
            cursor_pos = #code
        else
            code = vim.api.nvim_get_current_line()
            cursor_pos = vim.api.nvim_win_get_cursor(0)[2]
        end
        client:request("inspect", {
            session_id = State.rust_session_id,
            code = code,
            cursor_pos = cursor_pos,
            detail_level = 0,
        }, function(err, result)
            vim.schedule(function()
                if err then
                    vim.notify("inspect failed: " .. err, vim.log.levels.ERROR)
                    return
                end
                if not result or not result.found then
                    vim.notify("No information for symbol under cursor", vim.log.levels.INFO)
                    return
                end
                local text = (result.data or {})["text/plain"] or ""
                if type(text) ~= "string" or text == "" then
                    vim.notify("Empty inspect result", vim.log.levels.INFO)
                    return
                end
                local strip_ansi = require("jovian.ui.shared").strip_ansi
                local lines = vim.split(strip_ansi(text), "\n", { plain = true })
                local buf = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
                vim.bo[buf].buftype = "nofile"
                vim.bo[buf].modifiable = false
                vim.bo[buf].filetype = "rst"
                local Windows = require("jovian.ui.windows")
                Windows.create_float_window(buf, "Inspect", {
                    width = math.min(100, vim.o.columns - 4),
                    height = math.min(#lines + 2, math.floor(vim.o.lines * 0.6)),
                })
            end)
        end)
    end, { nargs = "?", desc = "Jovian: inspect the symbol under the cursor (Jupyter's ?foo)" })
end

return M
