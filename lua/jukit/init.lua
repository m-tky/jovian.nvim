local M = {}

-- === デフォルト設定 ===
local default_config = {
	preview_width_percent = 40,
	repl_height_percent = 30,
	preview_image_ratio = 0.6,
	repl_image_ratio = 0.3,
	flash_highlight_group = "Visual",
	flash_duration = 300,
	python_interpreter = "python3",
}

M.config = vim.deepcopy(default_config)

local job_id = nil
local output_buf = nil
local output_win = nil
local preview_buf = nil
local preview_win = nil
local stdout_buffer = {}
M.last_previewed_id = nil
M.repl_images = {}
M.preview_images = {}

local hl_ns = vim.api.nvim_create_namespace("JukitCellHighlight")

-- === ユーティリティ ===

local function generate_id()
	math.randomseed(os.time())
	local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
	local id = ""
	for i = 1, 8 do
		local rand = math.random(#chars)
		id = id .. string.sub(chars, rand, rand)
	end
	return id
end

local function ensure_cell_id(line_num, line_content)
	local id = line_content:match('id="([%w%-_]+)"')
	if id then
		return id
	else
		id = generate_id()
		if line_content:match("^# %%%%") then
			local new_line = line_content .. ' id="' .. id .. '"'
			vim.api.nvim_buf_set_lines(0, line_num - 1, line_num, false, { new_line })
		end
		return id
	end
end

local function get_cell_id(line_num)
	local line
	if line_num then
		local lines = vim.api.nvim_buf_get_lines(0, line_num - 1, line_num, false)
		if #lines > 0 then
			line = lines[1]
		else
			line = ""
		end
	else
		line = vim.api.nvim_get_current_line()
	end

	local existing_id = line:match('id="([%w%-_]+)"')
	if existing_id then
		return existing_id
	else
		local current_lnum = line_num or vim.fn.line(".")
		local found_id = nil
		for l = current_lnum, 1, -1 do
			local l_content = vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1]
			local mid = l_content:match('id="([%w%-_]+)"')
			if mid then
				found_id = mid
				break
			end
			if l_content:match("^# %%%%") then
				break
			end
		end

		if found_id then
			return found_id
		else
			if line:match("^# %%%%") then
				local id = generate_id()
				local new_line = line .. ' id="' .. id .. '"'
				if line_num then
					vim.api.nvim_buf_set_lines(0, line_num - 1, line_num, false, { new_line })
				else
					vim.api.nvim_set_current_line(new_line)
				end
				return id
			else
				return "scratchpad"
			end
		end
	end
end

local function flash_cell(bufnr, start_line, end_line)
	vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)
	vim.api.nvim_buf_set_extmark(bufnr, hl_ns, start_line - 1, 0, {
		end_row = end_line,
		hl_group = M.config.flash_highlight_group,
		hl_eol = true,
		priority = 200,
	})
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)
		end
	end, M.config.flash_duration)
end

function M.clean_stale_cache()
	if not job_id then
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
	local msg = vim.fn.json_encode({
		command = "clean_cache",
		filename = filename,
		valid_ids = valid_ids,
	})
	vim.fn.chansend(job_id, msg .. "\n")
end

-- === 描画ヘルパー ===

local function append_text(buf, win, text_lines, highlight_group)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, text_lines)

	if highlight_group then
		local last_line = vim.api.nvim_buf_line_count(buf)
		for i = 0, #text_lines - 1 do
			vim.api.nvim_buf_add_highlight(buf, -1, highlight_group, last_line - #text_lines + i, 0, -1)
		end
	end

	if win and vim.api.nvim_win_is_valid(win) then
		local count = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_win_set_cursor(win, { count, 0 })
	end
end

local function append_image(buf, win, image_path, ratio, store_table)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local win_height = 15
	local win_width = 50
	if win and vim.api.nvim_win_is_valid(win) then
		win_height = vim.api.nvim_win_get_height(win)
		win_width = vim.api.nvim_win_get_width(win)
	end

	local img_height = math.floor(win_height * (ratio or 0.5))
	if img_height < 3 then
		img_height = 3
	end
	local img_width = math.floor(win_width * 0.95)

	local empty_lines = {}
	for i = 1, img_height do
		table.insert(empty_lines, "")
	end
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, empty_lines)

	local current_total_lines = vim.api.nvim_buf_line_count(buf)
	local target_line_index = current_total_lines - img_height

	local ok_img, image = pcall(require, "image")
	if ok_img then
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			local img = image.from_file(image_path, {
				buffer = buf,
				window = win,
				with_virtual_padding = false,
				inline = true,
				x = 0,
				y = target_line_index,
				width = img_width,
				height = img_height,
			})
			if img then
				img:render()
				if store_table then
					table.insert(store_table, img)
				end
			end
		end)
	else
		vim.api.nvim_buf_set_lines(buf, target_line_index, target_line_index + 1, false, { "[Image]: " .. image_path })
	end

	if win and vim.api.nvim_win_is_valid(win) then
		local count = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_win_set_cursor(win, { count, 0 })
	end
