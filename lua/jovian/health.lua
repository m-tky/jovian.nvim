local M = {}
local Config = require("jovian.config")
local Python = require("jovian.python")

function M.check()
    vim.health.start("Jovian.nvim Report")

    -- Active python (from setup() — either explicit or auto-resolved)
    local active = Config.options.python_interpreter
    if active and active ~= "" then
        if vim.fn.executable(active) == 1 then
            local origin = Config.python_interpreter_explicit and "explicit (setup)" or "auto-resolved"
            vim.health.ok(("Active python: %s  [%s]"):format(active, origin))
            if Python.has_ipykernel(active) then
                vim.health.ok("ipykernel importable")
            else
                vim.health.error(
                    "Active python cannot import ipykernel — install it (e.g. `pip install ipykernel`) "
                        .. "or run :JovianPickPython to pick another."
                )
            end
        else
            vim.health.error("Active python is not executable: " .. active)
        end
    else
        vim.health.warn("No python configured; auto-resolver found nothing usable.")
    end

    -- Pinned kernelspec (optional)
    if Config.options.kernel_name and Config.options.kernel_name ~= "" then
        vim.health.info("Pinned kernelspec: " .. Config.options.kernel_name)
    end

    -- All probed candidates — useful for debugging "why didn't it pick the
    -- one I expected?" cases.
    vim.health.start("Python candidates")
    local candidates = Python.candidates()
    if #candidates == 0 then
        vim.health.warn("No candidate pythons found on this system.")
    else
        for _, c in ipairs(candidates) do
            local usable = Python.has_ipykernel(c.path)
            local marker = (c.path == active) and " (active)" or ""
            local line = ("%s  %s%s"):format(c.source, c.path, marker)
            if usable then
                vim.health.ok(line .. "  [ipykernel]")
            else
                vim.health.info(line .. "  [no ipykernel]")
            end
        end
    end

    -- Kitty graphics support (jovian-core writes Kitty escapes directly to
    -- /dev/tty; works on Kitty / Ghostty 1.3+ / WezTerm).
    vim.health.start("Terminal")
    local term = vim.env.TERM_PROGRAM or vim.env.TERM or ""
    if term:match("kitty") or term:match("ghostty") or term:match("wezterm") or vim.env.KITTY_WINDOW_ID then
        vim.health.ok("Kitty graphics terminal detected (" .. term .. ")")
    else
        vim.health.warn(
            "Kitty graphics support unclear (TERM="
                .. term
                .. ")"
                .. " — inline images may render as placeholder glyphs only"
        )
    end

    -- SSH Check
    vim.health.start("Remote")
    if Config.options.ssh_host then
        vim.health.info("SSH Host configured: " .. Config.options.ssh_host)
        local ssh_check = vim.fn.system({ "ssh", "-o", "ConnectTimeout=5", Config.options.ssh_host, "echo ok" })
        if ssh_check:match("ok") then
            vim.health.ok("SSH connection successful")
        else
            vim.health.error("SSH connection failed: " .. ssh_check)
        end
    else
        vim.health.info("Running in Local Mode")
    end
end

return M
