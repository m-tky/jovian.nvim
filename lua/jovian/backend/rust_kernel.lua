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
local strip_ansi = require("jovian.ui.shared").strip_ansi

local M = {}

-- The client object our cell_event/kernel_event/on_exit handlers are bound
-- to. After a core crash + respawn the client is a NEW object, so comparing
-- against it (rather than a one-shot boolean) re-registers handlers on the
-- fresh client instead of silently leaving the new core handler-less.
local _handlers_client = nil
-- Per-execution flag: an `error` event arrived between execute_input and the
-- final reply, so we should land the cell in "error" state when the reply hits.
local _cell_had_error = {}

-- Per-cell completion gating. Jupyter's rule: a cell is "done" once we
-- have BOTH `execute_reply` on shell AND `status: idle` on iopub (with
-- matching parent_msg_id). The two events arrive in arbitrary order
-- because they're on separate sockets, and trailing iopub messages
-- (stream chunks, execute_result) can land AFTER execute_reply but
-- BEFORE idle. If we fire set_final on execute_reply alone, the UI
-- flips to "Done" while the last lines of output are still arriving.
-- Track both signals and finalize only when both are in.
local _cell_done_state = {}

local function set_busy(cell_id)
    local buf = State.cell_buf_map[cell_id]
    if buf and vim.api.nvim_buf_is_valid(buf) then
        UI.set_cell_status(buf, cell_id, "running", Config.options.ui_symbols.running)
    end
end

-- Render an hrtime-delta (nanoseconds) into a compact "1.3s" / "230ms" /
-- "5m12s" string. The thresholds pick the unit that gives a 1-3 digit
-- significand, matching Jupyter's "Wall time" output style.
local function format_elapsed_ns(ns)
    if not ns then
        return nil
    end
    local seconds = ns / 1e9
    if seconds < 1 then
        return ("%dms"):format(math.floor(seconds * 1000 + 0.5))
    elseif seconds < 60 then
        return ("%.1fs"):format(seconds)
    else
        local m = math.floor(seconds / 60)
        local s = math.floor(seconds % 60)
        return ("%dm%ds"):format(m, s)
    end
end

local function set_final(cell_id, errored)
    local buf = State.cell_buf_map[cell_id]
    local started_at = State.cell_start_time[cell_id]
    local elapsed_ns = started_at and ((vim.uv or vim.loop).hrtime() - started_at) or nil
    if buf and vim.api.nvim_buf_is_valid(buf) then
        local timestamp = ""
        if Config.options.show_execution_time and elapsed_ns then
            timestamp = " (" .. format_elapsed_ns(elapsed_ns) .. ")"
        end
        if errored then
            UI.set_cell_status(buf, cell_id, "error", Config.options.ui_symbols.error .. timestamp)
            UI.send_notification("Error in cell " .. cell_id, "error")
        else
            UI.set_cell_status(buf, cell_id, "done", Config.options.ui_symbols.done .. timestamp)
        end
    end
    -- Desktop notification for long-running cells: fires when the elapsed
    -- wall-clock time crosses notify_threshold (seconds). Errors are
    -- notified above unconditionally, so only the success path needs gating.
    local threshold = Config.options.notify_threshold
    if not errored and elapsed_ns and threshold and threshold > 0 and elapsed_ns / 1e9 >= threshold then
        UI.send_notification(("Cell %s done in %s"):format(cell_id, format_elapsed_ns(elapsed_ns)), "info")
    end
    -- Batch run progress: emit a final summary when the last cell of a
    -- :JovianRunAll / :JovianRunAbove finishes. Per-cell progress is
    -- intentionally NOT emitted — the inline status extmarks already
    -- show every cell's state; another notification stream would just be
    -- noise.
    if State.batch and State.batch.pending[cell_id] then
        State.batch.pending[cell_id] = nil
        State.batch.done = State.batch.done + 1
        if State.batch.done == State.batch.total then
            local batch_elapsed_ns = (vim.uv or vim.loop).hrtime() - State.batch.started_at_ns
            local msg = ("jovian: %d/%d cells done in %s"):format(
                State.batch.done,
                State.batch.total,
                format_elapsed_ns(batch_elapsed_ns)
            )
            vim.notify(msg, vim.log.levels.INFO)
            -- Cross-threshold batches also get a desktop notification so
            -- the user can :JovianRunAll, switch windows, and be paged
            -- back when it finishes.
            if threshold and threshold > 0 and batch_elapsed_ns / 1e9 >= threshold then
                UI.send_notification(msg, errored and "error" or "info")
            end
            State.batch = nil
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
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local src_path = vim.api.nvim_buf_get_name(buf)
    local OutRender = require("jovian.ui.output_render")
    OutRender.invalidate(src_path)

    if Config.options.inline_outputs and Config.options.cell_frame then
        require("jovian.ui.cell_frame").schedule(buf)
    end

    -- Refresh preview if the focused cell is the one in the preview pane.
    if
        State.current_preview_cell_id == cell_id
        and State.buf.preview
        and vim.api.nvim_buf_is_valid(State.buf.preview)
    then
        OutRender.render_to_buffer(State.buf.preview, State.win.preview, src_path, cell_id)
    end

    -- Refresh the pin pane on every output event for the pinned cell so
    -- the user sees streaming results live (matches the preview behavior).
    if
        State.current_pin
        and State.current_pin.cell_id == cell_id
        and State.buf.pin
        and vim.api.nvim_buf_is_valid(State.buf.pin)
    then
        OutRender.render_to_buffer(State.buf.pin, State.win.pin, src_path, cell_id)
    end
