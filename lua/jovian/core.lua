local M = {}
local State = require("jovian.state")
local Config = require("jovian.config")
local UI = require("jovian.ui")
local Cell = require("jovian.cell")

local function is_window_open()
    return State.win.output and vim.api.nvim_win_is_valid(State.win.output)
end

-- Host Management
local Hosts = require("jovian.hosts")

local Handlers = require("jovian.handlers")
local Messenger = nil
local Zmq = nil

local function get_messenger()
    Messenger = Messenger or require("jovian.backend.messenger")
    return Messenger
end

local function get_zmq()
    Zmq = Zmq or require("jovian.backend.zmq")
    return Zmq
end

local function process_output_data(data, buffer_key)
    if not data or #data == 0 then
        return
    end

    local first = data[1] or ""
    State[buffer_key] = (State[buffer_key] or "") .. first

    if #data > 1 then
        local line = State[buffer_key]
        if line ~= "" then
            local ok, msg = pcall(vim.json and vim.json.decode or vim.fn.json_decode, line)
            if ok and msg then
                vim.schedule(function()
                    local handler_name = "handle_" .. (msg.type or "")
                    if Handlers[handler_name] then
                        local h_ok, h_err = pcall(Handlers[handler_name], msg)
                        if not h_ok then
                            UI.append_to_repl("[Handler Error: " .. tostring(h_err) .. "]", "ErrorMsg")
                        end
                    end
                end)
            else
                vim.schedule(function()
                    UI.append_to_repl(line, "Comment")
                end)
            end
        end

        for i = 2, #data - 1 do
            local l = data[i]
            if l ~= "" then
                local ok, msg = pcall(vim.json and vim.json.decode or vim.fn.json_decode, l)
                if ok and msg then
                    vim.schedule(function()
                        local handler_name = "handle_" .. (msg.type or "")
                        if Handlers[handler_name] then
                            local h_ok, h_err = pcall(Handlers[handler_name], msg)
                            if not h_ok then
                                UI.append_to_repl("[Handler Error: " .. tostring(h_err) .. "]", "ErrorMsg")
                            end
                        end
                    end)
                else
                    vim.schedule(function()
                        UI.append_to_repl(l, "Comment")
                    end)
                end
            end
        end

        State[buffer_key] = data[#data]
    end
end

local function on_stdout(_chan_id, data, _name)
    process_output_data(data, "stdout_buffer")
end

local function on_stderr(_chan_id, data, _name)
    process_output_data(data, "stderr_buffer")
end

function M._prepare_kernel_command(script_path)
    local cmd
    if Config.options.connection_file then
        -- Connect to existing kernel via connection file
        cmd = vim.split(Config.options.python_interpreter, " ")
        table.insert(cmd, script_path)
        table.insert(cmd, "--connection-file")
        table.insert(cmd, Config.options.connection_file)
        UI.append_to_repl("[Jovian] Connecting to kernel via: " .. Config.options.connection_file, "Special")
    elseif Config.options.ssh_host then
        local host = Config.options.ssh_host
        local remote_python = Config.options.ssh_python
        local remote_cwd = Config.options.remote_cwd or "."
        local remote_cmd =
            string.format("cd %s && %s -u /tmp/jovian_backend/kernel_bridge.py", remote_cwd, remote_python)
        cmd = { "ssh", host, remote_cmd }
        UI.append_to_repl("[Jovian] Connecting to remote: " .. host, "Special")
    else
        -- Local execution
        cmd = vim.split(Config.options.python_interpreter, " ")
        table.insert(cmd, script_path)
    end
    return cmd
end

function M.sync_backend(host, backend_dir, on_success, on_error)
    -- Calculate local hash
    local hasher = "sha256sum"
    if vim.fn.executable("sha256sum") == 0 and vim.fn.executable("shasum") == 1 then
        hasher = "shasum -a 256"
    end
    local hash_cmd = hasher .. " " .. backend_dir .. "/* | " .. hasher .. " | awk '{print $1}'"
    local local_hash = vim.fn.trim(vim.fn.system(hash_cmd))

    -- Check remote hash
    local check_cmd = string.format("ssh %s 'cat /tmp/jovian_backend/.hash 2>/dev/null'", host)

    local function do_sync()
        -- Sync files and update hash
        local setup_cmd = string.format("ssh %s 'rm -rf /tmp/jovian_backend && mkdir -p /tmp/jovian_backend'", host)

        vim.fn.jobstart(setup_cmd, {
            on_exit = function(_, code)
                if code ~= 0 then
                    if on_error then
                        on_error("Failed to prepare remote directory on " .. host)
                    end
                    return
                end

                local scp_cmd = string.format("scp -r %s/. %s:/tmp/jovian_backend", backend_dir, host)
                vim.fn.jobstart(scp_cmd, {
                    on_exit = function(_, scp_code)
                        if scp_code ~= 0 then
                            if on_error then
                                on_error("Failed to sync backend to " .. host)
                            end
                        else
                            -- Write hash file
                            local hash_write_cmd =
                                string.format("ssh %s 'echo %s > /tmp/jovian_backend/.hash'", host, local_hash)
                            vim.fn.jobstart(hash_write_cmd, {
                                on_exit = function()
                                    if on_success then
                                        on_success()
                                    end
                                end,
                            })
                        end
                    end,
                })
            end,
        })
    end

    vim.fn.jobstart(check_cmd, {
        stdout_buffered = true,
        on_stdout = function(_, data)
            if data and data[1] and vim.trim(data[1]) == local_hash then
                if on_success then
                    on_success()
                end
            else
                do_sync()
            end
        end,
        on_exit = function(_, code)
            if code ~= 0 then
                do_sync()
            end
        end,
    })
end

function M.start_kernel(on_ready)
    -- If called from command, on_ready might be a table (args). Ignore it.
    if type(on_ready) ~= "function" then
        on_ready = nil
    end

    if State.job_id then
        if on_ready then
            on_ready()
        end
        return
    end

    if State.is_starting_kernel then
        if on_ready then
            table.insert(State.on_ready_callbacks, on_ready)
        end
        return
    end

    State.is_starting_kernel = true

    -- Ensure IDs are unique before starting
    Cell.fix_duplicate_ids(0)

    -- Async Validation and Start
    Hosts.validate_connection(nil, function()
        -- Success callback
        local script_path = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h")
            .. "/lua/jovian/backend/kernel_bridge.py"
        local backend_dir = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h") .. "/lua/jovian/backend"

        local function launch()
            local cmd = M._prepare_kernel_command(script_path)
            State.job_id = vim.fn.jobstart(cmd, {
                on_stdout = on_stdout,
                on_stderr = on_stderr,
                stdout_buffered = false,
                on_exit = function(_, code)
                    State.job_id = nil
                    State.is_starting_kernel = false
                    if code ~= 0 and code ~= 143 then -- 143 is SIGTERM
                        vim.schedule(function()
                            vim.notify("Jovian Kernel died with code " .. code, vim.log.levels.ERROR)
                            UI.append_to_repl("[Kernel Process Died with code " .. code .. "]", "ErrorMsg")
                        end)
                    end
                    if State.lua_messenger_stop then
                        State.lua_messenger_stop()
                        State.lua_messenger_stop = nil
                    end
                end,
            })

            -- Native Lua Messenger (IOPUB & SHELL)
            local function start_lua_messenger()
                if not Config.options.use_lua_native_shell then
                    return
                end

                local m = get_messenger()
                if not m.is_available() then
                    if State.is_discovering_zmq then
                        -- Discovery is still in progress, wait a bit and retry
                        vim.defer_fn(start_lua_messenger, 200)
                        return
                    end

                    if not State.has_warned_native_unavailable then
                        vim.schedule(function()
                            vim.notify(
                                "[Jovian] Performance Mode (Native ZMQ) is unavailable because "
                                    .. "'libzmq' or 'openssl' is missing.\n"
                                    .. "Falling back to Python bridge. For maximum performance, "
                                    .. "please install these system dependencies.",
                                vim.log.levels.WARN
                            )
                        end)
                        State.has_warned_native_unavailable = true
                    end
                    return
                end

                local z = get_zmq()
                local conn_file = Config.options.connection_file
                if not conn_file then
                    return
                end

                local ok, content = pcall(function()
                    local f = io.open(conn_file, "r")
                    local res = f:read("*a")
                    f:close()
                    return vim.json.decode(res)
                end)

                if ok then
                    local ctx = z.new_ctx()
                    local iopub_socket = z.new_socket(ctx, z.SUB)
                    local shell_socket = z.new_socket(ctx, z.REQ)

                    local iopub_endpoint = string.format("tcp://%s:%d", content.ip, content.iopub_port)
                    local shell_endpoint = string.format("tcp://%s:%d", content.ip, content.shell_port)

                    z.connect(iopub_socket, iopub_endpoint)
                    z.connect(shell_socket, shell_endpoint)

                    z.setsockopt(iopub_socket, z.SUBSCRIBE, "", 0)

                    State.lua_shell_socket = shell_socket
                    State.lua_zmq_key = content.key

                    local timer = vim.loop.new_timer()
                    local stream_buffer = {}
                    local flush_timer = vim.loop.new_timer()

                    local function flush_streams()
                        if #stream_buffer > 0 then
                            local combined = table.concat(stream_buffer, "")
                            stream_buffer = {}
                            vim.schedule(function()
                                UI.append_to_repl(combined)
                            end)
                        end
                    end

                    flush_timer:start(50, 50, flush_streams)

                    timer:start(
                        0,
                        20, -- Faster poll for responsiveness
                        vim.schedule_wrap(function()
                            while true do
                                local msg = m.parse_multipart(iopub_socket)
                                if not msg then
                                    break
                                end

                                if msg.header.msg_type == "status" then
                                    local exec_state = msg.content.execution_state
                                    local parent = msg.parent_header
                                    if parent and parent.msg_id then
                                        local cell_id = State.msg_id_cell_map[parent.msg_id]
                                        if cell_id then
                                            local bufnr = State.cell_buf_map[cell_id]
                                            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                                                if exec_state == "busy" then
                                                    UI.set_cell_status(
                                                        bufnr,
                                                        cell_id,
                                                        "running",
                                                        Config.options.ui_symbols.running
                                                    )
                                                elseif exec_state == "idle" then
                                                    UI.set_cell_status(
                                                        bufnr,
                                                        cell_id,
                                                        "done",
                                                        Config.options.ui_symbols.done
                                                    )
                                                end
                                            end
                                        end
                                    end
                                elseif msg.header.msg_type == "stream" then
                                    table.insert(stream_buffer, msg.content.text)
                                end
                            end

                            -- Poll Shell Socket for replies to keep REQ/REP state clean
                            while true do
                                local reply = m.parse_multipart(shell_socket, z.DONTWAIT)
                                if not reply then
                                    break
                                end
                                -- We currently don't need to do much with shell replies in background
                                -- but we could buffer them if needed for async execution tracking.
                            end
                        end)
                    )

                    State.lua_messenger_stop = function()
                        timer:stop()
                        timer:close()
                        flush_timer:stop()
                        flush_timer:close()
                        z.zmq_close(iopub_socket)
                        z.zmq_close(shell_socket)
                        z.zmq_ctx_destroy(ctx)
                        State.lua_shell_socket = nil
                    end
                end
            end

            if Config.options.connection_file then
                start_lua_messenger()
            end
            -- UI.append_to_repl("[Jovian Kernel Started]")
            if on_ready then
                table.insert(State.on_ready_callbacks, on_ready)
            end
        end

        if Config.options.ssh_host then
            UI.append_to_repl("[Jovian] Syncing backend to remote...", "Special")
            M.sync_backend(Config.options.ssh_host, backend_dir, function()
                launch()
            end, function(err)
                UI.append_to_repl("[Error] " .. err, "ErrorMsg")
                vim.notify(err, vim.log.levels.ERROR)
            end)
        else
            launch()
        end
    end, function(err)
        -- Error callback
        UI.append_to_repl("[Error] " .. err, "ErrorMsg")
        vim.notify(err, vim.log.levels.ERROR)
    end)
end

function M.stop_kernel()
    if State.job_id then
        local id = State.job_id
        State.job_id = nil
        vim.fn.jobstop(id)
    end
    -- Feature 3: Cleanup tunnel
    require("jovian.tunnel").stop()
end

function M.restart_kernel()
    if State.job_id then
        vim.fn.jobstop(State.job_id)
        State.job_id = nil
    end
    UI.append_to_repl("[Kernel Restarting...]", "WarningMsg")

    -- Clear all status marks as kernel state is lost
    UI.clear_status_extmarks(0)

    M.start_kernel()
end

function M.send_payload(code, cell_id, filename)
    if not State.job_id then
        M.start_kernel(function()
            M.send_payload(code, cell_id, filename)
        end)
        return
    end
    local current_buf = vim.api.nvim_get_current_buf()

    State.cell_buf_map[cell_id] = current_buf
    State.cell_start_time[cell_id] = os.time()
    State.cell_hashes[cell_id] = Cell.get_cell_hash(code)
    State.running_cells[cell_id] = true

    local lines = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)
    for i, line in ipairs(lines) do
        if line:find('id="' .. cell_id .. '"', 1, true) then
            State.cell_start_line[cell_id] = i + 1
            break
        end
    end

    vim.diagnostic.reset(State.diag_ns, current_buf)
    vim.api.nvim_buf_clear_namespace(current_buf, State.diag_ns, 0, -1)

    UI.set_cell_status(current_buf, cell_id, "running", Config.options.ui_symbols.running)

    filename = filename or vim.fn.expand("%:t")
    if filename == "" then
        filename = "scratchpad"
    end
    local file_dir = vim.fn.expand("%:p:h")
    local cache_dir = file_dir .. "/.jovian_cache/" .. filename
    vim.fn.mkdir(cache_dir, "p")

    if State.lua_shell_socket and Config.options.use_lua_native_shell then
        local m = get_messenger()
        local req = m.create_message("execute_request", {
            code = code,
            silent = false,
            store_history = true,
            user_expressions = {},
            allow_stdin = true,
            stop_on_error = true,
        })
        local msg_id = m.send_message(State.lua_shell_socket, req, State.lua_zmq_key)
        State.msg_id_cell_map[msg_id] = cell_id

        -- Pre-set status to running for instant feedback
        local bufnr = vim.api.nvim_get_current_buf()
        UI.set_cell_status(bufnr, cell_id, "running", Config.options.ui_symbols.running)
        return
    end

    local payload = {
        command = "execute",
        code = code,
        cell_id = cell_id,
        file_dir = cache_dir,
        cwd = not Config.options.ssh_host and file_dir or nil,
    }

    -- Store hash for stale detection
    State.cell_hashes[cell_id] = Cell.get_cell_hash(code)

    local msg = vim.json.encode(payload)
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")
end

