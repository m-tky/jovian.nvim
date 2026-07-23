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

-- Host management — discovers/persists SSH host config. When a host is
-- active, rust_kernel.start passes it to jovian-core, which owns the SSH
-- tunnel + remote kernel launch directly (no Lua-side tunneling). Restored
-- into Config.options from init.setup() via Hosts.restore_active().

local RustKernel = nil
local function rust()
    RustKernel = RustKernel or require("jovian.backend.rust_kernel")
    return RustKernel
end

-- ---------- Kernel lifecycle ----------

function M.start_kernel(on_ready)
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
    Cell.fix_duplicate_ids(0)

    if on_ready then
        table.insert(State.on_ready_callbacks, on_ready)
    end
    rust().start()
end

function M.stop_kernel()
    rust().stop()
end

function M.restart_kernel(on_ready)
    -- Bound directly to :JovianRestart, which would pass the command-opts
    -- table as the first arg — only forward an actual callback.
    if type(on_ready) ~= "function" then
        on_ready = nil
    end
    UI.append_to_repl("[Kernel Restarting...]", "WarningMsg")
    UI.clear_status_extmarks(0)
    rust().restart(on_ready)
end

function M.interrupt_kernel()
    if not State.job_id then
        return vim.notify("Kernel not running", vim.log.levels.WARN)
    end
    rust().interrupt()
end

local function with_kernel(fn)
    if State.job_id then
        fn()
    else
        M.start_kernel(fn)
    end
end

-- ---------- Cell execution ----------

function M.send_payload(code, cell_id, filename, bufnr)
    -- Capture the issuing buffer up front. When the kernel is still starting
    -- (async), the deferred re-invocation must reparse THIS buffer, not
    -- whatever the user navigated to during the startup wait.
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not State.job_id then
        with_kernel(function()
            M.send_payload(code, cell_id, filename, bufnr)
        end)
        return
    end

    local current_buf = bufnr
    State.cell_buf_map[cell_id] = current_buf
    -- hrtime() is monotonic nanoseconds since startup. Used for elapsed
    -- display in set_final; os.time() (whole seconds) was too coarse to
    -- distinguish a 50 ms cell from a 950 ms one.
    State.cell_start_time[cell_id] = (vim.uv or vim.loop).hrtime()
    State.cell_hashes[cell_id] = Cell.get_cell_hash(code)
    State.running_cells[cell_id] = true

    vim.diagnostic.reset(State.diag_ns, current_buf)
    vim.api.nvim_buf_clear_namespace(current_buf, State.diag_ns, 0, -1)
    UI.set_cell_status(current_buf, cell_id, "running", Config.options.ui_symbols.running)

    rust().execute(code, cell_id, current_buf)
end

function M.send_cell()
    if not State.job_id then
        M.start_kernel()
    end
    local s, e = Cell.get_cell_range()
    UI.flash_range(s, e)
    local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
    if #lines > 0 and lines[1]:match("^# %%%%") then
        if Cell.is_markdown_header(lines[1]) then
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

function M.send_selection()
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

function M.run_line()
    if not State.job_id then
        M.start_kernel()
    end
    local line = vim.api.nvim_get_current_line()
    if line == "" then
        return
    end
    UI.flash_range(vim.fn.line("."), vim.fn.line("."))
    -- os.time() is whole-second; rapid run-line calls within the same second
    -- collided and mixed their outputs. A random id keeps them distinct.
    local id = "line_" .. Cell.generate_id()
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

-- _execute_lines runs every code cell in `lines`. The optional `filter`
-- receives each cell's tag list and returns true to include it — used by
-- :JovianRunOnly / :JovianRunAllExcept. nil means "no filter, run all".
function M._execute_lines(lines, filter)
    local fn = vim.fn.expand("%:t")
    local cells_to_run = {}
    local blk, current_bid, current_tags, is_code = {}, nil, {}, false

    local function flush()
        if #blk > 0 and is_code and current_bid and (not filter or filter(current_tags)) then
            table.insert(cells_to_run, { code = table.concat(blk, "\n"), id = current_bid })
        end
    end

    for i, line in ipairs(lines) do
        if line:match("^# %%%%") then
            flush()
            blk = {}
            current_bid = Cell.ensure_cell_id(i, line)
            current_tags = Cell.parse_header_tags(line)
            is_code = not Cell.is_markdown_header(line)
        elseif is_code then
            table.insert(blk, line)
        end
    end
    flush()

    if #cells_to_run == 0 then
        return
    end

    -- Set up batch tracking for multi-cell runs. set_final ticks `done` per
    -- cell completion and emits a final summary when done == total. Single-
    -- cell runs (:JovianRun) skip this so a normal cell doesn't get a
    -- "1/1 done" notification.
    if #cells_to_run > 1 then
        local pending = {}
        for _, c in ipairs(cells_to_run) do
            pending[c.id] = true
        end
        State.batch = {
            total = #cells_to_run,
            done = 0,
            started_at_ns = (vim.uv or vim.loop).hrtime(),
            pending = pending,
        }
        vim.notify(("jovian: running %d cells"):format(#cells_to_run), vim.log.levels.INFO)
    end

    for _, cell in ipairs(cells_to_run) do
        M.send_payload(cell.code, cell.id, fn)
    end
end

function M.run_all_cells()
    with_kernel(function()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        M._execute_lines(lines)
    end)
end

-- Run only cells whose tag list intersects `wanted` (set of tag strings).
function M.run_only_tagged(wanted)
    with_kernel(function()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        M._execute_lines(lines, function(tags)
            for _, t in ipairs(tags) do
                if wanted[t] then
                    return true
                end
            end
            return false
        end)
    end)
end

-- Run every cell whose tag list does NOT intersect `excluded`.
function M.run_all_except_tagged(excluded)
    with_kernel(function()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        M._execute_lines(lines, function(tags)
            for _, t in ipairs(tags) do
                if excluded[t] then
                    return false
                end
            end
            return true
        end)
    end)
end

function M.run_cells_above()
    with_kernel(function()
        local cursor_line = vim.fn.line(".")
        local cur_s, _ = Cell.get_cell_range(cursor_line)
        local lines = vim.api.nvim_buf_get_lines(0, 0, cur_s - 1, false)
        M._execute_lines(lines)
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
        local limit = (args and type(args) == "table") and args.limit or Config.options.dataframe_page_size
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
                with_kernel(function()
                    rust().eval(input)
                end)
            end
        end)
        return
    end
    with_kernel(function()
        rust().eval(code)
    end)
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

-- NOTE: persisted host config is restored from init.setup() via
-- Hosts.restore_active(), AFTER Config.setup() rebuilds the options table.
-- A previous module-load-time vim.schedule restore raced that rebuild and
-- got clobbered (and never restored remote_cwd).

return M
