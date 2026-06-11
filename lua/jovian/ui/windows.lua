local M = {}
local State = require("jovian.state")

-- Get (or create) a plain scratch buffer by name. Used for the preview /
-- pin / variables panes, which are rendered via nvim_buf_set_lines — NOT
-- terminals. This must NOT touch State.term_chan: doing so (the previous
-- behavior) hijacked the REPL's terminal channel so kernel output leaked
-- into whichever pane was created last (e.g. :JovianPin). The output
-- terminal is owned solely by ensure_output_buf below.
function M.get_or_create_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
        return existing
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = false

    return buf
end

-- The REPL output buffer is the ONE terminal buffer; it and its channel are
-- held as a pair (State.buf.output, State.term_chan). Create/reuse the
-- buffer and (re)open its terminal channel, returning both. Centralizing
-- the open_term here means no other pane can clobber term_chan, and a
-- detached channel can always be rebuilt against the right buffer.
function M.ensure_output_buf()
    local buf = State.buf.output
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        buf = M.get_or_create_buf("JovianOutput")
        State.buf.output = buf
        State.term_chan = nil -- fresh buffer ⇒ needs a fresh channel
    end
    if not State.term_chan then
        State.term_chan = vim.api.nvim_open_term(buf, {})
    end
    return State.buf.output, State.term_chan
end

function M.placeholder_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "No pinned content" })
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = false
    return buf
end

function M.apply_window_options(win, opts)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end

    local defaults = {
        number = false,
        relativenumber = false,
        signcolumn = "no",
        foldcolumn = "0",
        wrap = true,
        fillchars = "eob: ",
    }

    opts = vim.tbl_extend("force", defaults, opts or {})

    for k, v in pairs(opts) do
        vim.wo[win][k] = v
    end
end

function M.close_windows()
    local wins = { State.win.preview, State.win.output, State.win.variables, State.win.pin }
    for _, win in pairs(wins) do
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    State.win.preview = nil
    State.win.output = nil
    State.win.variables = nil
    State.win.pin = nil
end

-- Pin a cell's output into the pin window. Reads the sidecar JSON
-- directly via output_render — the previous .md-per-cell path was the
-- Python bridge's job and is gone.
function M.pin_cell(src_path, cell_id)
    State.current_pin = { src = vim.fn.fnamemodify(src_path, ":p"), cell_id = cell_id }
    if not (State.win.pin and vim.api.nvim_win_is_valid(State.win.pin)) then
        return
    end
    if not (State.buf.pin and vim.api.nvim_buf_is_valid(State.buf.pin)) then
        State.buf.pin = M.get_or_create_buf("JovianPin")
    end
    vim.api.nvim_win_set_buf(State.win.pin, State.buf.pin)
    M.apply_window_options(State.win.pin, { wrap = true })
    require("jovian.ui.output_render").render_to_buffer(
        State.buf.pin,
        State.win.pin,
        State.current_pin.src,
        State.current_pin.cell_id
    )
end

function M.unpin()
    State.current_pin = nil
    if State.win.pin and vim.api.nvim_win_is_valid(State.win.pin) then
        vim.api.nvim_win_set_buf(State.win.pin, M.placeholder_buf())
        M.apply_window_options(State.win.pin, { wrap = true })
    end
end

function M.create_float_window(buf, title, opts)
    local width = opts.width or math.floor(vim.o.columns * 0.8)
    local height = opts.height or math.floor(vim.o.lines * 0.8)
    local row = opts.row or math.floor((vim.o.lines - height) / 2)
    local col = opts.col or math.floor((vim.o.columns - width) / 2)

    local win_opts = {
        relative = opts.relative or "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = require("jovian.config").options.float_border,
        title = title and (" " .. title .. " ") or nil,
        title_pos = "center",
    }

    local win = vim.api.nvim_open_win(buf, true, win_opts)

    local Config = require("jovian.config")
    if Config.options.ui.winblend then
        vim.wo[win].winblend = Config.options.ui.winblend
    end
    vim.wo[win].winhighlight = "NormalFloat:JovianFloat,FloatBorder:JovianFloatBorder"

    local key_opts = { noremap = true, silent = true }
    vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", key_opts)
    vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", key_opts)

    return win
end

return M