-- Add: Profiling
function M.profile_cell(code, cell_id)
    if not State.job_id then
        M.start_kernel(function()
            M.profile_cell(code, cell_id)
        end)
        return
    end
    local msg = vim.json.encode({
        command = "profile",
        code = code,
        cell_id = cell_id,
    })
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")
end

-- Add: Copy
function M.copy_variable(args)
    if not State.job_id then
        M.start_kernel(function()
            M.copy_variable(args)
        end)
        return
    end
    local var_name = args.args
    if var_name == "" then
        var_name = vim.fn.expand("<cword>")
    end
    local msg = vim.json.encode({ command = "copy_to_clipboard", name = var_name })
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")
end

function M.print_backend()
    if not State.job_id then
        return vim.notify("Kernel not started", vim.log.levels.WARN)
    end
    -- We use a hidden execution to print the backend
    local code = "import matplotlib; print(f'[Jovian] Current Backend: {matplotlib.get_backend()}')"
    local payload = {
        command = "execute",
        code = code,
        cell_id = "backend_check",
        file_dir = vim.fn.expand("%:p:h"),
        cwd = vim.fn.expand("%:p:h"),
    }
    local msg = vim.json.encode(payload)
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")
end

function M.send_cell()
    if not is_window_open() then
        return vim.notify("Jovian windows are closed. Use :JovianOpen or :JovianToggle first.", vim.log.levels.WARN)
    end
    if not State.job_id then
        M.start_kernel()
    end
    local s, e = Cell.get_cell_range()
    UI.flash_range(s, e)
    local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
    if #lines > 0 and lines[1]:match("^# %%%%") then
        if lines[1]:lower():match("%[markdown%]") then
            return vim.notify("Skipping markdown cell", vim.log.levels.INFO)
        end
        table.remove(lines, 1)
    end
    local id = Cell.get_current_cell_id(s, true)
    local fn = vim.fn.expand("%:t")
    if fn == "" then
        fn = "untitled"
    end
    M.send_payload(table.concat(lines, "\n"), id, fn)