end

local function maybe_finalize_cell(cell_id)
    local s = _cell_done_state[cell_id]
    if not s or not s.got_reply or not s.got_idle then
        return
    end
    set_final(cell_id, s.errored or _cell_had_error[cell_id])
    refresh_inline_outputs(cell_id)
    _cell_done_state[cell_id] = nil
end

local function on_cell_event(params)
    local cell_id = params and params.cell_id
    if not cell_id then
        return
    end
    local ev = params.event or {}
    local kind = ev.kind

    if kind == "execute_input" then
        _cell_had_error[cell_id] = false
        _cell_done_state[cell_id] = { got_reply = false, got_idle = false, errored = false }
        -- Mark this cell as freshly executed in the current session so
        -- the renderers drop the "(cached)" suffix on its outputs.
        State.fresh_cells[cell_id] = true
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
        local img_b64 = data["image/png"] or data["image/gif"] or data["image/jpeg"]
        if type(img_b64) == "table" then
            img_b64 = table.concat(img_b64, "")
        end
        local has_img = type(img_b64) == "string" and img_b64 ~= ""

        -- Suppress matplotlib's "<Figure size NxM with K Axes>" / generic
        -- "<X object at 0x...>" repr when an image is the real payload —
        -- the image itself is the content.
        if
            has_img
            and type(tp) == "string"
            and (tp:match("^<Figure ") or tp:match("^<[%w._]+ object>$") or tp:match("^<[%w._]+ object at 0x[%x]+>$"))
        then
            tp = ""
        end
        if type(tp) == "string" and tp ~= "" then
            UI.append_to_repl(vim.split(tp, "\n"), "Identifier")
        end

        if has_img then
            local Kitty = require("jovian.ui.kitty")
            local rows = Config.options.image_rows or 14
            local cols = Config.options.image_cols or 56

            local function write_image(image_id)
                require("jovian.ui.shared").ensure_output_term()
                if not State.term_chan then
                    return
                end
                local r = bit.band(bit.rshift(image_id, 16), 0xff)
                local g = bit.band(bit.rshift(image_id, 8), 0xff)
                local b = bit.band(image_id, 0xff)
                if r == 0 and g == 0 and b == 0 then
                    b = 1
                end
                local fg = string.format("\27[38;2;%d;%d;%dm", r, g, b)
                local reset = "\27[0m"
                local placement = Kitty.build_virt_lines(image_id, rows, cols)
                local out = ""
                for _, row_chunks in ipairs(placement) do
                    local parts = {}
                    for _, c in ipairs(row_chunks) do
                        table.insert(parts, c[1])
                    end
                    out = out .. fg .. table.concat(parts) .. reset .. "\r\n"
                end
                pcall(vim.api.nvim_chan_send, State.term_chan, out)
            end

            local id = Kitty.ensure_transmitted(img_b64, write_image, cols, rows)
            if id then
                write_image(id)
            end
            -- If id is nil the transmit is in flight; write_image will run
            -- via the callback once kitty_transmit returns.
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
        local s = _cell_done_state[cell_id] or { got_reply = false, got_idle = false, errored = false }
        s.got_reply = true
        s.errored = (ev.status == "error")
        _cell_done_state[cell_id] = s
        maybe_finalize_cell(cell_id)
    elseif kind == "status" then
        -- Only `idle` matters for cell completion. `busy` is implied by
        -- execute_input firing, which already triggered set_busy().
        if ev.state == "idle" then
            local s = _cell_done_state[cell_id]
            if s then
                s.got_idle = true
                maybe_finalize_cell(cell_id)
            end
        end
    end
    -- update_display_data, kernel_info, clear_output: no-op
