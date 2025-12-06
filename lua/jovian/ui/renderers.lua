local M = {}
local Config = require("jovian.config")
local State = require("jovian.state")

function M.render_variables_pane(vars)
	if not (State.buf.variables and vim.api.nvim_buf_is_valid(State.buf.variables)) then
		return
	end
	local buf = State.buf.variables

	local SEPARATOR = " "
	local PADDING = 1

	-- 1. Calculate column widths
	local max_name_w = 4
	local max_type_w = 4

	for _, v in ipairs(vars) do
		max_name_w = math.max(max_name_w, vim.fn.strdisplaywidth(v.name))
		max_type_w = math.max(max_type_w, vim.fn.strdisplaywidth(v.type))
	end

	local function pad_str(s, w)
		local vis_w = vim.fn.strdisplaywidth(s)
		return string.rep(" ", PADDING) .. s .. string.rep(" ", w - vis_w + PADDING)
	end

	local fmt_lines = {}

	-- Header
	local header = pad_str("NAME", max_name_w) .. SEPARATOR .. pad_str("TYPE", max_type_w) .. SEPARATOR .. " VALUE"
	table.insert(fmt_lines, header)

	-- Create separator line
	local sep_len_name = max_name_w + (PADDING * 2)
	local sep_len_type = max_type_w + (PADDING * 2)
	local sep_line = string.rep("─", sep_len_name)
		.. "─"
		.. string.rep("─", sep_len_type)
		.. "─"
		.. string.rep("─", 50) -- Shorter tail for pane

	table.insert(fmt_lines, sep_line)

	if #vars == 0 then
		if not State.job_id then
			table.insert(fmt_lines, "(Kernel not started)")
		else
			table.insert(fmt_lines, "(No variables defined)")
		end
	else
		for _, v in ipairs(vars) do
			local line = pad_str(v.name, max_name_w)
				.. SEPARATOR
				.. pad_str(v.type, max_type_w)
				.. SEPARATOR
				.. " "
				.. v.info
			table.insert(fmt_lines, line)
		end
	end

	vim.api.nvim_buf_set_option(buf, "readonly", false)
	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, fmt_lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "readonly", true)

	    -- Simple highlighting
    vim.api.nvim_buf_add_highlight(buf, -1, "JovianHeader", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", 1, 0, -1)

	-- Add column highlighting
	local sep_len = #SEPARATOR
	local col1_end = sep_len_name
	local col2_end = col1_end + sep_len + sep_len_type

	for i = 2, #fmt_lines - 1 do
		if #vars > 0 then
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianVariable", i, 0, col1_end)
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianType", i, col1_end + sep_len, col2_end)
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col1_end, col1_end + sep_len)
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col2_end, col2_end + sep_len)
		end
	end
end

