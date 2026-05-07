local ffi = require("ffi")

ffi.cdef([[
    void *zmq_ctx_new();
    void *zmq_socket(void *context, int type);
    int zmq_connect(void *socket, const char *endpoint);
    int zmq_close(void *socket);
    int zmq_ctx_destroy(void *context);
    int zmq_msg_init(void *msg);
    int zmq_msg_send(void *msg, void *socket, int flags);
    int zmq_msg_recv(void *msg, void *socket, int flags);
    int zmq_send(void *socket, const void *buf, size_t len, int flags);
    int zmq_recv(void *socket, void *buf, size_t len, int flags);
    void *zmq_msg_data(void *msg);
    size_t zmq_msg_size(void *msg);
    int zmq_msg_close(void *msg);
    int zmq_getsockopt(void *socket, int option, void *optval, size_t *optvallen);
    int zmq_setsockopt(void *socket, int option, const void *optval, size_t optvallen);
]])

local zmq_lib = nil
local function get_zmq()
    if zmq_lib then
        return zmq_lib
    end
    -- Default search (system paths)
    local ok, lib = pcall(ffi.load, "zmq")
    if ok then
        zmq_lib = lib
        return zmq_lib
    end
    return nil
end

local M = {}

---Try to load ZMQ from a specific absolute path.
---@param path string
---@return boolean success
function M.load_from_path(path)
    local ok, lib = pcall(ffi.load, path)
    if ok then
        zmq_lib = lib
        return true
    end
    return false
end

---Asynchronously discover bundled libzmq in the Python environment.
---@param python_bin string Path to python interpreter
---@param callback fun(success: boolean, path?: string)
function M.discover_bundled(python_bin, callback)
    local script = [[
import zmq, os, glob, sys
try:
    # Some versions of pyzmq have a subpackage for libzmq
    import zmq.libzmq as libzmq
    print(libzmq.__file__)
except ImportError:
    # Manual search in zmq directory and zmq.libs
    d = os.path.dirname(zmq.__file__)
    p = os.path.dirname(d)
    ext = "so"
    if sys.platform == "darwin": ext = "dylib"
    elif sys.platform == "win32": ext = "dll"

    # Common patterns for bundled libzmq in wheels
    patterns = [
        os.path.join(d, "libzmq*." + ext + "*"),
        os.path.join(p, "zmq.libs", "libzmq*." + ext + "*"),
        os.path.join(d, "*." + ext + "*"), # generic fallback
    ]
    found = False
    for pat in patterns:
        files = glob.glob(pat)
        if files:
            print(files[0])
            found = True
            break
]]
    if vim.fn.executable(python_bin) ~= 1 then
        callback(false)
        return
    end

    vim.system({ python_bin, "-c", script }, { text = true }, function(obj)
        local path = vim.trim(obj.stdout or "")
        if path ~= "" and vim.fn.filereadable(path) == 1 then
            vim.schedule(function()
                local ok = M.load_from_path(path)
                callback(ok, path)
            end)
        else
            vim.schedule(function()
                callback(false)
            end)
        end
    end)
end

function M.is_available()
    return get_zmq() ~= nil
end

M.SUB = 2
M.REQ = 3
M.SUBSCRIBE = 6
M.DONTWAIT = 1
M.RCVMORE = 13
M.SNDMORE = 2

function M.new_ctx()
    local lib = get_zmq()
    return lib and lib.zmq_ctx_new()
end

function M.new_socket(ctx, type)
    local lib = get_zmq()
    return lib and lib.zmq_socket(ctx, type)
end

function M.connect(socket, endpoint)
    local lib = get_zmq()
    return lib and lib.zmq_connect(socket, endpoint) == 0
end

function M.recv_msg(socket, flags)
    local lib = get_zmq()
    if not lib then
        return nil
    end
    local msg = ffi.new("uint8_t[64]") -- Rough size for msg struct
    lib.zmq_msg_init(msg)
    local len = lib.zmq_msg_recv(msg, socket, flags or 0)
    if len < 0 then
        lib.zmq_msg_close(msg)
        return nil
    end
    local data = ffi.string(lib.zmq_msg_data(msg), len)
    lib.zmq_msg_close(msg)
    return data
end

function M.has_more(socket)
    local lib = get_zmq()
    if not lib then
        return false
    end
    local more = ffi.new("int[1]")
    local size = ffi.new("size_t[1]", ffi.sizeof("int"))
    lib.zmq_getsockopt(socket, M.RCVMORE, more, size)
    return more[0] == 1
end

function M.setsockopt(socket, option, value, len)
    local lib = get_zmq()
    return lib and lib.zmq_setsockopt(socket, option, value, len or #value) == 0
end

function M.send(socket, data, flags)
    local lib = get_zmq()
    return lib and lib.zmq_send(socket, data, #data, flags or 0)
end

function M.recv(socket, len, flags)
    local lib = get_zmq()
    if not lib then
        return nil
    end
    len = len or 4096
    local buf = ffi.new("uint8_t[?]", len)
    local actual_len = lib.zmq_recv(socket, buf, len, flags or 0)
    if actual_len < 0 then
        return nil
    end
    return ffi.string(buf, actual_len)
end

return M
