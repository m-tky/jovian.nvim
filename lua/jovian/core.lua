local M = {}
local State = require("jovian.state")
local Config = require("jovian.config")
local UI = require("jovian.ui")
local Utils = require("jovian.utils")

local function is_window_open()
	return State.win.output and vim.api.nvim_win_is_valid(State.win.output)
end

-- Host Management
local Hosts = require("jovian.hosts")


local function on_stdout(chan_id, data, name)
	if not data then
		return
	end

	-- Buffering processing
	if not State.stdout_buffer then
		State.stdout_buffer = ""
	end

	-- Concatenate data
	-- data is a table (lines), so concatenate first
	-- However, if the last element is not empty, it might mean "mid-line"
	-- vim.fn.jobstart spec: last element is usually continuation or empty string after newline

	local chunk = table.concat(data, "\n")
	State.stdout_buffer = State.stdout_buffer .. chunk

	-- Split by newline and process
	local lines = vim.split(State.stdout_buffer, "\n")

	-- The last element is likely an incomplete line, so put it back in buffer
	-- If the last element is empty, the previous one ended with newline,
	-- so buffer can be cleared.
	State.stdout_buffer = table.remove(lines)

	for _, line in ipairs(lines) do
		if line ~= "" then
			local ok, msg = pcall(vim.fn.json_decode, line)
			if ok and msg then
				vim.schedule(function()
					if msg.type == "stream" then
						UI.append_stream_text(msg.text, msg.stream)
					elseif msg.type == "image_saved" then
						UI.append_to_repl("[Image Created]: " .. vim.fn.fnamemodify(msg.path, ":t"), "Special")
					elseif msg.type == "result_ready" then
						UI.append_to_repl("-> Done: " .. msg.cell_id, "Comment")
						State.current_preview_file = nil
                        
                        -- Sync content to local cache if provided (SSH or Local)
                        if msg.content_md then
                            local cell_id = msg.cell_id
                            local filename = vim.fn.expand("%:t")
                            if filename == "" then filename = "scratchpad" end
                            local file_dir = vim.fn.expand("%:p:h")
                            local cache_dir = file_dir .. "/.jovian_cache/" .. filename
                            
                            -- Ensure cache dir exists
                            vim.fn.mkdir(cache_dir, "p")
                            
                            -- Write Images
                            if msg.images then
                                for img_name, b64 in pairs(msg.images) do
                                    local img_path = cache_dir .. "/" .. img_name
                                    -- Decode base64 and write
                                    -- Requires base64 CLI or pure lua. 
                                    -- Since we are in Neovim, we can use vim.base64 (if available? No)
                                    -- We can use python to decode? Or openssl?
                                    -- Let's use a simple python one-liner to write it, since we know python is available (we are running it).
                                    -- Actually, we can just write the bytes if we had them, but we have b64 string.
                                    -- Let's use vim.fn.system with python to decode and write.
                                    -- Or better, since we are in LuaJIT, maybe use `vim.base64`? No, it's not standard.
                                    -- `vim.mpack`? No.
                                    -- Let's use the `base64` command line tool if available, or python.
                                    -- Python is safer since we depend on it.
                                    local write_script = string.format(
                                        "import base64, sys; open('%s', 'wb').write(base64.b64decode(sys.stdin.read()))",
                                        img_path
                                    )
                                    vim.fn.system({Config.options.python_interpreter, "-c", write_script}, b64)
                                end
                            end

                            -- Write MD
                            local md_path = cache_dir .. "/" .. cell_id .. ".md"
                            local f = io.open(md_path, "w")
                            if f then
                                f:write(msg.content_md)
                                f:close()
                                msg.file = md_path -- Update to local path
                            end
                        end

						UI.open_markdown_preview(msg.file)
                        UI.update_variables_pane()

						local target_buf = State.cell_buf_map[msg.cell_id]
						if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
							local start_t = State.cell_start_time[msg.cell_id]
							if start_t and (os.time() - start_t) >= Config.options.notify_threshold then
								UI.send_notification("Calculation " .. msg.cell_id .. " Finished!")
							end
							vim.api.nvim_buf_clear_namespace(target_buf, State.diag_ns, 0, -1)

							-- Fix: Check status field as well
							if msg.error or msg.status == "error" then
								UI.set_cell_status(target_buf, msg.cell_id, "error", Config.options.ui_symbols.error)

								-- Show diagnostics if error info exists
								if msg.error then
									local start_line = State.cell_start_line[msg.cell_id] or 1
									local target_line = (start_line - 1) + (msg.error.line - 1)
									vim.diagnostic.set(State.diag_ns, target_buf, {
										{
											lnum = target_line,
											col = 0,
											message = msg.error.msg,
											severity = vim.diagnostic.severity.ERROR,
											source = "Jovian",
										},
									})
								end
							else
								UI.set_cell_status(target_buf, msg.cell_id, "done", Config.options.ui_symbols.done)
							end
						end
						State.cell_buf_map[msg.cell_id] = nil
						State.cell_start_time[msg.cell_id] = nil
						State.cell_start_line[msg.cell_id] = nil
					elseif msg.type == "variable_list" then
						UI.show_variables(msg.variables)
					elseif msg.type == "dataframe_data" then
						UI.show_dataframe(msg)
					elseif msg.type == "profile_stats" then
						UI.show_profile_stats(msg.text)
					elseif msg.type == "inspection_data" then
						UI.show_inspection(msg.data)
					elseif msg.type == "peek_data" then
						UI.show_peek(msg.data or msg)
					elseif msg.type == "clipboard_data" then
						vim.fn.setreg("+", msg.content)
						vim.notify("Copied to system clipboard!", vim.log.levels.INFO)
					elseif msg.type == "input_request" then
						UI.append_to_repl("[Input Requested]: " .. msg.prompt, "Special")
						vim.ui.input({ prompt = msg.prompt }, function(input)
							local value = input or ""
							UI.append_to_repl(value)
							if State.job_id then
								local reply = vim.fn.json_encode({ command = "input_reply", value = value })
								vim.fn.chansend(State.job_id, reply .. "\n")
							end
						end)
					end
				end)
			end
		end
	end
