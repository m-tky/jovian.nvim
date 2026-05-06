local ffi = require("ffi")

local zmq_lib = nil
local function get_zmq()
    if zmq_lib then
        return zmq_lib
    end
    ffi.cdef([[
        void *zmq_ctx_new();
        void *zmq_socket(void *context, int type);
        int zmq_connect(void *socket, const char *endpoint);
        int zmq_close(void *socket);
        int zmq_ctx_destroy(void *context);
        int zmq_msg_init(void *msg);
        int zmq_msg_recv(void *msg, void *socket, int flags);
        void *zmq_msg_data(void *msg);
        size_t zmq_msg_size(void *msg);
        int zmq_msg_close(void *msg);
        int zmq_getsockopt(void *socket, int option, void *optval, size_t *optvallen);
        int zmq_setsockopt(void *socket, int option, const void *optval, size_t optvallen);
    ]])
    local ok, lib = pcall(ffi.load, "zmq")
    if not ok then
        error("Jovian: libzmq.so not found. Please ensure zeromq is installed.")
    end
    zmq_lib = lib
    return zmq_lib
end

local M = {}

M.SUB = 2
M.SUBSCRIBE = 6
M.DONTWAIT = 1
M.RCVMORE = 13

function M.new_ctx()
    return get_zmq().zmq_ctx_new()
end

function M.new_socket(ctx, type)
    return get_zmq().zmq_socket(ctx, type)
end

function M.connect(socket, endpoint)
    return get_zmq().zmq_connect(socket, endpoint) == 0
end

function M.recv_msg(socket, flags)
    local msg = ffi.new("uint8_t[64]") -- Rough size for msg struct
    get_zmq().zmq_msg_init(msg)
    local len = get_zmq().zmq_msg_recv(msg, socket, flags or 0)
    if len < 0 then
        get_zmq().zmq_msg_close(msg)
        return nil
    end
    local data = ffi.string(get_zmq().zmq_msg_data(msg), len)
    get_zmq().zmq_msg_close(msg)
    return data
end

function M.has_more(socket)
    local more = ffi.new("int[1]")
    local size = ffi.new("size_t[1]", ffi.sizeof("int"))
    get_zmq().zmq_getsockopt(socket, M.RCVMORE, more, size)
    return more[0] == 1
end

function M.setsockopt(socket, option, value, len)
    return get_zmq().zmq_setsockopt(socket, option, value, len or #value) == 0
end

return M
