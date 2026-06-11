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
            current = "local_default",
        }
    else
        local content = table.concat(vim.fn.readfile(M.hosts_file), "\n")
        local ok, decoded = pcall(vim.json.decode, content)
        data = (ok and type(decoded) == "table") and decoded or {}
    end

    -- Normalize the shape: a hosts.json missing `configs` (hand-edited or
    -- from an older version) would otherwise nil-index below and take down
    -- every host command.
    if type(data.configs) ~= "table" then
        data.configs = {}
    end
    if not data.current then
        data.current = "local_default"
    end

    -- Ensure local_default exists and is synced with configured python
    local default_python = Config.configured_python or Config.options.python_interpreter
    data.configs["local_default"] = { type = "local", python = default_python }

    return data
end

function M.save_hosts(data)
    M.ensure_hosts_dir()
    local content = vim.json.encode(data)
    vim.fn.writefile({ content }, M.hosts_file)
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
        Config.options.remote_cwd = config.remote_cwd or "."
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

-- Apply the persisted "current" host to Config.options at startup. Same
-- option mapping as use_host, but without saving / notifying / restarting —
-- meant to be called from setup() AFTER Config.setup() has rebuilt the
-- options table, so the restored values aren't immediately clobbered.
function M.restore_active()
    local ok, data = pcall(M.load_hosts)
    if not ok or not data.current then
        return
    end
    local config = data.configs[data.current]
    if not config then
        return
    end
    if config.type == "ssh" then
        Config.options.ssh_host = config.host
        Config.options.ssh_python = config.python
        Config.options.remote_cwd = config.remote_cwd or "."
        Config.options.python_interpreter = config.python
    else
        Config.options.ssh_host = nil
        Config.options.ssh_python = nil
        Config.options.python_interpreter = config.python
    end
end

return M
