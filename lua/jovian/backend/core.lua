-- Locate and spawn jovian-core (the Rust backend).
--
-- Search order for the binary:
--   1. $JOVIAN_CORE_BIN env var (explicit override)
--   2. <plugin_dir>/core/target/release/jovian-core  (cargo build / nix postPatch)
--   3. `jovian-core` on $PATH (e.g. cargo install)
--
-- One core process is shared across every open buffer. Repeat calls to
-- `ensure()` return the same client.

local M = {}

local RPC = require("jovian.backend.rpc")

local _client = nil

local function plugin_dir()
    -- This file: <plugin_dir>/lua/jovian/backend/core.lua
    -- → strip three levels for plugin root
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    return vim.fn.fnamemodify(src, ":h:h:h:h")
end

function M.locate_binary()
    local env_bin = vim.env.JOVIAN_CORE_BIN
    if env_bin and env_bin ~= "" and vim.fn.executable(env_bin) == 1 then
        return env_bin
    end

    local bundled = plugin_dir() .. "/core/target/release/jovian-core"
    if vim.fn.executable(bundled) == 1 then
        return bundled
    end

    if vim.fn.executable("jovian-core") == 1 then
        return "jovian-core"
    end

    return nil
end

--- Get the shared client, spawning the core process on first call.
function M.ensure(opts)
    if _client and _client.running then
        return _client
    end

    local bin = M.locate_binary()
    if not bin then
        error(
            "jovian-core binary not found.\n"
                .. "Options:\n"
                .. "  - Run the lazy.nvim build hook (downloads prebuilt or builds via cargo)\n"
                .. "  - Set $JOVIAN_CORE_BIN to an existing binary\n"
                .. "  - Build manually: cd core && cargo build --release\n"
                .. "  - Use the flake's `jovian-nvim` package (bundles the binary)"
        )
    end

    local env = nil
    if opts and opts.log_level then
        env = { "JOVIAN_LOG=" .. opts.log_level }
        for k, v in pairs(vim.fn.environ()) do
            table.insert(env, k .. "=" .. v)
        end
    end

    _client = RPC.spawn({ cmd = bin, env = env })
    _client:on_exit(function(code, signal)
        _client = nil
        if code and code ~= 0 then
            vim.schedule(function()
                vim.notify(("jovian-core exited (code=%s signal=%s)"):format(code, signal), vim.log.levels.WARN)
            end)
        end
    end)

    -- Hand the controlling tty to core so it can write Kitty graphics escapes
    -- directly (bypassing Neovim's TUI mux). Use a request (not notify) so a
    -- failure surfaces visibly. Anyone needing the attach state (notably
    -- kitty_transmit callers) waits via M.on_kitty_ready — the Rust core
    -- dispatches RPC requests concurrently via tokio::spawn, so without this
    -- gate kitty_transmit can land before kitty_attach has opened the tty.
    M._kitty_attached = false
    M._kitty_attach_error = nil
    M._kitty_ready_cbs = {}
    local function flush_ready(ok, err)
        local cbs = M._kitty_ready_cbs
        M._kitty_ready_cbs = {}
        for _, cb in ipairs(cbs) do
            pcall(cb, ok, err)
        end
    end

    -- Resolve the actual pts device (e.g. /dev/pts/3) BEFORE forking.
    -- The jovian-core child process is spawned via vim.uv.spawn, which on
    -- many systems doesn't propagate a controlling tty — opening "/dev/tty"
    -- inside the child then fails with ENXIO. Passing an absolute pts path
    -- lets the child open it directly without needing a controlling tty.
    --
    -- We can't run `tty` via vim.fn.system because that subprocess itself
    -- has no controlling tty (system closes stdin); it would always say
    -- "not a tty". Instead, follow the /proc symlink of Neovim's own stdin
    -- / stdout / stderr — at least one of them is the real tty.
    local function resolve_tty()
        if vim.env.JOVIAN_TTY and vim.env.JOVIAN_TTY ~= "" then
            return vim.env.JOVIAN_TTY
        end
        local uv = vim.uv or vim.loop
        for _, fd in ipairs({ 0, 1, 2 }) do
            local link = "/proc/self/fd/" .. fd
            local target = uv.fs_readlink(link)
            if target and target:match("^/dev/") and not target:match("^/dev/null") then
                return target
            end
        end
        -- macOS / BSD have no /proc; the env-var override is the escape
        -- hatch there (set by the demo wrappers). Fallback to /dev/tty
        -- which will fail with a clear diagnostic.
        return "/dev/tty"
    end
    local tty = resolve_tty()
    _client:request("kitty_attach", { tty = tty }, function(err, _)
        if err then
            M._kitty_attach_error = err
            vim.schedule(function()
                vim.notify(
                    "jovian: kitty_attach failed ("
                        .. err
                        .. "). "
                        .. "Inline images will not render. "
                        .. "Run `:checkhealth jovian` to diagnose.",
                    vim.log.levels.WARN
                )
                flush_ready(false, err)
            end)
        else
            M._kitty_attached = true
            vim.schedule(function()
                flush_ready(true, nil)
            end)
        end
    end)

    return _client
end

--- Invoke `cb(ok, err?)` once kitty_attach has settled. Fires immediately
--- if it already has; queues the cb otherwise.
function M.on_kitty_ready(cb)
    if M._kitty_attached then
        vim.schedule(function()
            cb(true, nil)
        end)
    elseif M._kitty_attach_error then
        vim.schedule(function()
            cb(false, M._kitty_attach_error)
        end)
    else
        M._kitty_ready_cbs = M._kitty_ready_cbs or {}
        table.insert(M._kitty_ready_cbs, cb)
    end
end

function M.client()
    return _client
end

function M.stop()
    if _client then
        _client:stop()
        _client = nil
    end
end

return M