end

-- Clear all per-run execution bookkeeping (running cells, batch progress,
-- completion gating). When `status`/`msg` are given, any cell still shown
-- as "running" gets that final status so the UI doesn't hang on
-- "Running..." forever. Does NOT drop the kernel session — used by
-- interrupt, where the kernel keeps running.
local function clear_run_state(status, msg)
    if status and msg then
        for cell_id, buf in pairs(State.cell_buf_map) do
            if buf and vim.api.nvim_buf_is_valid(buf) then
                UI.set_cell_status(buf, cell_id, status, msg)
            end
        end
    end
    State.cell_buf_map = {}
    State.running_cells = {}
    State.cell_start_time = {}
    State.batch = nil
    -- Reassign (not wipe-in-place) so the closures that capture these
    -- upvalues see the fresh tables too.
    _cell_had_error = {}
    _cell_done_state = {}
end

-- Full session teardown: clear run state AND drop the kernel session so the
-- next :JovianStart begins fresh. Called from stop, kernel_died, and core
-- process exit. Also clears any queued on_ready callbacks so a stale cell
-- run can't fire against a later, unrelated kernel start.
local function teardown_session(status, msg)
    clear_run_state(status, msg)
    State.rust_active = false
    State.rust_session_id = nil
    State.job_id = nil
    State.is_starting_kernel = false
    State.on_ready_callbacks = {}
    -- Outputs from the dead kernel are now historical; drop the fresh flag
    -- so renderers tag them "(cached)".
    State.fresh_cells = {}
end

-- Handle kernel_event notifications from the core. The interesting kind
-- is kernel_died, which fires when the kernel process exits on its own
-- (segfault, OOM, user kills it from another terminal). We reset state
-- and notify the user so they can :JovianRestart instead of hanging on
-- the next :JovianRun.
local function on_kernel_event(params)
    local ev = params and params.event
    if not ev or ev.kind ~= "kernel_died" then
        return
    end
    vim.schedule(function()
        local code = ev.exit_code
        local code_str = code and tostring(code) or "?"
        vim.notify(
            "jovian: kernel process exited (code=" .. code_str .. "). Run :JovianRestart to start a new one.",
            vim.log.levels.ERROR
        )
        teardown_session("error", Config.options.ui_symbols.error .. " (kernel died)")
    end)
end

