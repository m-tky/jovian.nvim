-- omnifunc backed by jovian-core's `complete` RPC, which proxies the
-- kernel's complete_request and returns the standard Jupyter
-- complete_reply content.

local M = {}
local State = require("jovian.state")
local Core = require("jovian.backend.core")

function M.complete(findstart, _)
    if findstart == 1 then
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local line_to_cursor = line:sub(1, col)
        return vim.fn.match(line_to_cursor, [[\k*$]])
    end

    if not State.rust_session_id then return {} end
    local client = Core.client()
    if not client then return {} end

    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local result, err = client:request_sync("complete", {
        session_id = State.rust_session_id,
        code = line,
        cursor_pos = col,
    }, 500)
    if err or not result then return {} end

    local matches = result.matches or {}
    local formatted = {}
    for _, m in ipairs(matches) do
        table.insert(formatted, { word = m, menu = "[Jupyter]" })
    end
    return formatted
end

function M.setup_omnifunc()
    vim.bo.omnifunc = "v:lua.require'jovian.complete'.complete"
end

return M