end

-- === Preview更新 ===

function M.render_preview(cell_id)
	if not (preview_buf and vim.api.nvim_buf_is_valid(preview_buf)) then
		return
	end

	if M.preview_images then
		for _, img in ipairs(M.preview_images) do
			pcall(function()
				if img.clear then
					img:clear()
				end
			end)
		end
	end
	M.preview_images = {}

	vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
	M.last_previewed_id = cell_id

	append_text(preview_buf, preview_win, { "=== Output for Cell [" .. cell_id .. "] ===", "" }, "Title")

	local filename = vim.fn.expand("%:t")
	if filename == "" then
		filename = "scratchpad"
	end
	local cache_dir = ".jukit_cache/" .. filename

	local pattern = cache_dir .. "/" .. cell_id .. "_*"
	local files_str = vim.fn.glob(pattern)

	if files_str == "" then
		append_text(preview_buf, preview_win, { "(No output cache found)" }, "Comment")
		return
	end

	local files = vim.split(files_str, "\n", { trimempty = true })
	table.sort(files)

	for _, filepath in ipairs(files) do
		if filepath:match("%.txt$") then
			local f = io.open(filepath, "r")
			if f then
				local content = f:read("*a")
				f:close()
				if content and content ~= "" then
					content = content:gsub("\r\n", "\n")
					local lines = vim.split(content, "\n")
					if lines[#lines] == "" then
						table.remove(lines, #lines)
					end
					append_text(preview_buf, preview_win, lines)
				end
			end
		elseif filepath:match("%.png$") then
			append_image(preview_buf, preview_win, filepath, M.config.preview_image_ratio, M.preview_images)
		end
	end
end

-- === ハンドラ ===

local function on_stdout(chan_id, data, name)
	if not data then
		return
	end
	if #stdout_buffer > 0 then
		data[1] = table.concat(stdout_buffer) .. data[1]
		stdout_buffer = {}
	end
	if #data > 0 then
		stdout_buffer = { table.remove(data, #data) }
	end

	for _, line in ipairs(data) do
		if line ~= "" then
			local ok, msg = pcall(vim.fn.json_decode, line)
			if ok and msg then
				vim.schedule(function()
					local cell_id = msg.cell_id or "unknown"
					if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
						if msg.type == "text_file" then
							local f = io.open(msg.payload, "r")
							if f then
								local content = f:read("*a")
								f:close()
								if content and content ~= "" then
									content = content:gsub("\r\n", "\n")
									local lines = vim.split(content, "\n")
									if lines[#lines] == "" then
										table.remove(lines, #lines)
									end
									append_text(output_buf, output_win, { "Out [" .. cell_id .. "]:" }, "Comment")
									append_text(output_buf, output_win, lines)
								end
							end
						elseif msg.type == "image_file" then
							append_text(output_buf, output_win, { "Out [" .. cell_id .. "]: (Image)" }, "Comment")
							append_image(output_buf, output_win, msg.payload, M.config.repl_image_ratio, M.repl_images)
						elseif msg.type == "error" then
							local lines = vim.split(msg.payload, "\n")
							table.insert(lines, 1, "--- ERROR ---")
							append_text(output_buf, output_win, lines, "ErrorMsg")
						end
					end
					local current_cursor_cell_id = get_cell_id()
					if current_cursor_cell_id == cell_id then
						M.render_preview(cell_id)
					end
				end)
			end
		end
	end
end

function M.check_cursor_cell()
	if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
		return
	end
	local current_id = get_cell_id()
	if M.last_previewed_id ~= current_id then
		M.render_preview(current_id)
	end
end

-- === 送信ロジック ===

local function send_payload(code, cell_id, filename)
	if not job_id then
		M.start_kernel()
	end

	if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
		local log_lines = { "", "In [" .. cell_id .. "]:" }
		for _, l in ipairs(vim.split(code, "\n")) do
			table.insert(log_lines, "    " .. l)
		end
		append_text(output_buf, output_win, log_lines)
	end

	if preview_buf then
		if M.preview_images then
			for _, img in ipairs(M.preview_images) do
				pcall(function()
					if img.clear then
						img:clear()
					end
				end)
			end
		end
		M.preview_images = {}
		vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
		append_text(preview_buf, preview_win, { "", "--- Processing Cell [" .. cell_id .. "]... ---" }, "Special")
	end

	local msg = vim.fn.json_encode({
		command = "execute",
		code = code,
		cell_id = cell_id,
		filename = filename,
	})
	vim.fn.chansend(job_id, msg .. "\n")
end

-- 1. 現在セル
function M.send_cell()
	M.open_windows()
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	local total_lines = vim.api.nvim_buf_line_count(0)

	local start_line = cursor_line
	while start_line > 1 do
		local l = vim.api.nvim_buf_get_lines(0, start_line - 1, start_line, false)[1]
		if l:match("^# %%%%") then
			break
		end
		start_line = start_line - 1
	end
	local end_line = cursor_line
	while end_line < total_lines do
		local l = vim.api.nvim_buf_get_lines(0, end_line, end_line + 1, false)[1]
		if l:match("^# %%%%") then
			break
		end
		end_line = end_line + 1
	end

	flash_cell(0, start_line, end_line)

	local cell_lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	if #cell_lines > 0 and cell_lines[1]:match("^# %%%%") then
		table.remove(cell_lines, 1)
	end

	local cell_id = get_cell_id(start_line)
	local code = table.concat(cell_lines, "\n")
	local filename = vim.fn.expand("%:t")
	if filename == "" then
		filename = "untitled"
	end

	send_payload(code, cell_id, filename)
end

-- 2. 選択範囲
function M.send_selection()
	M.open_windows()
	local _, csrow, _, _ = unpack(vim.fn.getpos("'<"))
	local _, cerow, _, _ = unpack(vim.fn.getpos("'>"))
	local lines = vim.api.nvim_buf_get_lines(0, csrow - 1, cerow, false)
	if #lines == 0 then
		return
	end
	flash_cell(0, csrow, cerow)
	local cell_id = get_cell_id(csrow)
	local code = table.concat(lines, "\n")
	local filename = vim.fn.expand("%:t")
	if filename == "" then
		filename = "untitled"
	end
	send_payload(code, cell_id, filename)
end

-- 3. 全セル (修正版: より安全なMarkdown除外判定)
function M.run_all_cells()
	M.open_windows()
	if not job_id then
		M.start_kernel()
	end

	local filename = vim.fn.expand("%:t")
	if filename == "" then
		filename = "untitled"
	end
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local current_block = {}
	local current_id = "scratchpad"
	local is_code_block = true

	if preview_buf then
		vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
		append_text(preview_buf, preview_win, { "--- Running All Cells... ---" }, "Title")
	end

	for i, line in ipairs(lines) do
		if line:match("^# %%%%") then
			if #current_block > 0 and is_code_block then
				local code = table.concat(current_block, "\n")
				send_payload(code, current_id, filename)
			end

			current_block = {}
			current_id = ensure_cell_id(i, line)

			-- ★ 判定ロジック強化: 行頭付近に [markdown] がある場合のみ除外
			-- 例: # %% [markdown] id="foo" -> 除外
			-- 例: # %% id="foo" -> 実行 (idの中にmarkdownが含まれていてもOK)
			if line:lower():match("^# %%%%+%s*%[markdown%]") then
				is_code_block = false
			else
				is_code_block = true
			end
		else
			if is_code_block then
				table.insert(current_block, line)
			end
		end
	end
	if #current_block > 0 and is_code_block then
		local code = table.concat(current_block, "\n")
		send_payload(code, current_id, filename)
	end
end

-- 4. カーネル再起動
function M.restart_kernel()
	if job_id then
		vim.fn.jobstop(job_id)
		job_id = nil
	end
	M.repl_images = {}
	M.preview_images = {}
	if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
		vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { "[Kernel Restarting...]", "" })
	end
	if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
		vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
	end
	print("Jukit: Kernel restarting...")
	M.start_kernel()
end

-- === ウィンドウ管理 ===

function M.open_windows()
	local code_win = vim.api.nvim_get_current_win()
	if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
		vim.cmd("vsplit")
		vim.cmd("wincmd L")
		preview_win = vim.api.nvim_get_current_win()
		preview_buf = vim.api.nvim_create_buf(false, true)
		local width = math.floor(vim.o.columns * (M.config.preview_width_percent / 100))
		vim.api.nvim_win_set_width(preview_win, width)
		vim.api.nvim_buf_set_option(preview_buf, "buftype", "nofile")
		vim.api.nvim_buf_set_name(preview_buf, "JukitPreview")
		vim.api.nvim_win_set_buf(preview_win, preview_buf)
	end
	vim.api.nvim_set_current_win(code_win)
	if not (output_win and vim.api.nvim_win_is_valid(output_win)) then
		vim.cmd("split")
		vim.cmd("wincmd j")
		output_win = vim.api.nvim_get_current_win()
		if not (output_buf and vim.api.nvim_buf_is_valid(output_buf)) then
			output_buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_option(output_buf, "buftype", "nofile")
			vim.api.nvim_buf_set_name(output_buf, "JukitConsole")
			vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { "[Jukit Kernel Console Ready]" })
		end
		vim.api.nvim_win_set_buf(output_win, output_buf)
		local height = math.floor(vim.o.lines * (M.config.repl_height_percent / 100))
		vim.api.nvim_win_set_height(output_win, height)
	end
	vim.api.nvim_set_current_win(code_win)
end

function M.close_windows()
	if preview_win and vim.api.nvim_win_is_valid(preview_win) then
		vim.api.nvim_win_close(preview_win, true)
		preview_win = nil
	end
	if output_win and vim.api.nvim_win_is_valid(output_win) then
		vim.api.nvim_win_close(output_win, true)
		output_win = nil
	end
end

function M.toggle_windows()
	local p_open = preview_win and vim.api.nvim_win_is_valid(preview_win)
	local o_open = output_win and vim.api.nvim_win_is_valid(output_win)
	if p_open or o_open then
		M.close_windows()
	else
		M.open_windows()
	end
end

-- === カーネル起動 ===

function M.start_kernel()
	if job_id then
		return
	end
	M.repl_images = {}
	M.preview_images = {}

	local source = debug.getinfo(1).source:sub(2)
	local root = vim.fn.fnamemodify(source, ":h:h:h")
	local script_path = root .. "/lua/jukit/kernel.py"

	local cmd_parts = vim.split(M.config.python_interpreter, " ")
	table.insert(cmd_parts, script_path)

	job_id = vim.fn.jobstart(cmd_parts, {
		on_stdout = on_stdout,
		on_stderr = on_stdout,
		stdout_buffered = false,
		on_exit = function()
			job_id = nil
		end,
	})

	if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
		vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, { "Kernel Job ID: " .. job_id })
	end

	vim.defer_fn(function()
		M.clean_stale_cache()
	end, 500)
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", default_config, opts or {})

	vim.api.nvim_create_user_command("JukitStart", M.start_kernel, {})
	vim.api.nvim_create_user_command("JukitRun", M.send_cell, {})
	vim.api.nvim_create_user_command("JukitSendSelection", M.send_selection, { range = true })
	vim.api.nvim_create_user_command("JukitRunAll", M.run_all_cells, {})
	vim.api.nvim_create_user_command("JukitRestart", M.restart_kernel, {})
	vim.api.nvim_create_user_command("JukitOpen", M.open_windows, {})
	vim.api.nvim_create_user_command("JukitToggle", M.toggle_windows, {})
	vim.api.nvim_create_user_command("JukitClean", M.clean_stale_cache, {})

	vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
		pattern = "*",
		callback = function()
			if vim.bo.filetype == "python" then
				if job_id then
					M.check_cursor_cell()
				end
			end
		end,
	})
end

return M
