-- msgpack-rpc client for jovian-core.
--
-- Spawns the Rust backend via vim.uv (NOT jobstart — the latter strips \n
-- bytes from binary stdio, which corrupts framed msgpack payloads).
--
-- Wire framing matches jovian-core/src/rpc.rs:
--   <u32 BE length><msgpack payload>
--
-- Public API:
--   local rpc = require("jovian.backend.rpc")
--   local client = rpc.spawn({ cmd = "/path/to/jovian-core" })
--   client:request("ping", {}, function(err, result) ... end)
--   client:notify("kitty_attach", { tty = "/dev/tty" })
--   client:on("cell_event", function(params) ... end)
--   client:stop()

local M = {}

local Client = {}
Client.__index = Client

local function pack_u32_be(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function unpack_u32_be(s)
    local a, b, c, d = s:byte(1, 4)
    return a * 16777216 + b * 65536 + c * 256 + d
end

function M.spawn(opts)
    opts = opts or {}
    local cmd = opts.cmd or error("rpc.spawn: cmd required")
    local args = opts.args or {}
    local env = opts.env

    local uv = vim.uv or vim.loop
    local stdin = uv.new_pipe(false)
    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)

    local self = setmetatable({
        cmd = cmd,
        stdin = stdin,
        stdout = stdout,
        stderr = stderr,
        out_acc = "",
        next_id = 0,
        pending = {}, -- msgid → callback
        notification_handlers = {}, -- method → list of handlers
        running = false,
        on_exit_cbs = {},
    }, Client)

    local spawn_args = { args = args, stdio = { stdin, stdout, stderr } }
    if env then
        spawn_args.env = env
    end

    local handle, pid_or_err = uv.spawn(cmd, spawn_args, function(code, signal)
        self.running = false
        -- Flush every in-flight request with an error so callers (and
        -- request_sync's vim.wait) return immediately instead of blocking
        -- until timeout when the core dies mid-request.
        local pending = self.pending
        self.pending = {}
        for _, cb in pairs(pending) do
            vim.schedule(function()
                pcall(cb, "jovian-core exited", nil)
            end)
        end
        -- Release the pipe handles — otherwise the fds leak and a later
        -- write to the dead stdin raises.
        for _, pipe in ipairs({ self.stdin, self.stdout, self.stderr }) do
            if pipe and not pipe:is_closing() then
                pcall(uv.close, pipe)
            end
        end
        for _, cb in ipairs(self.on_exit_cbs) do
            pcall(cb, code, signal)
        end
    end)

    if not handle then
        stdin:close()
        stdout:close()
        stderr:close()
        error("rpc.spawn: failed to spawn " .. cmd .. ": " .. tostring(pid_or_err))
    end

    self.handle = handle
    self.pid = pid_or_err
    self.running = true

    uv.read_start(stdout, function(err, chunk)
        if err then
            vim.schedule(function()
                vim.notify("jovian rpc stdout err: " .. err, vim.log.levels.ERROR)
            end)
            return
        end
        if not chunk then
            return
        end
        self.out_acc = self.out_acc .. chunk
        self:_drain()
    end)

    uv.read_start(stderr, function(_, chunk)
        if chunk and chunk ~= "" then
            -- core writes tracing logs to a file; anything on stderr is unusual
            vim.schedule(function()
                vim.notify("jovian-core: " .. chunk, vim.log.levels.WARN)
            end)
        end
    end)

    return self
end

function Client:_drain()
    while #self.out_acc >= 4 do
        local n = unpack_u32_be(self.out_acc:sub(1, 4))
        if #self.out_acc < 4 + n then
            return
        end
        local payload = self.out_acc:sub(5, 4 + n)
        self.out_acc = self.out_acc:sub(5 + n)
        local ok, val = pcall(vim.mpack.decode, payload)
        if ok and type(val) == "table" then
            local kind = val[1]
            if kind == 1 then
                -- Response: [1, msgid, err, result]
                local cb = self.pending[val[2]]
                self.pending[val[2]] = nil
                if cb then
                    vim.schedule(function()
                        local err = val[3]
                        if err == vim.NIL then
                            err = nil
                        end
                        local res = val[4]
                        if res == vim.NIL then
                            res = nil
                        end
                        pcall(cb, err, res)
                    end)
                end
            elseif kind == 2 then
                -- Notification: [2, method, params]
                local method = val[2]
                local params = val[3]
                if type(params) == "table" and #params == 1 then
                    params = params[1]
                end
                local handlers = self.notification_handlers[method]
                if handlers then
                    vim.schedule(function()
                        for _, h in ipairs(handlers) do
                            pcall(h, params)
                        end
                    end)
                end
            end
        else
            vim.schedule(function()
                vim.notify("jovian rpc decode failed: " .. tostring(val), vim.log.levels.WARN)
            end)
        end
    end
end

function Client:_send(payload)
    if not self.running then
        return false, "core not running"
    end
    local framed = pack_u32_be(#payload) .. payload
    local uv = vim.uv or vim.loop
    uv.write(self.stdin, framed)
    return true
end

--- Send a request and call `cb(err, result)` when the reply arrives.
function Client:request(method, params, cb)
    self.next_id = self.next_id + 1
    local id = self.next_id
    self.pending[id] = cb or function() end
    local payload = vim.mpack.encode({ 0, id, method, { params or vim.empty_dict() } })
    local ok, err = self:_send(payload)
    if not ok then
        self.pending[id] = nil
        if cb then
            vim.schedule(function()
                cb(err, nil)
            end)
        end
    end
    return id
end

--- Synchronous request — blocks via vim.wait until reply or timeout.
function Client:request_sync(method, params, timeout_ms)
    local done, result, err
    self:request(method, params, function(e, r)
        err, result, done = e, r, true
    end)
    local ok = vim.wait(timeout_ms or 5000, function()
        return done
    end, 10)
    if not ok then
        return nil, "rpc timeout: " .. method
    end
    return result, err
end

function Client:notify(method, params)
    local payload = vim.mpack.encode({ 2, method, { params or vim.empty_dict() } })
    self:_send(payload)
end

--- Register a handler for a notification method.
function Client:on(method, handler)
    self.notification_handlers[method] = self.notification_handlers[method] or {}
    table.insert(self.notification_handlers[method], handler)
end

function Client:on_exit(cb)
    table.insert(self.on_exit_cbs, cb)
end

function Client:stop()
    if not self.running then
        return
    end
    -- Drop running first so any in-flight :_send during the shutdown window
    -- short-circuits instead of writing to a stdin we're about to close.
    self.running = false
    local uv = vim.uv or vim.loop
    -- Closing stdin signals EOF to core's reader loop; it then exits cleanly.
    -- Fall back to SIGTERM if it ignores us.
    if self.stdin and not self.stdin:is_closing() then
        pcall(uv.close, self.stdin)
    end
    local handle = self.handle
    vim.defer_fn(function()
        if handle and not handle:is_closing() then
            pcall(uv.process_kill, handle, "sigterm")
        end
    end, 500)
end

return M
