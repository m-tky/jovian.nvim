local ffi = require("ffi")

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

local zmq = ffi.load("zmq")

local M = {}

M.SUB = 2
M.SUBSCRIBE = 6
M.DONTWAIT = 1
M.RCVMORE = 13

function M.new_ctx()
    return zmq.zmq_ctx_new()
end

function M.new_socket(ctx, type)
    return zmq.zmq_socket(ctx, type)
end

function M.connect(socket, endpoint)
    return zmq.zmq_connect(socket, endpoint) == 0
end

function M.recv_msg(socket, flags)
    local msg = ffi.new("uint8_t[64]") -- Rough size for msg struct
    zmq.zmq_msg_init(msg)
    local len = zmq.zmq_msg_recv(msg, socket, flags or 0)
    if len < 0 then
        zmq.zmq_msg_close(msg)
        return nil
    end
    local data = ffi.string(zmq.zmq_msg_data(msg), len)
    zmq.zmq_msg_close(msg)
    return data
end

function M.has_more(socket)
    local more = ffi.new("int[1]")
    local size = ffi.new("size_t[1]", ffi.sizeof("int"))
    zmq.zmq_getsockopt(socket, M.RCVMORE, more, size)
    return more[0] == 1
end

function M.setsockopt(socket, option, value, len)
    return zmq.zmq_setsockopt(socket, option, value, len or #value) == 0
end

return M