local function ensure_event_handler()
    local client = Core.client()
    if not client then
        return
    end
    -- Already bound to this exact client? Nothing to do. After a core
    -- crash + respawn this is a different object, so we fall through and
    -- bind the new one (the old client is gone with the dead process).
    if _handlers_client == client then
        return
    end
    client:on("cell_event", on_cell_event)
    client:on("kernel_event", on_kernel_event)
    -- The core PROCESS exiting (not just the kernel) tears down everything:
    -- mark running cells errored, drop the session, and clear queued
    -- callbacks so the next start is clean. Without this the State keeps
    -- a dead session id and cells hang in "Running..." until nvim restarts.
    client:on_exit(function()
        _handlers_client = nil
        vim.schedule(function()
            teardown_session("error", Config.options.ui_symbols.error .. " (core exited)")
        end)
    end)
    _handlers_client = client
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
    -- Core.ensure() raises when the binary can't be found (the typical
    -- first-run path). Catch it so is_starting_kernel doesn't stay latched
    -- on — otherwise every later :JovianRun/:JovianStart just silently
    -- queues a callback and the plugin appears dead.
    local ok, client = pcall(Core.ensure)
    if not ok or not client then
        vim.schedule(function()
            State.is_starting_kernel = false
            State.on_ready_callbacks = {}
            vim.notify("jovian-core unavailable: " .. tostring(client), vim.log.levels.ERROR)
        end)
        return
    end
    ensure_event_handler()

    client:request("open", { path = session_path() }, function(err, result)
        if err then
            vim.schedule(function()
                State.is_starting_kernel = false
                State.on_ready_callbacks = {}
                vim.notify("jovian-core open failed: " .. err, vim.log.levels.ERROR)
            end)
            return
        end
        local sid = result.session_id
        local args = { session_id = sid }
        if Config.options.ssh_host and Config.options.ssh_host ~= "" then
            -- Remote kernel: jovian-core spawns the kernel over SSH and tunnels
            -- its ZMQ ports back to localhost. ssh_host / ssh_python / remote_cwd
            -- are set by hosts.use_host (:JovianConnect / :JovianUse).
            args.host = Config.options.ssh_host
            args.remote_python = Config.options.ssh_python or "python3"
            args.remote_cwd = Config.options.remote_cwd
        elseif looks_like_path(Config.options.python_interpreter) then
            args.python_path = Config.options.python_interpreter
        elseif Config.options.kernel_name and Config.options.kernel_name ~= "" then
            -- No usable python pinned; defer to a registered Jupyter
            -- kernelspec. The Rust side calls discover_with_fallback(name).
            args.kernel_name = Config.options.kernel_name
        end
        client:request("start_kernel", args, function(err2, _)
            vim.schedule(function()
                State.is_starting_kernel = false
                if err2 then
                    State.on_ready_callbacks = {}
                    vim.notify("jovian-core start_kernel failed: " .. err2, vim.log.levels.ERROR)
                    return
                end
                State.rust_session_id = sid
                State.rust_active = true
                -- Sentinel so legacy `if State.job_id` gates still pass. NEVER
                -- pass this value to vim.fn.jobstop/jobpid — branch on
                -- State.rust_active first.
                State.job_id = "rust"
                if on_ready then
                    pcall(on_ready)
                end
                for _, cb in ipairs(State.on_ready_callbacks) do
                    pcall(cb)
                end
                State.on_ready_callbacks = {}
            end)
        end)
    end)
end

