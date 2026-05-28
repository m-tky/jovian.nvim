-- jovian's kernel-control surface. After Phase 5 every method delegates
-- to the Rust backend (`jovian.backend.rust_kernel`); the legacy
-- kernel_bridge.py + libzmq FFI path was removed. The shape of the API
-- (start_kernel / send_payload / send_cell / show_variables / etc.) is
-- kept intact so commands.lua and the UI stay unchanged.

local M = {}
local State = require("jovian.state")
local Config = require("jovian.config")
local UI = require("jovian.ui")
local Cell = require("jovian.cell")

-- Host management — only used for SSH config persistence at the moment.
-- Remote-kernel routing through SSH tunnel will return in a later phase
-- with the Rust core handling the wire setup directly.
local Hosts = require("jovian.hosts")

local RustKernel = nil
local function rust()
    RustKernel = RustKernel or require("jovian.backend.rust_kernel")
    return RustKernel
end

-- "Is the jovian UI set up?" The Output window is now on-demand, so this
-- checks the persistent panels (preview / output / variables / pin) — any
-- one being open means :JovianOpen has run and results have somewhere to go
-- (inline rendering aside).
local function is_window_open()
    for _, win in ipairs({
        State.win.preview,
        State.win.output,
        State.win.variables,
        State.win.pin,
    }) do
        if win and vim.api.nvim_win_is_valid(win) then
            return true
        end
    end
    return false
end

-- ---------- Kernel lifecycle ----------

function M.start_kernel(on_ready)
    if type(on_ready) ~= "function" then on_ready = nil end

    if State.job_id then
        if on_ready then on_ready() end
        return
    end

    if State.is_starting_kernel then
        if on_ready then
            table.insert(State.on_ready_callbacks, on_ready)
        end
        return
    end

    State.is_starting_kernel = true
    Cell.fix_duplicate_ids(0)

    if on_ready then
        table.insert(State.on_ready_callbacks, on_ready)
    end
    rust().start()
end

function M.stop_kernel()
    rust().stop()
    require("jovian.tunnel").stop()
end

function M.restart_kernel()
    UI.append_to_repl("[Kernel Restarting...]", "WarningMsg")
    UI.clear_status_extmarks(0)
    rust().restart()
end

function M.interrupt_kernel()
    if not State.job_id then
        return vim.notify("Kernel not running", vim.log.levels.WARN)
    end
    rust().interrupt()
end

local function with_kernel(fn)
    if State.job_id then fn() else M.start_kernel(fn) end
end

-- ---------- Cell execution ----------

function M.send_payload(code, cell_id, filename)
    if not State.job_id then
        with_kernel(function() M.send_payload(code, cell_id, filename) end)
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

    rust().execute(code, cell_id)
end

function M.send_cell()
    if not is_window_open() then
        return vim.notify(
            "Jovian windows are closed. Use :JovianOpen or :JovianToggle first.",
            vim.log.levels.WARN
        )
    end
    if not State.job_id then M.start_kernel() end
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
    if fn == "" then fn = "untitled" end
    M.send_payload(table.concat(lines, "\n"), id, fn)
end

function M.send_selection()
    if not is_window_open() then
        return vim.notify("Jovian windows are closed.", vim.log.levels.WARN)
    end
    if not State.job_id then M.start_kernel() end
    local _, csrow, _, _ = unpack(vim.fn.getpos("'<"))
    local _, cerow, _, _ = unpack(vim.fn.getpos("'>"))
    local lines = vim.api.nvim_buf_get_lines(0, csrow - 1, cerow, false)
    if #lines == 0 then return end
    UI.flash_range(csrow, cerow)
    local id = Cell.get_current_cell_id(csrow, true)
    local fn = vim.fn.expand("%:t")
    if fn == "" then fn = "untitled" end
    M.send_payload(table.concat(lines, "\n"), id, fn)
end

function M.run_line()
    if not is_window_open() then
        return vim.notify("Jovian windows are closed.", vim.log.levels.WARN)
    end
    if not State.job_id then M.start_kernel() end
    local line = vim.api.nvim_get_current_line()
    if line == "" then return end
    UI.flash_range(vim.fn.line("."), vim.fn.line("."))
    local id = "line_" .. os.time()
    local fn = vim.fn.expand("%:t")
    M.send_payload(line, id, fn)
end

function M.run_and_next()
    M.send_cell()
    local _, e = Cell.get_cell_range()
    local total = vim.api.nvim_buf_line_count(0)
    if e < total then
        vim.api.nvim_win_set_cursor(0, { e + 1, 0 })
    end
end

