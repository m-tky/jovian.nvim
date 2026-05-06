local M = {}
local Config = require("jovian.config")

function M.check()
    vim.health.start("Jovian.nvim Report")

    -- Python Check
    local python_exe = Config.options.python_interpreter
    if vim.fn.executable(python_exe) == 1 then
        vim.health.ok("Python executable found: " .. python_exe)

        -- Check dependencies
        local check_cmd = { python_exe, "-c", "import ipykernel, jupyter_client; print('ok')" }
        local out = vim.fn.system(check_cmd)
        if out:match("ok") then
            vim.health.ok("Python dependencies (ipykernel, jupyter_client) found")
        else
            vim.health.error("Missing Python dependencies: ipykernel, jupyter_client")
        end
    else
        vim.health.error("Python executable not found: " .. python_exe)
    end

    -- Image.nvim Check
    local has_image, _ = pcall(require, "image")
    if has_image then
        vim.health.ok("image.nvim is installed")
    else
        vim.health.warn("image.nvim not found (Plotting will not work)")
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
