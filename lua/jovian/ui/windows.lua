local M = {}
local State = require("jovian.state")

function M.get_or_create_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
        return existing
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = false

    State.term_chan = vim.api.nvim_open_term(buf, {})

    return buf
end

function M.placeholder_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "No pinned content" })
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = false
    return buf
end

local function cleanup_buffer(old_buf, current_buf)
    if old_buf and old_buf ~= current_buf and vim.api.nvim_buf_is_valid(old_buf) then
        if vim.api.nvim_buf_get_option(old_buf, "modified") then
            return
        end

        local buf_name = vim.api.nvim_buf_get_name(old_buf)
        local is_jovian_cache = buf_name:find(".jovian_cache", 1, true)
        local buftype = vim.bo[old_buf].buftype
        local is_ephemeral = (buftype == "nofile" or buftype == "terminal")

        if not (is_jovian_cache or is_ephemeral) then
            return
        end

        local wins = vim.fn.win_findbuf(old_buf)
        if #wins == 0 then
            vim.api.nvim_buf_delete(old_buf, { force = true })
        end
    end
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

local function load_markdown_into_window(win, filepath)
    local old_buf = vim.api.nvim_win_get_buf(win)
    local abs_path = vim.fn.fnamemodify(filepath, ":p")

    local buf = vim.fn.bufadd(abs_path)
    if buf == 0 then
        return nil
    end

    if not vim.api.nvim_buf_is_loaded(buf) then
        vim.fn.bufload(buf)
    else
        vim.cmd("checktime " .. buf)
    end

    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].buftype = ""
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    M.apply_window_options(win, { wrap = true })
    cleanup_buffer(old_buf, buf)
    return abs_path
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

function M.open_markdown_preview(filepath)
    if not (State.win.preview and vim.api.nvim_win_is_valid(State.win.preview)) then
        return
    end
    State.current_preview_file = load_markdown_into_window(State.win.preview, filepath)
end

function M.pin_cell(filepath)
    State.current_pin_file = vim.fn.fnamemodify(filepath, ":p")
    if State.win.pin and vim.api.nvim_win_is_valid(State.win.pin) then
        load_markdown_into_window(State.win.pin, filepath)
    end
end

function M.unpin()
    State.current_pin_file = nil

    if State.win.pin and vim.api.nvim_win_is_valid(State.win.pin) then
        local old_buf = vim.api.nvim_win_get_buf(State.win.pin)
        local buf = M.placeholder_buf()
        vim.api.nvim_win_set_buf(State.win.pin, buf)
        M.apply_window_options(State.win.pin, { wrap = true })
        cleanup_buffer(old_buf, buf)
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
