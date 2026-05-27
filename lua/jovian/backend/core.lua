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
    if src:sub(1, 1) == "@" then src = src:sub(2) end
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
    if _client and _client.running then return _client end

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
                vim.notify(
                    ("jovian-core exited (code=%s signal=%s)"):format(code, signal),
                    vim.log.levels.WARN
                )
            end)
        end
    end)

    -- Hand the controlling tty to core so it can write Kitty graphics escapes
    -- directly (bypassing Neovim's TUI mux). Use a request (not notify) so a
    -- failure to open /dev/tty surfaces visibly — otherwise every subsequent
    -- kitty_transmit just errors silently and users see blank image areas.
    M._kitty_attached = false
    M._kitty_attach_error = nil
    local tty = vim.env.JOVIAN_TTY or "/dev/tty"
    _client:request("kitty_attach", { tty = tty }, function(err, _)
        if err then
            M._kitty_attach_error = err
            vim.schedule(function()
                vim.notify(
                    "jovian: kitty_attach failed (" .. err .. "). "
                    .. "Inline images will not render. "
                    .. "Run `:checkhealth jovian` to diagnose.",
                    vim.log.levels.WARN
                )
            end)
        else
            M._kitty_attached = true
        end
    end)

    return _client
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
