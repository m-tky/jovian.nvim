local M = {}
local Config = require("jovian.config")
local State = require("jovian.state")

function M.send_notification(msg, level)
    level = level or "info"
    local mode = Config.options.notify_mode
    
    if mode == "none" then return end
    if mode == "error" and level ~= "error" then return end

	if vim.fn.executable("notify-send") == 1 then
		vim.fn.jobstart({ "notify-send", "Jovian Task Finished", msg }, { detach = true })
	elseif vim.fn.executable("osascript") == 1 then
		vim.fn.jobstart(
			{ "osascript", "-e", 'display notification "' .. msg .. '" with title "Jovian"' },
			{ detach = true }
		)
	else
        local log_level = level == "error" and vim.log.levels.ERROR or vim.log.levels.INFO
		vim.notify(msg, log_level)
	end
end

function M.append_to_repl(text, hl_group)
	if not State.term_chan then
		return
	end

	local lines = type(text) == "table" and text or vim.split(text, "\n")
	local output = ""

	-- ANSI Color Code Definitions
	local RESET = "\x1b[0m"
	local BOLD = "\x1b[1m"
	local GREEN = "\x1b[32m"
	local BLUE = "\x1b[34m"
	local CYAN = "\x1b[36m"
	local YELLOW = "\x1b[33m"
	local GREY = "\x1b[90m"

	local color_start = ""
	local color_end = RESET

	if hl_group == "Type" then
		-- Prompt (In [abc]:) -> Green & Bold
		color_start = GREEN .. BOLD

		-- Tip: Insert a faint separator line before the prompt
		-- This makes the boundary with previous results clear
		output = output .. GREY .. string.rep("─", 40) .. RESET .. "\r\n"
	elseif hl_group == nil then
		-- Code body (no hl_group) -> Cyan (Distinguishable!)
		color_start = CYAN
	elseif hl_group == "Special" then
		-- Image save notification etc. -> Blue
		color_start = BLUE
	elseif hl_group == "WarningMsg" then
		-- Warning -> Yellow
		color_start = YELLOW
	elseif hl_group == "Comment" then
		-- Completion notification etc. -> Grey
		color_start = GREY
	end

	for _, line in ipairs(lines) do
		output = output .. color_start .. line .. color_end .. "\r\n"
	end

	-- Send to terminal
	vim.api.nvim_chan_send(State.term_chan, output)

	-- Auto-scroll
	if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
		local buf = State.buf.output
		local count = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_win_set_cursor(State.win.output, { count, 0 })
	end
end

function M.append_stream_text(text, stream_type)
	if not State.term_chan then
		return
	end

	-- nvim_open_term handles \r and \n automatically,
	-- so just send it as is!

	-- However, converting Unix newline (\n) to terminal newline (\r\n) prevents display issues
	-- (IPython often sends \r\n already, but just in case)
	local clean_text = text:gsub("\n", "\r\n")

	-- Red for stderr
	if stream_type == "stderr" then
		local RED = "\x1b[31m"
		local RESET = "\x1b[0m"
		clean_text = RED .. clean_text .. RESET
	end

	vim.api.nvim_chan_send(State.term_chan, clean_text)

	if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
		local buf = State.buf.output
		local count = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_win_set_cursor(State.win.output, { count, 0 })
	end
end

return M
