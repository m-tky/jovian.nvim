local ffi = require("ffi")
local zmq = require("jovian.backend.zmq")

ffi.cdef([[
    typedef struct engine_st ENGINE;
    typedef struct evp_md_st EVP_MD;
    const EVP_MD *EVP_sha256(void);
    unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len,
                        const unsigned char *d, size_t n, unsigned char *md,
                        unsigned int *md_len);
]])

local crypto_lib = nil
local function get_crypto()
    if crypto_lib then
        return crypto_lib
    end
    local ok, lib = pcall(ffi.load, "crypto")
    if not ok then
        error("Jovian: libcrypto not found. Please ensure openssl is installed.")
    end
    crypto_lib = lib
    return crypto_lib
end

local function hmac_sha256(key, data)
    if not key or key == "" then
        return ""
    end
    local md = ffi.new("unsigned char[32]")
    local md_len = ffi.new("unsigned int[1]")
    get_crypto().HMAC(get_crypto().EVP_sha256(), key, #key, data, #data, md, md_len)

    local hex = ""
    for i = 0, 31 do
        hex = hex .. string.format("%02x", md[i])
    end
    return hex
end

local M = {}

function M.parse_multipart(socket, flags)
    local parts = {}
    repeat
        local part = zmq.recv_msg(socket, flags)
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

function M.create_message(msg_type, content, parent_header, metadata)
    local header = {
        msg_id = vim.fn.reltimestr(vim.fn.reltime()):gsub("%.", ""),
        username = "jovian",
        session = "jovian-session",
        msg_type = msg_type,
        version = "5.3",
        date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    return {
        header = header,
        parent_header = parent_header or {},
        metadata = metadata or {},
        content = content or {},
    }
end

function M.send_message(socket, msg, key)
    local h = vim.json.encode(msg.header)
    local p = vim.json.encode(msg.parent_header)
    local m = vim.json.encode(msg.metadata)
    local c = vim.json.encode(msg.content)

    local signature_data = h .. p .. m .. c
    local signature = hmac_sha256(key, signature_data)

    zmq.send(socket, msg.header.msg_id, zmq.SNDMORE)
    zmq.send(socket, "<IDS|MSG>", zmq.SNDMORE)
    zmq.send(socket, signature, zmq.SNDMORE)
    zmq.send(socket, h, zmq.SNDMORE)
    zmq.send(socket, p, zmq.SNDMORE)
    zmq.send(socket, m, zmq.SNDMORE)
    zmq.send(socket, c, 0)

    return msg.header.msg_id
end

return M
