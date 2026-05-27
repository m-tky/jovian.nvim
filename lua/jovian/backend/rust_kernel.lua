-- Phase 1 wrapper: route kernel lifecycle and cell execution through the
-- jovian-core Rust backend. Active only when config.use_rust_core == true.
--
-- What this path handles end-to-end:
--   - kernel spawn / shutdown / interrupt / restart
--   - per-cell execute, with cell_id ↔ msg_id routing owned by the Rust side
--   - REPL stream/result/error rendering (UI.append_stream_text / append_to_repl)
--   - cell status virtual text (running / done / error)
--
-- What it does NOT yet handle (falls back or warns):
--   - variable inspection / dataframe view / clipboard / image saving
--   - SSH/tunnel kernels (currently localhost ipykernel only)
--   - Markdown preview window content (the bridge wrote .md files; Phase 4
--     replaces that with structured rendering from the sidecar JSON)

local Core = require("jovian.backend.core")
local State = require("jovian.state")
local UI = require("jovian.ui")
local Config = require("jovian.config")

local M = {}

local _event_handler_registered = false
-- Per-execution flag: an `error` event arrived between execute_input and the
-- final reply, so we should land the cell in "error" state when the reply hits.
local _cell_had_error = {}

local function strip_ansi(s)
    if not s then return "" end
    s = s:gsub("\27%[[?]?[%d;]*[a-zA-Z]", "")
    s = s:gsub("\27%][^\27]*\27\\", "")
    return s
end

local function set_busy(cell_id)
    local buf = State.cell_buf_map[cell_id]
    if buf and vim.api.nvim_buf_is_valid(buf) then
        UI.set_cell_status(buf, cell_id, "running", Config.options.ui_symbols.running)
    end
end

local function set_final(cell_id, errored)
    local buf = State.cell_buf_map[cell_id]
    if buf and vim.api.nvim_buf_is_valid(buf) then
        local timestamp = ""
        if Config.options.show_execution_time then
            timestamp = " (" .. os.date("%H:%M:%S") .. ")"
        end
        if errored then
            UI.set_cell_status(buf, cell_id, "error", Config.options.ui_symbols.error .. timestamp)
            UI.send_notification("Error in cell " .. cell_id, "error")
        else
            UI.set_cell_status(buf, cell_id, "done", Config.options.ui_symbols.done .. timestamp)
        end
    end
    State.running_cells[cell_id] = nil
    State.cell_buf_map[cell_id] = nil
    State.cell_start_time[cell_id] = nil
    _cell_had_error[cell_id] = nil
end

-- Trigger a debounced cell_frame re-render whenever an output-bearing
-- event arrives, so the inline output block grows in near-real-time as
-- the kernel streams. Also push the freshest cell into the side preview
-- buffer if it's the one currently being shown.
local function refresh_inline_outputs(cell_id)
    local buf = State.cell_buf_map[cell_id]
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    local src_path = vim.api.nvim_buf_get_name(buf)
    local OutRender = require("jovian.ui.output_render")
    OutRender.invalidate(src_path)

    if Config.options.inline_outputs and Config.options.cell_frame then
        require("jovian.ui.cell_frame").schedule(buf)
    end

    -- Refresh preview if the focused cell is the one in the preview pane.
    if State.current_preview_cell_id == cell_id
        and State.buf.preview
        and vim.api.nvim_buf_is_valid(State.buf.preview)
    then
        OutRender.render_to_buffer(
            State.buf.preview,
            State.win.preview,
            src_path,
            cell_id
        )
    end
end

local function on_cell_event(params)
    local cell_id = params and params.cell_id
    if not cell_id then return end
    local ev = params.event or {}
    local kind = ev.kind

    if kind == "execute_input" then
        _cell_had_error[cell_id] = false
        UI.append_to_repl({ "In [" .. cell_id .. "]:" }, "Type")
        if type(ev.code) == "string" and ev.code ~= "" then
            local indented = {}
            for _, l in ipairs(vim.split(ev.code, "\n")) do
                table.insert(indented, "    " .. l)
            end
            UI.append_to_repl(indented)
            UI.append_to_repl({ "" })
        end
        set_busy(cell_id)
    elseif kind == "stream" then
        UI.append_stream_text(ev.text or "", ev.name or "stdout")
        refresh_inline_outputs(cell_id)
    elseif kind == "execute_result" or kind == "display_data" then
        local data = ev.data or {}
        local tp = data["text/plain"]
        local has_img = data["image/png"] or data["image/gif"] or data["image/jpeg"]
        -- Suppress matplotlib's "<Figure size NxM with K Axes>" / generic
        -- "<X object at 0x...>" repr when an image is the real payload —
        -- the inline cell area shows the picture, the REPL line would
        -- just be noise.
        if has_img and type(tp) == "string"
            and (tp:match("^<Figure ")
                or tp:match("^<[%w._]+ object>$")
                or tp:match("^<[%w._]+ object at 0x[%x]+>$"))
        then
            UI.append_to_repl("[image]", "Special")
        elseif type(tp) == "string" and tp ~= "" then
            UI.append_to_repl(vim.split(tp, "\n"), "Identifier")
        end
        refresh_inline_outputs(cell_id)
    elseif kind == "error" then
        _cell_had_error[cell_id] = true
        local head = (ev.ename or "Error") .. ": " .. (ev.evalue or "")
        UI.append_to_repl(head, "ErrorMsg")
        for _, tb in ipairs(ev.traceback or {}) do
            for _, line in ipairs(vim.split(strip_ansi(tb), "\n")) do
                UI.append_to_repl(line, "ErrorMsg")
            end
        end
        refresh_inline_outputs(cell_id)
    elseif kind == "execute_reply" then
        set_final(cell_id, ev.status == "error" or _cell_had_error[cell_id])
        refresh_inline_outputs(cell_id)
    end
    -- status (busy/idle), update_display_data, kernel_info, clear_output: no-op for Phase 1
