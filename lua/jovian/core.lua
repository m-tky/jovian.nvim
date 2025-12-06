local M = {}
local State = require("jovian.state")
local Config = require("jovian.config")
local UI = require("jovian.ui")
local UI = require("jovian.ui")
local Utils = require("jovian.utils")
local Cell = require("jovian.cell")
local Session = require("jovian.session")

local function is_window_open()
	return State.win.output and vim.api.nvim_win_is_valid(State.win.output)
end

-- Host Management
local Hosts = require("jovian.hosts")


local Handlers = require("jovian.handlers")

local function on_stdout(chan_id, data, name)
	if not data then
		return
	end

	-- Buffering processing
	if not State.stdout_buffer then
		State.stdout_buffer = ""
	end

	-- Concatenate data
	local chunk = table.concat(data, "\n")
	State.stdout_buffer = State.stdout_buffer .. chunk

	-- Split by newline and process
	local lines = vim.split(State.stdout_buffer, "\n")

	-- The last element is likely an incomplete line, so put it back in buffer
	State.stdout_buffer = table.remove(lines)

	for _, line in ipairs(lines) do
		if line ~= "" then
			local ok, msg = pcall(vim.fn.json_decode, line)
			if ok and msg then
				vim.schedule(function()
                    local handler_name = "handle_" .. msg.type
                    if Handlers[handler_name] then
                        Handlers[handler_name](msg)
                    else
                        -- Fallback or ignore
                    end
				end)
			else
				-- Failed to decode JSON, likely an error message or debug output
				vim.schedule(function()
					vim.notify("Jovian Backend: " .. line, vim.log.levels.WARN)
				end)
			end
		end
	end
end



function M._prepare_kernel_command(script_path, backend_dir)
    local cmd = {}
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

        -- Transfer local backend directory to remote
        -- 1. scp -r to transfer directory
        -- 2. execute via ssh (specify kernel_bridge.py directly)
        -- Remote location: /tmp/jovian_backend

        -- First remove old remote directory and recreate it
        vim.fn.system(string.format("ssh %s 'rm -rf /tmp/jovian_backend && mkdir -p /tmp/jovian_backend'", host))

        -- Copy contents of backend_dir to remote /tmp/jovian_backend
        -- We use backend_dir/. to copy contents
        local scp_cmd = string.format("scp -r %s/. %s:/tmp/jovian_backend", backend_dir, host)
        vim.fn.system(scp_cmd) -- Synchronous execution to ensure file transfer

        cmd = { "ssh", host, remote_python, "-u", "/tmp/jovian_backend/kernel_bridge.py" }
        UI.append_to_repl("[Jovian] Connecting to remote: " .. host, "Special")
    else
        -- Local execution
        cmd = vim.split(Config.options.python_interpreter, " ")
        table.insert(cmd, script_path)
    end
    return cmd
end

