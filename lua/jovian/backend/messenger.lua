local zmq = require("jovian.backend.zmq")

local M = {}

function M.parse_multipart(socket)
    local parts = {}
    repeat
        local part = zmq.recv_msg(socket)
        if part then
            table.insert(parts, part)
        end
    until not zmq.has_more(socket)

    if #parts < 6 then
        return nil
    end

    -- Jupyter Wire Protocol:
    -- 0: ID (can be multiple)
    -- delimiter: "<IDS|MSG>"
    -- signature
    -- header
    -- parent_header
    -- metadata
    -- content

    local delim_idx = -1
    for i, p in ipairs(parts) do
        if p == "<IDS|MSG>" then
            delim_idx = i
            break
        end
    end

    if delim_idx == -1 or delim_idx + 4 > #parts then
        return nil
    end

    local msg = {
        header = vim.json.decode(parts[delim_idx + 2]),
        parent_header = vim.json.decode(parts[delim_idx + 3]),
        metadata = vim.json.decode(parts[delim_idx + 4]),
        content = vim.json.decode(parts[delim_idx + 5]),
    }
    return msg
end

function M.listen_iopub(config, on_msg)
    local ctx = zmq.new_ctx()
    local socket = zmq.new_socket(ctx, zmq.SUB)

    local endpoint = string.format("tcp://%s:%d", config.ip, config.iopub_port)
    zmq.connect(socket, endpoint)

    -- Subscribe to all
    zmq.setsockopt(socket, zmq.SUBSCRIBE, "", 0)

    -- Use luv to poll
    local timer = vim.loop.new_timer()
    timer:start(
        0,
        50,
        vim.schedule_wrap(function()
            while true do
                local msg = M.parse_multipart(socket)
                if not msg then
                    break
                end
                on_msg(msg)
            end
        end)
    )

    return function()
        timer:stop()
        timer:close()
        zmq.zmq_close(socket)
        zmq.zmq_ctx_destroy(ctx)
    end
end

return M
