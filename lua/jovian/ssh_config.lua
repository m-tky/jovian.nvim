local M = {}

function M.parse(filepath)
    filepath = filepath or vim.fn.expand("~/.ssh/config")
    if vim.fn.filereadable(filepath) == 0 then
        return {}
    end

    local hosts = {}
    local current_host = nil

    local lines = vim.fn.readfile(filepath)
    for _, line in ipairs(lines) do
        line = vim.trim(line)
        -- Skip comments and empty lines
        if line ~= "" and not line:match("^#") then
            local parts = vim.split(line, "%s+")
            local key = parts[1]:lower()

            if key == "host" then
                local name = parts[2]
                -- Skip wildcards for now
                if name and not name:match("[%*%?]") then
                    current_host = { name = name }
                    table.insert(hosts, current_host)
                else
                    current_host = nil
                end
            elseif current_host then
                if key == "hostname" then
                    current_host.hostname = parts[2]
                elseif key == "user" then
                    current_host.user = parts[2]
                elseif key == "port" then
                    current_host.port = tonumber(parts[2])
                elseif key == "identityfile" then
                    current_host.identity_file = parts[2]
                elseif key == "proxyjump" then
                    current_host.proxy_jump = parts[2]
                end
            elseif key == "include" then
                -- Handle Include (recursive)
                local pattern = parts[2]
                if pattern:sub(1, 1) ~= "/" then
                    pattern = vim.fn.expand("~/.ssh/") .. pattern
                end
                local files = vim.fn.glob(pattern, false, true)
                for _, f in ipairs(files) do
                    local sub_hosts = M.parse(f)
                    for _, sh in ipairs(sub_hosts) do
                        table.insert(hosts, sh)
                    end
                end
            end
        end
    end
    return hosts
end

function M.get_tailscale_hosts()
    if vim.fn.executable("tailscale") == 0 then
        return {}
    end

    local handle = io.popen("tailscale status --json")
    if not handle then return {} end
    local result = handle:read("*a")
    handle:close()

    local ok, decoded = pcall(vim.json.decode, result)
    if not ok or not decoded.Peer then
        return {}
    end

    local hosts = {}
    for _, peer in pairs(decoded.Peer) do
        -- Only show online Linux nodes (common for Jupyter)
        if peer.Online and peer.OS == "linux" then
            local name = peer.DNSName:gsub("%.$", "") -- Remove trailing dot
            table.insert(hosts, {
                name = name,
                hostname = name,
                user = peer.User or "",
                is_tailscale = true
            })
        end
    end
    return hosts
end

function M.get_all_hosts()
    local config_hosts = M.parse()
    local tailscale_hosts = M.get_tailscale_hosts()

    -- Merge, prioritizing config_hosts
    local names = {}
    for _, h in ipairs(config_hosts) do
        names[h.name] = true
    end

    local all = vim.deepcopy(config_hosts)
    for _, h in ipairs(tailscale_hosts) do
        if not names[h.name] then
            table.insert(all, h)
        end
    end
    return all
end

return M
