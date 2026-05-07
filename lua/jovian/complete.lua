local M = {}
local State = require("jovian.state")
local Messenger = require("jovian.backend.messenger")
local Zmq = require("jovian.backend.zmq")

function M.complete(findstart, _)
    if findstart == 1 then
        -- Find the start of the word
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local line_to_cursor = line:sub(1, col)
        local start = vim.fn.match(line_to_cursor, [[\k*$]])
        return start
    else
        -- Get completions from kernel
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local timeout = 0.5 -- seconds
        local start_t = os.clock()
        local results = nil

        if State.lua_shell_socket then
            -- High Performance Native Path
            local req = Messenger.create_message("complete_request", {
                code = line,
                cursor_pos = col,
            })
            local msg_id = Messenger.send_message(State.lua_shell_socket, req, State.lua_zmq_key)

            while os.clock() - start_t < timeout do
                local reply = Messenger.parse_multipart(State.lua_shell_socket, Zmq.DONTWAIT)
                if reply then
                    if reply.parent_header.msg_id == msg_id then
                        results = reply.content.matches
                        break
                    end
                end
                vim.wait(10)
            end
        elseif State.job_id then
            -- Fallback Python Bridge Path
            State.last_completion_results = nil
            local payload = vim.json.encode({
                command = "complete",
                code = line,
                cursor_pos = col,
            })
            vim.api.nvim_chan_send(State.job_id, payload .. "\n")

            while os.clock() - start_t < timeout do
                if State.last_completion_results then
                    results = State.last_completion_results
                    State.last_completion_results = nil
                    break
                end
                vim.wait(10)
            end
        end

        if results then
            local formatted = {}
            for _, m in ipairs(results) do
                table.insert(formatted, { word = m, menu = "[Jupyter]" })
            end
            return formatted
        end

        return {}
    end
end

-- Function to set up omnifunc in current buffer
function M.setup_omnifunc()
    vim.bo.omnifunc = "v:lua.require'jovian.complete'.complete"
end

return M