function M.show_variables(vars, force_float)
	-- If persistent pane is open, render there
	if State.win.variables and vim.api.nvim_win_is_valid(State.win.variables) then
		M.render_variables_pane(vars)
		vim.notify("Variables updated in pane", vim.log.levels.INFO)

		if not force_float then
			return
		end
	end

	-- Otherwise, show floating window (existing logic)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

	local SEPARATOR = " │ "
	local PADDING = 1

	-- 1. Calculate column widths (default min widths)
	local max_name_w = 4 -- Length of "NAME"
	local max_type_w = 4 -- Length of "TYPE"

	for _, v in ipairs(vars) do
		max_name_w = math.max(max_name_w, vim.fn.strdisplaywidth(v.name))
		max_type_w = math.max(max_type_w, vim.fn.strdisplaywidth(v.type))
	end

	-- Padding function
	local function pad_str(s, w)
		local vis_w = vim.fn.strdisplaywidth(s)
		return string.rep(" ", PADDING) .. s .. string.rep(" ", w - vis_w + PADDING)
	end

	local fmt_lines = {}

	-- Create header
	local header = pad_str("NAME", max_name_w)
		.. SEPARATOR
		.. pad_str("TYPE", max_type_w)
		.. SEPARATOR
		.. pad_str("VALUE/INFO", 10)

	table.insert(fmt_lines, header)

	-- Calculate max info width
	local max_info_w = 10 -- Minimum width for header "VALUE/INFO"
	for _, v in ipairs(vars) do
		max_info_w = math.max(max_info_w, vim.fn.strdisplaywidth(v.info))
	end

	-- Create separator line
	local sep_len_name = max_name_w + (PADDING * 2)
	local sep_len_type = max_type_w + (PADDING * 2)
	local sep_len_info = max_info_w + (PADDING * 2)

	local sep_line = string.rep("─", sep_len_name)
		.. "─┼─"
		.. string.rep("─", sep_len_type)
		.. "─┼─"
		.. string.rep("─", sep_len_info)

	table.insert(fmt_lines, sep_line)

	-- Create data lines
	if #vars == 0 then
		-- Empty state: Show message in the VALUE/INFO column
		local msg = State.job_id and "(No variables defined)" or "(Kernel not started)"
		local line = pad_str("", max_name_w) .. SEPARATOR .. pad_str("", max_type_w) .. SEPARATOR .. " " .. msg
		table.insert(fmt_lines, line)
	else
		for _, v in ipairs(vars) do
			local line = pad_str(v.name, max_name_w)
				.. SEPARATOR
				.. pad_str(v.type, max_type_w)
				.. SEPARATOR
				.. " "
				.. v.info
			table.insert(fmt_lines, line)
		end
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, fmt_lines)

	-- Highlight
	vim.api.nvim_buf_add_highlight(buf, -1, "JovianHeader", 0, 0, -1)
	vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", 1, 0, -1)

	local col1_end = sep_len_name
	local col2_end = col1_end + 3 + sep_len_type

	for i = 2, #fmt_lines - 1 do
		if #vars > 0 then
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianVariable", i, 0, col1_end)
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianType", i, col1_end + 3, col2_end)
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col1_end, col1_end + 3)
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col2_end, col2_end + 3)
		else
			-- Empty state highlight (Message in Comment color)
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col1_end, col1_end + 3)
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, col2_end, col2_end + 3)
			vim.api.nvim_buf_add_highlight(buf, -1, "JovianComment", i, col2_end + 3, -1)
		end
	end

	-- Window settings
	local editor_width = vim.o.columns
	local content_width = 0
	for _, line in ipairs(fmt_lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end

	local width = math.min(content_width, math.floor(editor_width * 0.9))
	local height = math.min(#fmt_lines, math.floor(vim.o.lines * 0.8))

	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = Config.options.float_border,
		title = " Jovian Variables ",
		title_pos = "center",
	})

	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true
    vim.wo[win].winblend = Config.options.ui.winblend
	vim.wo[win].winhighlight = "NormalFloat:JovianFloat,FloatBorder:JovianFloatBorder"

	local opts = { noremap = true, silent = true }
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

function M.show_profile_stats(text)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

	local lines = vim.split(text, "\n")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local width = math.floor(vim.o.columns * 0.8)
	local height = math.floor(vim.o.lines * 0.8)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = Config.options.float_border,
		title = " cProfile Stats ",
		title_pos = "center",
	})
    vim.wo[win].winblend = Config.options.ui.winblend
	vim.wo[win].winhighlight = "NormalFloat:JovianFloat,FloatBorder:JovianFloatBorder"
	local opts = { noremap = true, silent = true }
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