end

-- Add: Profile current cell
function M.run_profile_cell()
    if not is_window_open() then
        return vim.notify("Jovian windows are closed.", vim.log.levels.WARN)
    end
    local s, e = Cell.get_cell_range()
    local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
    if #lines > 0 and lines[1]:match("^# %%%%") then
        table.remove(lines, 1)
    end
    local id = Cell.get_current_cell_id(s, true)
    M.profile_cell(table.concat(lines, "\n"), id)
end

function M.send_selection()
    if not is_window_open() then
        return vim.notify("Jovian windows are closed.", vim.log.levels.WARN)
    end
    if not State.job_id then
        M.start_kernel()
    end
    local _, csrow, _, _ = unpack(vim.fn.getpos("'<"))
    local _, cerow, _, _ = unpack(vim.fn.getpos("'>"))
    local lines = vim.api.nvim_buf_get_lines(0, csrow - 1, cerow, false)
    if #lines == 0 then
        return
    end
    UI.flash_range(csrow, cerow)
    local id = Cell.get_current_cell_id(csrow, true)
    local fn = vim.fn.expand("%:t")
    if fn == "" then
        fn = "untitled"
    end
    M.send_payload(table.concat(lines, "\n"), id, fn)
end

function M.run_and_next()
    M.send_cell()
    local _, e = Cell.get_cell_range()
    local total = vim.api.nvim_buf_line_count(0)
    if e < total then
        vim.api.nvim_win_set_cursor(0, { e + 1, 0 })
        -- If the next line is a header, we are good. If it's a gap, we might want to skip empty lines?
        -- For now, simple jump is sufficient.
    end
