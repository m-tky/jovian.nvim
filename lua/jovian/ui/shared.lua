local M = {}
local Config = require("jovian.config")
local State = require("jovian.state")

function M.send_notification(msg, level)
    level = level or "info"
    local mode = Config.options.notify_mode

    if mode == "none" then
        return
    end
    if mode == "error" and level ~= "error" then
        return
    end

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
    local ok, err = pcall(vim.api.nvim_chan_send, State.term_chan, output)
    if not ok then
        if string.match(err, "E900") then
            -- Invalid channel, try to recover if buffer exists
            if State.buf.output and vim.api.nvim_buf_is_valid(State.buf.output) then
                State.term_chan = vim.api.nvim_open_term(State.buf.output, {})
                -- Retry send
                pcall(vim.api.nvim_chan_send, State.term_chan, output)
            end
        else
            -- Re-raise other errors
            error(err)
        end
    end

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

    local function ends_with_newline(str)
        if not str or str == "" then
            return false
        end
        -- Strip ANSI codes (simple approximation for CSI codes)
        local stripped = str:gsub("\27%[[0-9;]*m", "")
        -- Only consider \n as newline. \r means cursor is at start of line,
        -- so we need to inject \n to preserve the line content.
        return stripped:sub(-1) == "\n"
    end

    -- Fix for tqdm: If switching from stderr (no newline) to stdout, inject newline
    if stream_type == "stdout" and State.last_stream_type == "stderr" then
        if not ends_with_newline(State.last_stream_tail) then
            text = "\r\n" .. text
        end
    end

    -- Update state
    State.last_stream_type = stream_type
    if #text > 0 then
        -- Keep last 50 chars to capture potential newlines hidden by ANSI codes
        local tail = text
        if #tail > 50 then
            tail = tail:sub(-50)
        end
        State.last_stream_tail = tail
    end

    local clean_text = text:gsub("\n", "\r\n")

    -- Red for stderr
    if stream_type == "stderr" then
        local RED = "\x1b[31m"
        local RESET = "\x1b[0m"
        clean_text = RED .. clean_text .. RESET
    end

    local ok, err = pcall(vim.api.nvim_chan_send, State.term_chan, clean_text)
    if not ok then
        if string.match(err, "E900") then
            -- Invalid channel, try to recover if buffer exists
            if State.buf.output and vim.api.nvim_buf_is_valid(State.buf.output) then
                State.term_chan = vim.api.nvim_open_term(State.buf.output, {})
                -- Retry send
                pcall(vim.api.nvim_chan_send, State.term_chan, clean_text)
            end
        else
            -- Re-raise other errors
            error(err)
        end
    end

    if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
        local buf = State.buf.output
        local count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_win_set_cursor(State.win.output, { count, 0 })
    end
end

return M