function M.start_kernel()
	if State.job_id then
		return
	end

	-- Ensure IDs are unique before starting
	Cell.fix_duplicate_ids(0)

    -- Validate Connection
    local ok, err = Hosts.validate_connection()
    if not ok then
        UI.append_to_repl("[Error] " .. err, "ErrorMsg")
        vim.notify(err, vim.log.levels.ERROR)
        return
    end

	local script_path = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h") .. "/lua/jovian/backend/kernel_bridge.py"
	local backend_dir = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h") .. "/lua/jovian/backend"
	local cmd = M._prepare_kernel_command(script_path, backend_dir)

	State.job_id = vim.fn.jobstart(cmd, {
		on_stdout = on_stdout,
		on_stderr = on_stdout,
		stdout_buffered = false,
		on_exit = function()
			State.job_id = nil
		end,
	})
	UI.append_to_repl("[Jovian Kernel Started]")
	vim.defer_fn(function()
		Session.clean_stale_cache()
        -- Refresh variables pane if open
        if State.win.variables and vim.api.nvim_win_is_valid(State.win.variables) then
            M.show_variables()
        end
        
        -- Initialize plot mode from config
        if Config.options.plot_view_mode then
            local msg = vim.fn.json_encode({ command = "set_plot_mode", mode = Config.options.plot_view_mode })
            vim.fn.chansend(State.job_id, msg .. "\n")
        end
	end, 500)
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
		M.start_kernel()
	end
	local current_buf = vim.api.nvim_get_current_buf()

	State.cell_buf_map[cell_id] = current_buf
	State.cell_start_time[cell_id] = os.time()
    State.cell_hashes[cell_id] = Cell.get_cell_hash(code)

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



	local filename = vim.fn.expand("%:t")
	if filename == "" then
		filename = "scratchpad"
	end
	local file_dir = vim.fn.expand("%:p:h")
	local cache_dir = file_dir .. "/.jovian_cache/" .. filename
	vim.fn.mkdir(cache_dir, "p")

	local payload = {
		command = "execute",
		code = code,
		cell_id = cell_id,
		file_dir = cache_dir,
		cwd = file_dir,
	}
    
    -- Store hash for stale detection
    State.cell_hashes[cell_id] = Cell.get_cell_hash(code)
    
	local msg = vim.fn.json_encode(payload)
	vim.fn.chansend(State.job_id, msg .. "\n")
end

-- Add: Profiling
function M.profile_cell(code, cell_id)
	if not State.job_id then
		M.start_kernel()
	end
	local msg = vim.fn.json_encode({
		command = "profile",
		code = code,
		cell_id = cell_id,
	})
	vim.fn.chansend(State.job_id, msg .. "\n")
end

-- Add: Copy
function M.copy_variable(args)
	if not State.job_id then
		return vim.notify("Kernel not started", vim.log.levels.WARN)
	end
	local var_name = args.args
	if var_name == "" then
		var_name = vim.fn.expand("<cword>")
	end
	local msg = vim.fn.json_encode({ command = "copy_to_clipboard", name = var_name })
	vim.fn.chansend(State.job_id, msg .. "\n")
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
    local msg = vim.fn.json_encode(payload)
    vim.fn.chansend(State.job_id, msg .. "\n")
end

function M.send_cell()
	if not is_window_open() then
		return vim.notify("Jovian windows are closed. Use :JovianOpen or :JovianToggle first.", vim.log.levels.WARN)
	end
	local src_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(src_win)
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
	local src_win = vim.api.nvim_get_current_win()
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
	local src_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(src_win)
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
	local src_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(src_win)

	local line = vim.api.nvim_get_current_line()
	if line == "" then
		return
	end

	UI.flash_range(vim.fn.line("."), vim.fn.line("."))

	-- For single line execution, we can use a generic ID or try to attribute it to the current cell?
	-- Attributing to current cell is better for context, but we don't want to mark the whole cell as "Running".
	-- Let's use "scratchpad" or a temp ID to avoid UI status conflict, OR just use send_payload but suppress status update?
	-- send_payload updates status.
	-- Let's use a special ID suffix or just "line_exec".
	local id = "line_" .. os.time()
	local fn = vim.fn.expand("%:t")

	-- We use send_payload but maybe we want a lighter version?
	-- send_payload does: status update, append to repl, send json.
	-- It's fine to use it.
	M.send_payload(line, id, fn)
end

function M.run_all_cells()
	if not is_window_open() then
		return vim.notify("Jovian windows are closed.", vim.log.levels.WARN)
	end
	local src_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(src_win)
	if not State.job_id then
		M.start_kernel()
	end
	local fn = vim.fn.expand("%:t")
	if fn == "" then
		fn = "untitled"
	end
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local blk, bid, is_code = {}, "scratchpad", true
	for i, line in ipairs(lines) do
		if line:match("^# %%%%") then
			if #blk > 0 and is_code then
				M.send_payload(table.concat(blk, "\n"), bid, fn)
			end
			blk, bid = {}, Cell.ensure_cell_id(i, line)
			is_code = not line:lower():match("^# %%%%+%s*%[markdown%]")
		else
			if is_code then
				table.insert(blk, line)
			end
		end
	end
	if #blk > 0 and is_code then
		M.send_payload(table.concat(blk, "\n"), bid, fn)
	end