end

function M.run_line()
    if not is_window_open() then
        return vim.notify("Jovian windows are closed.", vim.log.levels.WARN)
    end
    if not State.job_id then
        M.start_kernel()
    end

    local line = vim.api.nvim_get_current_line()
    if line == "" then
        return
    end

    UI.flash_range(vim.fn.line("."), vim.fn.line("."))

    -- For single line execution, we can use a generic ID or try to attribute it to the current cell?
    -- Attributing to current cell is better for context, but we don't want to mark the whole cell as "Running".
    -- Let's use "scratchpad" or a temp ID to avoid UI status conflict,
    -- OR just use send_payload but suppress status update?
    -- send_payload updates status.
    -- Let's use a special ID suffix or just "line_exec".
    local id = "line_" .. os.time()
    local fn = vim.fn.expand("%:t")

    -- We use send_payload but maybe we want a lighter version?
    -- send_payload does: status update, append to repl, send json.
    -- It's fine to use it.
    M.send_payload(line, id, fn)
end

function M._execute_lines(lines, batch_name)
    local blk, current_bid, is_code = {}, nil, false
    local fn = vim.fn.expand("%:t")

    for i, line in ipairs(lines) do
        if line:match("^# %%%%") then
            -- 1. Send previous cell
            if #blk > 0 and is_code and current_bid then
                M.send_payload(table.concat(blk, "\n"), current_bid, fn)
            end
            -- 2. New Cell
            blk = {}
            current_bid = Cell.ensure_cell_id(i, line)
            is_code = not line:lower():find("# %% [markdown]", 1, true)
        elseif is_code then
            table.insert(blk, line)
        end
    end
    -- 3. Final cell
    if #blk > 0 and is_code and current_bid then
        M.send_payload(table.concat(blk, "\n"), current_bid, fn)
    end
    if batch_name then
        vim.notify("Jovian: " .. batch_name .. " finished", vim.log.levels.INFO)
    end