end

function M.clean_stale_cache()
	if not State.job_id then
		return
	end
	local filename = vim.fn.expand("%:t")
	if filename == "" then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local valid_ids = {}
	for _, line in ipairs(lines) do
		local id = line:match('id="([%w%-_]+)"')
		if id then
			table.insert(valid_ids, id)
		end
	end
    local file_dir = vim.fn.expand("%:p:h")
	local msg = vim.fn.json_encode({
		command = "clean_cache",
		filename = filename,
        file_dir = file_dir,
		valid_ids = valid_ids,
	})
	vim.fn.chansend(State.job_id, msg .. "\n")
end

function M.start_kernel()
	if State.job_id then
		return
	end

	-- Ensure IDs are unique before starting
	Utils.fix_duplicate_ids(0)

    -- Validate Connection
    local ok, err = Hosts.validate_connection()
    if not ok then
        UI.append_to_repl("[Error] " .. err, "ErrorMsg")
        vim.notify(err, vim.log.levels.ERROR)
        return
    end

	local script_path = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h") .. "/lua/jovian/backend/main.py"
	local backend_dir = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h") .. "/lua/jovian/backend"
	local cmd = {}

	-- Add: SSH support
	if Config.options.ssh_host then
		local host = Config.options.ssh_host
		local remote_python = Config.options.ssh_python

		-- Transfer local backend directory to remote
		-- 1. scp -r to transfer directory
		-- 2. execute via ssh (specify main.py directly)
		-- Remote location: /tmp/jovian_backend

		-- First remove old remote directory (just in case)
		vim.fn.system(string.format("ssh %s 'rm -rf /tmp/jovian_backend'", host))

		local scp_cmd = string.format("scp -r %s %s:/tmp/jovian_backend", backend_dir, host)
		vim.fn.system(scp_cmd) -- Synchronous execution to ensure file transfer

		cmd = { "ssh", host, remote_python, "-u", "/tmp/jovian_backend/main.py" }
		UI.append_to_repl("[Jovian] Connecting to remote: " .. host, "Special")
	else
		-- Local execution
		cmd = vim.split(Config.options.python_interpreter, " ")
		table.insert(cmd, script_path)
	end

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
		M.clean_stale_cache()
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

	UI.append_to_repl({ "In [" .. cell_id .. "]:" }, "Type")
	local code_lines = vim.split(code, "\n")
	local indented = {}
	for _, l in ipairs(code_lines) do
		table.insert(indented, "    " .. l)
	end
	UI.append_to_repl(indented)
	UI.append_to_repl({ "" })

	local msg = vim.fn.json_encode({
		command = "execute",
		code = code,
		cell_id = cell_id,
		filename = filename,
        file_dir = vim.fn.expand("%:p:h"),
	})
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