end

local function ensure_event_handler()
    if _event_handler_registered then return end
    local client = Core.client()
    if not client then return end
    client:on("cell_event", on_cell_event)
    _event_handler_registered = true
end

local function session_path()
    local p = vim.api.nvim_buf_get_name(0)
    if p == "" then
        p = vim.fn.getcwd() .. "/scratchpad.py"
    end
    return p
end

local function looks_like_path(p)
    return p and (p:match("/") or p:match("^%a:[/\\]"))
end

--- Spawn the kernel via jovian-core. Calls `on_ready()` when the kernel is up.
function M.start(on_ready)
    local client = Core.ensure()
    ensure_event_handler()

    client:request("open", { path = session_path() }, function(err, result)
        if err then
            vim.schedule(function()
                State.is_starting_kernel = false
                vim.notify("jovian-core open failed: " .. err, vim.log.levels.ERROR)
            end)
            return
        end
        local sid = result.session_id
        local args = { session_id = sid }
        if looks_like_path(Config.options.python_interpreter) then
            args.python_path = Config.options.python_interpreter
        end
        client:request("start_kernel", args, function(err2, _)
            vim.schedule(function()
                State.is_starting_kernel = false
                if err2 then
                    vim.notify("jovian-core start_kernel failed: " .. err2, vim.log.levels.ERROR)
                    return
                end
                State.rust_session_id = sid
                State.rust_active = true
                -- Sentinel so legacy `if State.job_id` gates still pass. NEVER
                -- pass this value to vim.fn.jobstop/jobpid — branch on
                -- State.rust_active first.
                State.job_id = "rust"
                if on_ready then pcall(on_ready) end
                for _, cb in ipairs(State.on_ready_callbacks) do pcall(cb) end
                State.on_ready_callbacks = {}
            end)
        end)
    end)
end

--- Send a cell's code to the kernel. Caller must have set up State.cell_buf_map
--- and friends BEFORE calling — same contract as the legacy send_payload.
function M.execute(_code, cell_id)
    local client = Core.client()
    if not client or not State.rust_session_id then
        vim.notify("jovian-core not started", vim.log.levels.WARN)
        return
    end
    -- Sync the current buffer text so the Rust side has up-to-date cell models
    -- (including any newly-inserted cells / freshly-assigned ids).
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    client:notify("reparse", { session_id = State.rust_session_id, text = text })
    client:request("execute", {
        session_id = State.rust_session_id,
        cell_id = cell_id,
    }, function(err, _)
        if err then
            vim.schedule(function()
                vim.notify("jovian-core execute failed: " .. err, vim.log.levels.ERROR)
                set_final(cell_id, true)
            end)
        end
    end)
end

function M.interrupt()
    local client = Core.client()
    if not client or not State.rust_session_id then return end
    client:notify("interrupt_kernel", { session_id = State.rust_session_id })
    UI.append_to_repl("[Kernel Interrupted!]", "WarningMsg")
    for cell_id, buf in pairs(State.cell_buf_map) do
        if buf and vim.api.nvim_buf_is_valid(buf) then
            UI.set_cell_status(buf, cell_id, "error", Config.options.ui_symbols.interrupted)
        end
    end
    State.cell_buf_map = {}
    State.running_cells = {}
end

function M.stop()
    local client = Core.client()
    if client and State.rust_session_id then
        client:notify("close", { session_id = State.rust_session_id })
    end
    State.rust_active = false
    State.rust_session_id = nil
    State.job_id = nil
end

function M.restart(on_ready)
    M.stop()
    vim.defer_fn(function() M.start(on_ready) end, 200)
end

return M