end

function M.run_all_cells()
    if not is_window_open() then
        return
    end
    if not State.job_id then
        M.start_kernel(function()
            M.run_all_cells()
        end)
        return
    end
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    M._execute_lines(lines, "RunAll")
end

function M.run_cells_above()
    if not is_window_open() then
        return
    end
    if not State.job_id then
        M.start_kernel(function()
            M.run_cells_above()
        end)
        return
    end
    local cursor_line = vim.fn.line(".")
    local cur_s, _ = Cell.get_cell_range(cursor_line)
    local lines = vim.api.nvim_buf_get_lines(0, 0, cur_s - 1, false)
    M._execute_lines(lines, "RunCellsAbove")
end

function M.view_dataframe(args)
    if not State.job_id then
        M.start_kernel(function()
            M.view_dataframe(args)
        end)
        return
    end

    local var_name = type(args) == "table" and args.args or args
    if var_name == "" or var_name == nil then
        var_name = vim.fn.expand("<cword>")
    end

    local offset = (args and type(args) == "table") and args.offset or 0
    local limit = (args and type(args) == "table") and args.limit or Config.options.dataframe_page_size

    local msg = vim.json.encode({
        command = "view_dataframe",
        name = var_name,
        offset = offset,
        limit = limit,
    })
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")
end