function M.show_dataframe(data)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	local SEPARATOR = " │ "
	local PADDING = 1

	local headers = { "" }
	for _, c in ipairs(data.columns) do
		table.insert(headers, tostring(c))
	end

	local col_widths = {}
	for i, h in ipairs(headers) do
		col_widths[i] = vim.fn.strdisplaywidth(h)
	end

	for i, row in ipairs(data.data) do
		local idx = tostring(data.index[i])
		col_widths[1] = math.max(col_widths[1], vim.fn.strdisplaywidth(idx))
		for j, val in ipairs(row) do
			local s = tostring(val)
			col_widths[j + 1] = math.max(col_widths[j + 1] or 0, vim.fn.strdisplaywidth(s))
		end
	end

	local function pad_str(s, w)
		local vis_w = vim.fn.strdisplaywidth(s)
		return string.rep(" ", PADDING) .. s .. string.rep(" ", w - vis_w + PADDING)
	end

	local fmt_lines = {}
	local header_line = ""
	for i, h in ipairs(headers) do
		header_line = header_line .. pad_str(h, col_widths[i]) .. (i < #headers and SEPARATOR or "")
	end
	table.insert(fmt_lines, header_line)

	local sep_line = ""
	for i, w in ipairs(col_widths) do
		local total_w = w + (PADDING * 2)
		sep_line = sep_line .. string.rep("─", total_w) .. (i < #headers and "─┼─" or "")
	end
	table.insert(fmt_lines, sep_line)

	for i, row in ipairs(data.data) do
		local line_str = pad_str(tostring(data.index[i]), col_widths[1]) .. SEPARATOR
		for j, val in ipairs(row) do
			line_str = line_str .. pad_str(tostring(val), col_widths[j + 1]) .. (j < #row and SEPARATOR or "")
		end
		table.insert(fmt_lines, line_str)
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, fmt_lines)
	vim.api.nvim_buf_add_highlight(buf, -1, "JovianHeader", 0, 0, -1)
	vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", 1, 0, -1)

	local index_col_width = col_widths[1] + (PADDING * 2)
	for i = 2, #fmt_lines - 1 do
		vim.api.nvim_buf_add_highlight(buf, -1, "JovianIndex", i, 0, index_col_width)
		local current_pos = 0
		for j, w in ipairs(col_widths) do
			current_pos = current_pos + w + (PADDING * 2)
			if j < #col_widths then
				vim.api.nvim_buf_add_highlight(buf, -1, "JovianSeparator", i, current_pos, current_pos + #SEPARATOR)
				current_pos = current_pos + #SEPARATOR
			end
		end
	end

	-- Calculate size based on content
	local content_width = 0
	for _, line in ipairs(fmt_lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end

	local width = math.min(content_width, math.floor(vim.o.columns * 0.9))
	local height = math.min(#fmt_lines, math.floor(vim.o.lines * 0.8))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = Config.options.float_border,
		title = " " .. data.name .. " ",
		title_pos = "center",
	})
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true
    vim.wo[win].winblend = Config.options.ui.winblend
	vim.wo[win].winhighlight = "NormalFloat:JovianFloat,FloatBorder:JovianFloatBorder"
	local opts = { noremap = true, silent = true }
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

function M.show_inspection(data)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "filetype", "python") -- For syntax highlighting

	local lines = {}
	local type_str = (data.type and data.type ~= vim.NIL) and data.type or "unknown"
	table.insert(lines, "# " .. data.name .. " (" .. type_str .. ")")
	table.insert(lines, "")

	if data.definition and data.definition ~= vim.NIL and data.definition ~= "" then
		table.insert(lines, "## Definition:")
		table.insert(lines, data.definition)
		table.insert(lines, "")
	end

	if data.docstring and data.docstring ~= vim.NIL then
		table.insert(lines, "## Docstring:")
		-- Split docstring into lines and add
		for _, l in ipairs(vim.split(data.docstring, "\n")) do
			table.insert(lines, l)
		end
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Calculate size based on content
	local content_width = 0
	for _, l in ipairs(lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
	end

	local width = math.min(content_width + 4, math.floor(vim.o.columns * 0.8))
	local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))

	-- Ensure minimum size
	width = math.max(width, 40)
	height = math.max(height, 5)

	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = Config.options.float_border,
		title = " Jovian Doc ",
		title_pos = "center",
	})
    vim.wo[win].winblend = Config.options.ui.winblend
    vim.wo[win].winhighlight = "NormalFloat:JovianFloat,FloatBorder:JovianFloatBorder"
	local opts = { noremap = true, silent = true }
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

function M.show_peek(data)
	if data.error then
		return vim.notify(data.error, vim.log.levels.WARN)
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

	local lines = {}
	table.insert(lines, "Name:  " .. data.name)
	table.insert(lines, "Type:  " .. data.type)
	table.insert(lines, "Size:  " .. data.size)
	if data.shape and data.shape ~= "" then
		table.insert(lines, "Shape: " .. data.shape)
	end
	table.insert(lines, "")
	table.insert(lines, "Value:")
	for _, l in ipairs(vim.split(data.repr, "\n")) do
		table.insert(lines, l)
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Calculate size
	local width = 0
	for _, l in ipairs(lines) do
		if #l > width then
			width = #l
		end
	end
	width = math.min(width + 4, 80)
	local height = math.min(#lines + 2, 20)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "cursor",
		width = width,
		height = height,
		row = 1,
		col = 0,
		style = "minimal",
		border = Config.options.float_border,
		title = " Jovian Peek ",
		title_pos = "center",
	})
    vim.wo[win].winblend = Config.options.ui.winblend
    vim.wo[win].winhighlight = "NormalFloat:JovianFloat,FloatBorder:JovianFloatBorder"
	local opts = { noremap = true, silent = true }
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

return M