--- Send a cell's code to the kernel. Caller must have set up State.cell_buf_map
--- and friends BEFORE calling — same contract as the legacy send_payload.
function M.execute(code, cell_id)
    local client = Core.client()
    if not client or not State.rust_session_id then
        vim.notify("jovian-core not started", vim.log.levels.WARN)
        return
    end
    -- Sync the current buffer text so the Rust side has up-to-date cell models
    -- (including any newly-inserted cells / freshly-assigned ids).
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    client:notify("reparse", { session_id = State.rust_session_id, text = text })
    -- Pass `code` explicitly so the Rust side runs exactly what the caller
    -- intended even if the buffer doesn't carry a cell with that id
    -- (direct send_payload calls, scratchpad lines, tests).
    client:request("execute", {
        session_id = State.rust_session_id,
        cell_id = cell_id,
        code = code,
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
    if not client or not State.rust_session_id then
        return
    end
    client:notify("interrupt_kernel", { session_id = State.rust_session_id })
    UI.append_to_repl("[Kernel Interrupted!]", "WarningMsg")
    -- Kernel stays alive after an interrupt — only drop the in-flight run
    -- bookkeeping (batch progress, completion gating), not the session.
    clear_run_state("error", Config.options.ui_symbols.interrupted)
end

function M.stop()
    local client = Core.client()
    if client and State.rust_session_id then
        client:notify("close", { session_id = State.rust_session_id })
    end
    teardown_session()
end

function M.restart(on_ready)
    M.stop()
    vim.defer_fn(function()
        M.start(on_ready)
    end, 200)
end

-- ---------- Hidden execute helpers (Vars / View) ----------

-- The `[==[ ... ]==]` long-string level keeps `]]` inside the Python
-- list comprehensions (df.index[a:b]] inside outer [ ... ]) from
-- terminating the Lua string early.
local VARS_SNIPPET = [==[
import json, types
def _jovian_vars(offset, limit):
    try:
        from IPython import get_ipython
        shell = get_ipython()
        ns = shell.user_ns if shell else globals()
        keys = [k for k in ns.keys() if not k.startswith("_")]
        keys.sort()
        filtered = []
        for k in keys:
            val = ns[k]
            if isinstance(val, (types.ModuleType, types.FunctionType, type)):
                continue
            filtered.append(k)
        total = len(filtered)
        page = filtered[offset:offset + limit]
        out = []
        for name in page:
            val = ns[name]
            tn = type(val).__name__
            r = repr(val).replace("\n", " ")
            info = (r[:97] + "...") if len(r) > 100 else r
            out.append({"name": name, "type": tn, "info": info})
        print("__JOVIAN_VARS__" + json.dumps({
            "variables": out, "total_vars": total,
            "offset": offset, "limit": limit,
        }))
    except Exception as e:
        print("__JOVIAN_ERR__" + json.dumps({"error": str(e)}))
_jovian_vars(%d, %d)
]==]

local DF_SNIPPET = [==[
import json
def _jovian_df(name, offset, limit):
    try:
        from IPython import get_ipython
        shell = get_ipython()
        ns = shell.user_ns if shell else globals()
        if name not in ns:
            print("__JOVIAN_ERR__" + json.dumps({"error": "name not found: " + name}))
            return
        df = ns[name]
        if not hasattr(df, "columns"):
            print("__JOVIAN_ERR__" + json.dumps({"error": name + " is not a DataFrame"}))
            return
        total = len(df)
        data = {
            "name": name,
            "columns": [str(c) for c in df.columns],
            "index": [str(i) for i in df.index[offset:offset + limit]],
            "data": df.iloc[offset:offset + limit].values.tolist(),
            "total_rows": total,
            "offset": offset,
            "limit": limit,
        }
        print("__JOVIAN_DF__" + json.dumps(data, default=str))
    except Exception as e:
        print("__JOVIAN_ERR__" + json.dumps({"error": str(e)}))
_jovian_df(%q, %d, %d)
]==]

-- Find a line in the collected stdout that starts with `marker`, return
-- the decoded JSON suffix (or nil if marker not found / decode failed).
local function parse_marker(stdout, marker)
    if type(stdout) ~= "string" then
        return nil
    end
    for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
        local payload = line:match("^" .. marker .. "(.*)$")
        if payload then
            local ok, decoded = pcall(vim.json.decode, payload)
            if ok then
                return decoded
            end
        end
    end
    return nil
end

--- Show the variables pane via execute_collect. opts may contain
--- force_float, offset, limit.
function M.show_variables(opts)
    opts = opts or {}
    local client = Core.client()
    if not client or not State.rust_session_id then
        vim.notify("jovian-core not started", vim.log.levels.WARN)
        return
    end
    local offset = opts.offset or 0
    local limit = opts.limit or 100
    local code = string.format(VARS_SNIPPET, offset, limit)
    client:request("execute_collect", {
        session_id = State.rust_session_id,
        code = code,
        timeout_ms = 5000,
    }, function(err, result)
        if err then
            vim.schedule(function()
                vim.notify("jovian: variables fetch failed: " .. err, vim.log.levels.WARN)
            end)
            return
        end
        local errpayload = parse_marker(result.stdout, "__JOVIAN_ERR__")
        if errpayload then
            vim.schedule(function()
                vim.notify("jovian: " .. (errpayload.error or "?"), vim.log.levels.WARN)
            end)
            return
        end
        local data = parse_marker(result.stdout, "__JOVIAN_VARS__")
        if not data then
            return
        end
        vim.schedule(function()
            UI.show_variables(data, opts.force_float)
        end)
    end)
end

--- Quick-eval a snippet in the running kernel WITHOUT recording it in the
--- In/Out history (store_history=false in execute_collect). It runs in the
--- same kernel so all cell-defined variables are visible, but it never
--- increments Out[N], never touches the sidecar, and never becomes a cell.
--- The input echo + result are appended to the Output log.
function M.eval(code, on_done)
    if not code or vim.trim(code) == "" then
        if on_done then
            on_done()
        end
        return
    end
    local client = Core.client()
    if not client or not State.rust_session_id then
        vim.notify("jovian-core not started", vim.log.levels.WARN)
        if on_done then
            on_done()
        end
        return
    end

    require("jovian.ui.shared").ensure_output_term()
    UI.append_to_repl({ "eval> " .. code }, "Type")

    client:request("execute_collect", {
        session_id = State.rust_session_id,
        code = code,
        timeout_ms = 30000,
    }, function(err, result)
        vim.schedule(function()
            if err then
                UI.append_to_repl("[eval failed] " .. err, "ErrorMsg")
                if on_done then
                    on_done()
                end
                return
            end
            -- msgpack null decodes to vim.NIL (which is truthy), so
            -- normalize the optional fields before testing them.
            local function present(v)
                if v == nil or v == vim.NIL then
                    return nil
                end
                return v
            end
            local stdout = present(result.stdout)
            local stderr = present(result.stderr)
            local rerror = present(result.error)
            local data = present(result.result)

            if type(stdout) == "string" and stdout ~= "" then
                UI.append_stream_text(stdout, "stdout")
            end
            if type(stderr) == "string" and stderr ~= "" then
                UI.append_stream_text(stderr, "stderr")
            end
            if type(rerror) == "table" then
                UI.append_to_repl((rerror.ename or "Error") .. ": " .. (rerror.evalue or ""), "ErrorMsg")
                for _, tb in ipairs(rerror.traceback or {}) do
                    for _, line in ipairs(vim.split(strip_ansi(tb), "\n")) do
                        UI.append_to_repl(line, "ErrorMsg")
                    end
                end
            end
            if type(data) == "table" then
                local tp = data["text/plain"]
                if type(tp) == "table" then
                    tp = table.concat(tp, "")
                end
                if type(tp) == "string" and tp ~= "" then
                    UI.append_to_repl(vim.split(strip_ansi(tp), "\n"), "Identifier")
                end
            end
            if on_done then
                on_done()
            end
        end)
    end)
end

--- Page a DataFrame via execute_collect. opts: { name, offset, limit }.
function M.view_dataframe(opts)
    opts = opts or {}
    local client = Core.client()
    if not client or not State.rust_session_id then
        vim.notify("jovian-core not started", vim.log.levels.WARN)
        return
    end
    local name = opts.name
    if not name or name == "" then
        name = vim.fn.expand("<cword>")
    end
    if not name or name == "" then
        vim.notify("jovian: no variable name", vim.log.levels.WARN)
        return
    end
    local offset = opts.offset or 0
    local limit = opts.limit or Config.options.dataframe_page_size or 50
    local code = string.format(DF_SNIPPET, name, offset, limit)
    client:request("execute_collect", {
        session_id = State.rust_session_id,
        code = code,
        timeout_ms = 10000,
    }, function(err, result)
        if err then
            vim.schedule(function()
                vim.notify("jovian: dataframe fetch failed: " .. err, vim.log.levels.WARN)
            end)
            return
        end
        local errpayload = parse_marker(result.stdout, "__JOVIAN_ERR__")
        if errpayload then
            vim.schedule(function()
                vim.notify("jovian: " .. (errpayload.error or "?"), vim.log.levels.WARN)
            end)
            return
        end
        local data = parse_marker(result.stdout, "__JOVIAN_DF__")
        if not data then
            return
        end
        -- Record session for paging callbacks.
        State.dataframe_sessions[data.name] = {
            total = data.total_rows,
            offset = data.offset,
            limit = data.limit,
            columns = data.columns,
        }
        vim.schedule(function()
            UI.show_dataframe(data)
        end)
    end)
end

return M