function M.view_dataframe_page(var_name, offset, limit)
    M.view_dataframe({ args = var_name, offset = offset, limit = limit })
end

function M.show_variables(opts)
    opts = opts or {}
    if not State.job_id then
        M.start_kernel(function()
            M.show_variables(opts)
        end)
        return
    end

    if opts.force_float then
        State.vars_request_force_float = true
    end

    local payload = {
        command = "get_variables",
        offset = opts.offset or 0,
        limit = opts.limit or 100,
    }

    local msg = vim.json.encode(payload)
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")
end

function M.interrupt_kernel()
    if not State.job_id then
        return vim.notify("Kernel not running", vim.log.levels.WARN)
    end

    -- Get PID from job_id and send SIGINT (Ctrl+C equivalent)
    local pid = vim.fn.jobpid(State.job_id)
    if pid then
        -- kill -2 for Unix, assuming Linux/Mac for now
        vim.loop.kill(pid, 2) -- 2 = SIGINT
        UI.append_to_repl("[Kernel Interrupted!]", "WarningMsg")

        -- Change status to Error if running
        for cell_id, buf in pairs(State.cell_buf_map) do
            UI.set_cell_status(buf, cell_id, "error", Config.options.ui_symbols.interrupted)
        end
        State.cell_buf_map = {} -- Clear
    else
        vim.notify("Could not get PID for kernel", vim.log.levels.ERROR)
    end
end

-- Add command functions
function M.inspect_object(args)
    if not State.job_id then
        M.start_kernel(function()
            M.inspect_object(args)
        end)
        return
    end
    local var_name = args.args
    if var_name == "" then
        var_name = vim.fn.expand("<cword>")
    end

    local msg = vim.json.encode({ command = "inspect", name = var_name })
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")
end

function M.peek_symbol(args)
    if not State.job_id then
        M.start_kernel(function()
            M.peek_symbol(args)
        end)
        return
    end
    local var_name = args.args
    if var_name == "" then
        var_name = vim.fn.expand("<cword>")
    end

    local msg = vim.json.encode({ command = "peek", name = var_name })
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")
end

-- Initialize
vim.schedule(function()
    local ok, data = pcall(Hosts.load_hosts)
    if ok and data.current and data.configs[data.current] then
        local config = data.configs[data.current]
        if config.type == "ssh" then
            Config.options.ssh_host = config.host
            Config.options.ssh_python = config.python
            Config.options.connection_file = nil
            Config.options.python_interpreter = config.python
        elseif config.type == "connection" then
            Config.options.ssh_host = nil
            Config.options.ssh_python = nil
            Config.options.connection_file = config.connection_file
            Config.options.python_interpreter = config.python
        else
            Config.options.ssh_host = nil
            Config.options.ssh_python = nil
            Config.options.connection_file = nil
            Config.options.python_interpreter = config.python
        end
    end
end)

function M.toggle_plot_view()
    if not State.job_id then
        M.start_kernel(function()
            M.toggle_plot_view()
        end)
        return
    end

    local current = Config.options.plot_view_mode
    local new_mode = current == "inline" and "window" or "inline"
    Config.options.plot_view_mode = new_mode

    local msg = vim.json.encode({ command = "set_plot_mode", mode = new_mode })
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")

    vim.notify("Plot View Mode: " .. new_mode, vim.log.levels.INFO)
end
function M.show_error_diagnostics(bufnr, cell_id, error_info)
    local start_line = State.cell_start_line[cell_id] or 1
    local err_line = error_info.line or 1
    local target_line = (start_line - 1) + (err_line - 1) -- 0-indexed for vim.diagnostic

    -- Ensure target_line is within buffer bounds
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if target_line >= line_count then
        target_line = line_count - 1
    end
    if target_line < 0 then
        target_line = 0
    end

    vim.diagnostic.set(State.diag_ns, bufnr, {
        {
            lnum = target_line,
            col = 0,
            message = error_info.msg,
            severity = vim.diagnostic.severity.ERROR,
            source = "Jovian",
        },
    })
end

return M