end

function M.run_cells_above()
	if not is_window_open() then
		return vim.notify("Jovian windows are closed.", vim.log.levels.WARN)
	end
	local src_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(src_win)
	if not State.job_id then
		M.start_kernel()
	end
	local fn = vim.fn.expand("%:t")
	if fn == "" then
		fn = "untitled"
	end

    local cursor_line = vim.fn.line(".")
    local _, end_line = Cell.get_cell_range(cursor_line)
	local lines = vim.api.nvim_buf_get_lines(0, 0, end_line, false)
    
	local blk, bid, is_code = {}, "scratchpad", true
	for i, line in ipairs(lines) do
		if line:match("^# %%%%") then
			if #blk > 0 and is_code then
				M.send_payload(table.concat(blk, "\n"), bid, fn)
			end
			blk, bid = {}, Cell.ensure_cell_id(i, line)
			is_code = not line:lower():match("^# %%%%+%s*%[markdown%]")
		else
			if is_code then
				table.insert(blk, line)
			end
		end
	end
	if #blk > 0 and is_code then
		M.send_payload(table.concat(blk, "\n"), bid, fn)
	end
end

function M.view_dataframe(args)
	if not State.job_id then
		return vim.notify("Kernel not started", vim.log.levels.WARN)
	end
	local var_name = args.args
	if var_name == "" then
		var_name = vim.fn.expand("<cword>")
	end
	local msg = vim.fn.json_encode({ command = "view_dataframe", name = var_name })
	vim.fn.chansend(State.job_id, msg .. "\n")
end

function M.show_variables(opts)
	if not State.job_id then
		return vim.notify("Kernel not started", vim.log.levels.WARN)
	end
    
    if opts and opts.force_float then
        State.vars_request_force_float = true
    end

	local msg = vim.fn.json_encode({ command = "get_variables" })
    -- UI.append_to_repl("[Jovian] Requesting variables...", "Comment")
	vim.fn.chansend(State.job_id, msg .. "\n")
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
		return vim.notify("Kernel not started", vim.log.levels.WARN)
	end
	local var_name = args.args
	if var_name == "" then
		var_name = vim.fn.expand("<cword>")
	end

	local msg = vim.fn.json_encode({ command = "inspect", name = var_name })
	vim.fn.chansend(State.job_id, msg .. "\n")
end

function M.peek_symbol(args)
	if not State.job_id then
		return vim.notify("Kernel not started", vim.log.levels.WARN)
	end
	local var_name = args.args
	if var_name == "" then
		var_name = vim.fn.expand("<cword>")
	end

	local msg = vim.fn.json_encode({ command = "peek", name = var_name })
	vim.fn.chansend(State.job_id, msg .. "\n")
end



-- Initialize
vim.schedule(function()
    local data = Hosts.load_hosts()
    if data.current and data.configs[data.current] then
        local config = data.configs[data.current]
        if config.type == "ssh" then
            Config.options.ssh_host = config.host
            Config.options.ssh_python = config.python
            Config.options.connection_file = nil
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
        return vim.notify("Kernel not started", vim.log.levels.WARN)
    end
    
    local current = Config.options.plot_view_mode
    local new_mode = current == "inline" and "window" or "inline"
    Config.options.plot_view_mode = new_mode
    
    local msg = vim.fn.json_encode({ command = "set_plot_mode", mode = new_mode })
    vim.fn.chansend(State.job_id, msg .. "\n")
    
    vim.notify("Plot View Mode: " .. new_mode, vim.log.levels.INFO)
end

return M
