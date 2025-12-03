local M = {}
local Config = require("jovian.config")

M.hosts_file = vim.fn.stdpath("data") .. "/jovian/hosts.json"

function M.ensure_hosts_dir()
    local dir = vim.fn.fnamemodify(M.hosts_file, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end
end

function M.load_hosts()
    local data
    if vim.fn.filereadable(M.hosts_file) == 0 then
        data = {
            configs = {},
            current = "local_default"
        }
    else
        local content = table.concat(vim.fn.readfile(M.hosts_file), "\n")
        local ok, decoded = pcall(vim.fn.json_decode, content)
        data = ok and decoded or { configs = {}, current = "local_default" }
    end

    -- Ensure local_default exists and is synced with configured python
    local default_python = Config.configured_python or Config.options.python_interpreter
    data.configs["local_default"] = { type = "local", python = default_python }

    return data
end

function M.save_hosts(data)
    M.ensure_hosts_dir()
    local content = vim.fn.json_encode(data)
    vim.fn.writefile({content}, M.hosts_file)
end

function M.exists(name)
    local data = M.load_hosts()
    return data.configs[name] ~= nil
end

function M.add_host(name, config)
    local data = M.load_hosts()
    data.configs[name] = config
    M.save_hosts(data)
    vim.notify("Host '" .. name .. "' added.", vim.log.levels.INFO)
end

function M.remove_host(name)
    local data = M.load_hosts()
    if not data.configs[name] then
        return vim.notify("Host '" .. name .. "' not found.", vim.log.levels.ERROR)
    end
    if name == "local_default" then
        return vim.notify("Cannot remove default local host.", vim.log.levels.WARN)
    end
    
    data.configs[name] = nil
    M.save_hosts(data)
    
    if data.current == name then
        vim.notify("Removed active host. Switched back to local_default.", vim.log.levels.WARN)
        M.use_host("local_default")
    else
        vim.notify("Host '" .. name .. "' removed.", vim.log.levels.INFO)
    end
end

function M.use_host(name)
    local data = M.load_hosts()
    local config = data.configs[name]
    if not config then
        return vim.notify("Host '" .. name .. "' not found.", vim.log.levels.ERROR)
    end
    
    -- Update Runtime Config
    if config.type == "ssh" then
        Config.options.ssh_host = config.host
        Config.options.ssh_python = config.python
        Config.options.python_interpreter = config.python -- Sync for reference
    else
        Config.options.ssh_host = nil
        Config.options.ssh_python = nil
        Config.options.python_interpreter = config.python
    end
    
    data.current = name
    M.save_hosts(data)
    vim.notify("Switched to host: " .. name, vim.log.levels.INFO)
    
    -- Restart kernel if running
    -- Require core dynamically to avoid circular dependency
    local Core = require("jovian.core")
    local State = require("jovian.state")
    if State.job_id then
        Core.restart_kernel()
    end
end

function M.validate_connection(config)
    -- Default to current config if not provided
    local host = config and config.host or Config.options.ssh_host
    local python = config and config.python or Config.options.python_interpreter
    if config and config.type == "ssh" then
        python = config.python
    elseif config and config.type == "local" then
        host = nil
        python = config.python
    end

    if host then
        -- Check SSH connectivity
        vim.notify("[Jovian] Validating connection to " .. host .. "...", vim.log.levels.INFO)
        
        local ssh_check = vim.fn.system({"ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "exit"})
        if vim.v.shell_error ~= 0 then
            return false, "Could not connect to " .. host .. ". Check SSH config/keys."
        end
        
        local py_check = vim.fn.system({"ssh", host, python, "--version"})
        if vim.v.shell_error ~= 0 then
            return false, "Python interpreter '" .. python .. "' not found or not executable on " .. host .. "."
        end
    else
        -- Check local python
        local py_check = vim.fn.system({python, "--version"})
        if vim.v.shell_error ~= 0 then
            return false, "Local Python interpreter '" .. python .. "' not found."
        end
    end
    return true, nil
end

return M
