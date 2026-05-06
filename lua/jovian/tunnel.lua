local M = {}
local State = require("jovian.state")
local Config = require("jovian.config")

local function get_handle_data()
    return function(_, data)
        if not data then
            return
        end
        local output = table.concat(data, "\n")
        local url = output:match("(https://login.tailscale.com/[^%s]+)")
        if url then
            vim.notify("[Jovian] Tailscale Auth Required:\n" .. url, vim.log.levels.WARN, { timeout = 30000 })
            if vim.ui.open then
                vim.ui.open(url)
            end
        end
    end
end

function M.start(host, python, remote_cwd, on_success, on_error)
    python = python or "python3"
    remote_cwd = (remote_cwd and remote_cwd ~= "") and remote_cwd or "."
    local msg = string.format("[Jovian] Starting remote kernel on %s in %s...", host, remote_cwd)
    vim.notify(msg, vim.log.levels.INFO)

    -- Step 1: Start remote kernel and get PID
    local kernel_cmd = string.format(
        'ssh %s "cd %s && nohup %s -m ipykernel_launcher '
            .. '--ip=127.0.0.1 -f /tmp/jovian_kernel.json > /dev/null 2>&1 & echo $!"',
        host,
        remote_cwd,
        python
    )

    local handle_data = get_handle_data()

    vim.fn.jobstart(kernel_cmd, {
        stdout_buffered = true,
        on_stdout = function(j, data)
            handle_data(j, data)
            if data and data[1] and data[1] ~= "" then
                local pid = vim.trim(data[1])
                -- PID is usually just a number, avoid catching URL as PID
                if pid:match("^%d+$") then
                    State.remote_kernel_pid = pid
                    State.tunnel_host = host
                    M._setup_tunnel(host, on_success, on_error)
                end
            end
        end,
        on_stderr = function(j, data)
            handle_data(j, data)
            if data and #data > 0 and data[1] ~= "" then
                -- Only error if it's not the Tailscale URL message
                local output = table.concat(data, "\n")
                if not output:find("https://login.tailscale.com") then
                    if on_error then
                        on_error("Remote kernel start error: " .. output)
                    end
                end
            end
        end,
    })
end

function M._setup_tunnel(host, on_success, on_error)
    local retries = 0
    local max_retries = 10
    local handle_data = get_handle_data()

    local function try_cat()
        vim.fn.jobstart("ssh " .. host .. " cat /tmp/jovian_kernel.json", {
            stdout_buffered = true,
            on_stdout = function(j, data)
                handle_data(j, data)
                if data and data[1] and data[1] ~= "" then
                    local ok, content = pcall(vim.json.decode, table.concat(data, "\n"))
                    if ok then
                        M._establish_ssh_tunnel(host, content, on_success)
                    else
                        -- This might be an auth prompt, wait for it
                        if not table.concat(data, "\n"):find("https://login.tailscale.com") then
                            if on_error then
                                on_error("Failed to parse remote connection file")
                            end
                        end
                    end
                elseif retries < max_retries then
                    retries = retries + 1
                    vim.defer_fn(try_cat, 1000)
                else
                    if on_error then
                        on_error("Connection file not found after retries")
                    end
                end
            end,
            on_stderr = handle_data,
            on_exit = function(_, code)
                if code ~= 0 and retries >= max_retries then
                    if on_error then
                        on_error("Failed to cat connection file")
                    end
                end
            end,
        })
    end

    try_cat()
end

function M._establish_ssh_tunnel(host, config, on_success)
    -- Ports to forward
    local ports = {
        config.shell_port,
        config.iopub_port,
        config.stdin_port,
        config.control_port,
        config.hb_port,
    }

    local forward_args = ""
    for _, p in ipairs(ports) do
        forward_args = forward_args .. string.format("-L %d:127.0.0.1:%d ", p, p)
    end

    local tunnel_cmd = "ssh -N " .. forward_args .. host
    local handle_data = get_handle_data()

    State.tunnel_job_id = vim.fn.jobstart(tunnel_cmd, {
        on_stdout = handle_data,
        on_stderr = handle_data,
        on_exit = function(_, code)
            if code ~= 0 and code ~= 143 then -- 143 is SIGTERM
                vim.notify("Jovian: SSH Tunnel died with code " .. code, vim.log.levels.ERROR)
                State.tunnel_job_id = nil
            end
        end,
    })

    -- Rewrite local connection file
    local local_config = vim.deepcopy(config)
    local_config.ip = "127.0.0.1"
    local local_path = "/tmp/jovian_tunnel_" .. host .. ".json"
    vim.fn.writefile({ vim.json.encode(local_config) }, local_path)

    Config.options.connection_file = local_path
    Config.options.python_interpreter = "python3" -- Use local python to connect to forwarded ports

    vim.notify("[Jovian] Tunnel established (5 ports forwarded)", vim.log.levels.INFO)
    if on_success then
        on_success()
    end
end

function M.stop(on_done)
    if State.tunnel_job_id then
        vim.fn.jobstop(State.tunnel_job_id)
        State.tunnel_job_id = nil
    end

    if State.remote_kernel_pid and State.tunnel_host then
        local kill_cmd =
            string.format('ssh %s "kill %s && rm /tmp/jovian_kernel.json"', State.tunnel_host, State.remote_kernel_pid)
        vim.fn.jobstart(kill_cmd, {
            on_exit = function()
                State.remote_kernel_pid = nil
                State.tunnel_host = nil
                vim.notify("[Jovian] Tunnel closed and remote kernel killed", vim.log.levels.INFO)
                if on_done then
                    on_done()
                end
            end,
        })
    else
        if on_done then
            on_done()
        end
    end
end

return M