function M.send_cell()
	if not is_window_open() then
		return vim.notify("Jovian windows are closed. Use :JovianOpen or :JovianToggle first.", vim.log.levels.WARN)
	end
	local src_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(src_win)
	local s, e = Utils.get_cell_range()
	UI.flash_range(s, e)
	local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
	if #lines > 0 and lines[1]:match("^# %%%%") then
		table.remove(lines, 1)
	end
	local id = Utils.get_current_cell_id(s)
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
	local s, e = Utils.get_cell_range()
	local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
	if #lines > 0 and lines[1]:match("^# %%%%") then
		table.remove(lines, 1)
	end
	local id = Utils.get_current_cell_id(s)
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
	local id = Utils.get_current_cell_id(csrow)
	local fn = vim.fn.expand("%:t")
	if fn == "" then
		fn = "untitled"
	end
	M.send_payload(table.concat(lines, "\n"), id, fn)
end

function M.run_and_next()
	M.send_cell()
	local _, e = Utils.get_cell_range()
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
			blk, bid = {}, Utils.ensure_cell_id(i, line)
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

function M.show_variables()
	if not State.job_id then
		return vim.notify("Kernel not started", vim.log.levels.WARN)
	end
	local msg = vim.fn.json_encode({ command = "get_variables" })
	vim.fn.chansend(State.job_id, msg .. "\n")
end

function M.check_cursor_cell()
	-- if not State.job_id then return end -- Allow checking cache even if kernel is not running
	vim.schedule(function()
		local cell_id = Utils.get_current_cell_id()
		local filename = vim.fn.expand("%:t")
		if filename == "" then
			filename = "scratchpad"
		end
        local file_dir = vim.fn.expand("%:p:h")
		local cache_dir = file_dir .. "/.jovian_cache/" .. filename
		local rel_path = cache_dir .. "/" .. cell_id .. ".md"
		local md_path = vim.fn.fnamemodify(rel_path, ":p")
		if State.current_preview_file ~= md_path and vim.fn.filereadable(md_path) == 1 then
			UI.open_markdown_preview(md_path)
		end
	end)
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

-- Add: Save session command
function M.save_session(args)
	if not State.job_id then
		return
	end
	local filename = args.args
	if filename == "" then
		filename = "jovian_session.pkl"
	end -- Default name

	local msg = vim.fn.json_encode({ command = "save_session", filename = filename })
	vim.fn.chansend(State.job_id, msg .. "\n")
end

-- Add: Load session command
function M.load_session(args)
	if not State.job_id then
		M.start_kernel()
	end
	local filename = args.args
	if filename == "" then
		filename = "jovian_session.pkl"
	end

	local msg = vim.fn.json_encode({ command = "load_session", filename = filename })
	vim.fn.chansend(State.job_id, msg .. "\n")
end

-- Add: TUI Plot
function M.plot_tui(args)
	if not State.job_id then
		return
	end
	local var_name = args.args
	if var_name == "" then
		var_name = vim.fn.expand("<cword>")
	end

	if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
		-- Subtract line number width etc. (approx 5 chars) from window width
		width = vim.api.nvim_win_get_width(State.win.output) - 5
		if width < 20 then
			width = 20
		end -- Minimum width guarantee
	end

	local msg = vim.fn.json_encode({ command = "plot_tui", name = var_name, width = width })
	vim.fn.chansend(State.job_id, msg .. "\n")
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

-- Add: Structure Check
function M.check_structure_change()
    local bufnr = vim.api.nvim_get_current_buf()
    UI.clean_invalid_extmarks(bufnr)
end

local structure_timer = nil
function M.schedule_structure_check()
    if structure_timer then
        structure_timer:close()
    end
    structure_timer = vim.loop.new_timer()
    structure_timer:start(200, 0, vim.schedule_wrap(function()
        M.check_structure_change()
        if structure_timer then
            structure_timer:close()
            structure_timer = nil
        end
    end))
end

-- Initialize
vim.schedule(function()
    local data = Hosts.load_hosts()
    if data.current and data.configs[data.current] then
        local config = data.configs[data.current]
        if config.type == "ssh" then
            Config.options.ssh_host = config.host
            Config.options.ssh_python = config.python
        else
            Config.options.ssh_host = nil
            Config.options.ssh_python = nil
            Config.options.python_interpreter = config.python
        end
    end
end)

return M
