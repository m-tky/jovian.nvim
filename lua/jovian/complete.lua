local M = {}
local State = require("jovian.state")
local Messenger = require("jovian.backend.messenger")
local Zmq = require("jovian.backend.zmq")

function M.complete(findstart, base)
    if findstart == 1 then
        -- Find the start of the word
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local line_to_cursor = line:sub(1, col)
        local start = vim.fn.match(line_to_cursor, [[\k*$]])
        return start
    else
        -- Get completions from kernel
        if not State.lua_shell_socket then
            return {}
        end

        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        
        local req = Messenger.create_message("complete_request", {
            code = line,
            cursor_pos = col,
        })
        
        local msg_id = Messenger.send_message(State.lua_shell_socket, req, State.lua_zmq_key)
        
        local timeout = 0.5 -- seconds
        local start_t = os.clock()
        
        while os.clock() - start_t < timeout do
            local reply = Messenger.parse_multipart(State.lua_shell_socket, Zmq.DONTWAIT)
            if reply then
                if reply.parent_header.msg_id == msg_id then
                    local matches = reply.content.matches
                    local results = {}
                    for _, m in ipairs(matches) do
                        table.insert(results, { word = m, menu = "[Jupyter]" })
                    end
                    return results
                end
            end
            vim.wait(10)
        end
        
        return {}
    end
end

-- Function to set up omnifunc in current buffer
function M.setup_omnifunc()
    vim.bo.omnifunc = "v:lua.require'jovian.complete'.complete"
end

return M
