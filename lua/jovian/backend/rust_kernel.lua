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
        if type(img_b64) == "table" then img_b64 = table.concat(img_b64, "") end
        local has_img = type(img_b64) == "string" and img_b64 ~= ""

        -- Suppress matplotlib's "<Figure size NxM with K Axes>" / generic
        -- "<X object at 0x...>" repr when an image is the real payload —
        -- the image itself is the content.
        if has_img and type(tp) == "string"
            and (tp:match("^<Figure ")
                or tp:match("^<[%w._]+ object>$")
                or tp:match("^<[%w._]+ object at 0x[%x]+>$"))
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
                if not State.term_chan then return end
                local r = bit.band(bit.rshift(image_id, 16), 0xff)
                local g = bit.band(bit.rshift(image_id, 8), 0xff)
                local b = bit.band(image_id, 0xff)
                if r == 0 and g == 0 and b == 0 then b = 1 end
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
    -- Outputs from the killed kernel are now historical — flag them
    -- as cached so the user can tell they're not from the new session.
    State.fresh_cells = {}
end

function M.restart(on_ready)
    M.stop()
    vim.defer_fn(function() M.start(on_ready) end, 200)
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
    if type(stdout) ~= "string" then return nil end
    for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
        local payload = line:match("^" .. marker .. "(.*)$")
        if payload then
            local ok, decoded = pcall(vim.json.decode, payload)
            if ok then return decoded end
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
        if not data then return end
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
function M.eval(code)
    if not code or vim.trim(code) == "" then return end
    local client = Core.client()
    if not client or not State.rust_session_id then
        vim.notify("jovian-core not started", vim.log.levels.WARN)
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
                return
            end
            -- msgpack null decodes to vim.NIL (which is truthy), so
            -- normalize the optional fields before testing them.
            local function present(v)
                if v == nil or v == vim.NIL then return nil end
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
                UI.append_to_repl(
                    (rerror.ename or "Error") .. ": " .. (rerror.evalue or ""),
                    "ErrorMsg"
                )
                for _, tb in ipairs(rerror.traceback or {}) do
                    for _, line in ipairs(vim.split(strip_ansi(tb), "\n")) do
                        UI.append_to_repl(line, "ErrorMsg")
                    end
                end
            end
            if type(data) == "table" then
                local tp = data["text/plain"]
                if type(tp) == "table" then tp = table.concat(tp, "") end
                if type(tp) == "string" and tp ~= "" then
                    UI.append_to_repl(vim.split(strip_ansi(tp), "\n"), "Identifier")
                end
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
        if not data then return end
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