function M._execute_lines(lines, batch_name)
    local fn = vim.fn.expand("%:t")
    local cells_to_run = {}
    local blk, current_bid, is_code = {}, nil, false

    for i, line in ipairs(lines) do
        if line:match("^# %%%%") then
            if #blk > 0 and is_code and current_bid then
                table.insert(cells_to_run, { code = table.concat(blk, "\n"), id = current_bid })
            end
            blk = {}
            current_bid = Cell.ensure_cell_id(i, line)
            is_code = not line:lower():find("# %% [markdown]", 1, true)
        elseif is_code then
            table.insert(blk, line)
        end
    end
    if #blk > 0 and is_code and current_bid then
        table.insert(cells_to_run, { code = table.concat(blk, "\n"), id = current_bid })
    end

    if #cells_to_run == 0 then return end

    if batch_name then
        State.batch_execution = {
            total = #cells_to_run,
            current = 0,
            start_time = os.time(),
            name = batch_name,
        }
    end

    for _, cell in ipairs(cells_to_run) do
        M.send_payload(cell.code, cell.id, fn)
    end
end

function M.run_all_cells()
    if not is_window_open() then return end
    with_kernel(function()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        M._execute_lines(lines, "RunAll")
    end)
end

function M.run_cells_above()
    if not is_window_open() then return end
    with_kernel(function()
        local cursor_line = vim.fn.line(".")
        local cur_s, _ = Cell.get_cell_range(cursor_line)
        local lines = vim.api.nvim_buf_get_lines(0, 0, cur_s - 1, false)
        M._execute_lines(lines, "RunCellsAbove")
    end)
end

-- ---------- Variable inspection / DataFrame view ----------

function M.show_variables(opts)
    opts = opts or {}
    with_kernel(function()
        rust().show_variables(opts)
    end)
end

function M.view_dataframe(args)
    with_kernel(function()
        local name = type(args) == "table" and args.args or args
        local offset = (args and type(args) == "table") and args.offset or 0
        local limit = (args and type(args) == "table") and args.limit
            or Config.options.dataframe_page_size
        rust().view_dataframe({ name = name, offset = offset, limit = limit })
    end)
end

function M.view_dataframe_page(var_name, offset, limit)
    M.view_dataframe({ args = var_name, offset = offset, limit = limit })
end

-- Quick-eval in the Output window. Runs in the live kernel (sees all
-- cell-defined variables) but with store_history=false, so it neither
-- bumps Out[N] nor leaves a trace in the cell sidecar.
function M.eval(code)
    if not code or vim.trim(code) == "" then
        vim.ui.input({ prompt = "eval> " }, function(input)
            if input and vim.trim(input) ~= "" then
                with_kernel(function() rust().eval(input) end)
            end
        end)
        return
    end
    with_kernel(function() rust().eval(code) end)
end

-- Continuous REPL session in the Output window: prompt → run → re-prompt.
-- Submitting an empty line (or cancelling) exits. This is the replacement
-- for the old :JovianREPL (jupyter console), reusing the in-Output eval
-- so there's no jupyter-console dependency.
function M.eval_repl()
    with_kernel(function()
        local function step()
            vim.ui.input({ prompt = "eval> " }, function(input)
                if not input or vim.trim(input) == "" then
                    return -- empty / <Esc> ends the session
                end
                rust().eval(input, function()
                    vim.schedule(step) -- loop for the next expression
                end)
            end)
        end
        step()
    end)
end

-- ---------- Error diagnostics ----------

function M.show_error_diagnostics(bufnr, cell_id, error_info)
    local start_line = State.cell_start_line[cell_id] or 1
    local err_line = error_info.line or 1
    local target_line = (start_line - 1) + (err_line - 1)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if target_line >= line_count then target_line = line_count - 1 end
    if target_line < 0 then target_line = 0 end
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

-- ---------- Init ----------

-- Load any stored host config (legacy ssh/tunnel). The Rust path doesn't
-- consume these directly yet, but the wizard / status commands still do.
vim.schedule(function()
    local ok, data = pcall(Hosts.load_hosts)
    if ok and data.current and data.configs[data.current] then
        local cfg = data.configs[data.current]
        if cfg.type == "ssh" then
            Config.options.ssh_host = cfg.host
            Config.options.ssh_python = cfg.python
            Config.options.connection_file = nil
            Config.options.python_interpreter = cfg.python
        elseif cfg.type == "connection" then
            Config.options.ssh_host = nil
            Config.options.ssh_python = nil
            Config.options.connection_file = cfg.connection_file
            Config.options.python_interpreter = cfg.python
        else
            Config.options.ssh_host = nil
            Config.options.ssh_python = nil
            Config.options.connection_file = nil
            Config.options.python_interpreter = cfg.python
        end
    end
end)

return M
