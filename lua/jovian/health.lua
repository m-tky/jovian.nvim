local M = {}
local Config = require("jovian.config")

function M.check()
    vim.health.start("Jovian.nvim Report")

    -- Python Check
    local python_exe = Config.options.python_interpreter
    if vim.fn.executable(python_exe) == 1 then
        vim.health.ok("Python executable found: " .. python_exe)

        -- jovian-core spawns `python -m ipykernel_launcher`; ipykernel is
        -- the only hard dependency (it pulls jupyter_client transitively).
        local check_cmd = { python_exe, "-c", "import ipykernel; print('ok')" }
        local out = vim.fn.system(check_cmd)
        if out:match("ok") then
            vim.health.ok("Python dependency (ipykernel) found")
        else
            vim.health.error("Missing Python dependency: ipykernel (pip install ipykernel)")
        end
    else
        vim.health.error("Python executable not found: " .. python_exe)
    end

    -- Kitty graphics support (jovian-core writes Kitty escapes directly to
    -- /dev/tty; works on Kitty / Ghostty 1.3+ / WezTerm).
    local term = vim.env.TERM_PROGRAM or vim.env.TERM or ""
    if term:match("kitty") or term:match("ghostty") or term:match("wezterm")
        or vim.env.KITTY_WINDOW_ID
    then
        vim.health.ok("Kitty graphics terminal detected (" .. term .. ")")
    else
        vim.health.warn(
            "Kitty graphics support unclear (TERM=" .. term .. ")"
            .. " — inline images may render as placeholder glyphs only"
        )
    end

    -- SSH Check
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
