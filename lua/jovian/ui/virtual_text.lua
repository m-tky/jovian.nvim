local M = {}
local Config = require("jovian.config")
local State = require("jovian.state")

function M.flash_range(start_line, end_line)
	vim.api.nvim_buf_clear_namespace(0, State.hl_ns, 0, -1)
	vim.api.nvim_buf_set_extmark(0, State.hl_ns, start_line - 1, 0, {
		end_row = end_line,
		hl_group = Config.options.flash_highlight_group,
		hl_eol = true,
		priority = 200,
	})
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(0) then
			vim.api.nvim_buf_clear_namespace(0, State.hl_ns, 0, -1)
		end
	end, Config.options.flash_duration)
end

function M.set_cell_status(bufnr, cell_id, status, msg)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for i, line in ipairs(lines) do
		if line:find('id="' .. cell_id .. '"', 1, true) then
			local hl_group = "Comment"
			if status == "running" then
				hl_group = "WarningMsg"
			elseif status == "done" then
		hl_group = "String"
    elseif status == "stale" then
        hl_group = "Comment"
	elseif status == "error" then
		hl_group = "ErrorMsg"
			end

            -- Defensive: Clear any existing status on this line first
			vim.api.nvim_buf_clear_namespace(bufnr, State.status_ns, i - 1, i)
			local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, State.status_ns, i - 1, 0, {
				virt_text = { { "  " .. msg, hl_group } },
				virt_text_pos = "eol",
			})
            State.cell_status_extmarks[cell_id] = extmark_id
			return
		end
	end
end

function M.clean_invalid_extmarks(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
    
    -- Iterate over tracked extmarks
    for cell_id, extmark_id in pairs(State.cell_status_extmarks) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, State.status_ns, extmark_id, {})
        if #mark > 0 then
            local row = mark[1]
            local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
            -- Strict check: Line must exist AND contain the correct cell_id
            if #lines == 0 or not lines[1]:find('id="' .. cell_id .. '"', 1, true) then
                vim.api.nvim_buf_del_extmark(bufnr, State.status_ns, extmark_id)
                State.cell_status_extmarks[cell_id] = nil
            end
        else
            -- Extmark already gone (deleted by nvim?)
            State.cell_status_extmarks[cell_id] = nil
        end
    end
end

function M.clear_status_extmarks(bufnr, start_line, end_line)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
    -- If start/end not provided, clear all
    local s = start_line and (start_line - 1) or 0
    local e = end_line or -1
    vim.api.nvim_buf_clear_namespace(bufnr, State.status_ns, s, e)
end

function M.get_cell_status_extmark(bufnr, line)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return nil end
    -- Use {line, col} to ensure it's treated as a position, not an ID
    local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, State.status_ns, {line - 1, 0}, {line, 0}, { details = true })
    if #extmarks > 0 then
        local mark = extmarks[1]
        local id = mark[1]
        local details = mark[4]
        local virt_text = details.virt_text
        if virt_text and #virt_text > 0 then
            local text = virt_text[1][1]
            local hl = virt_text[1][2]
            local status = "unknown"
            if hl == "WarningMsg" then status = "running"
            elseif hl == "String" then status = "done"
            elseif hl == "Comment" then status = "stale"
            elseif hl == "ErrorMsg" then status = "error"
            end
            -- Remove leading "  " from msg
            local msg = text:gsub("^%s+", "")
            return { id = id, status = status, msg = msg }
        end
    end
    return nil
end

function M.delete_status_extmark(bufnr, id)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
    vim.api.nvim_buf_del_extmark(bufnr, State.status_ns, id)
end

function M.clear_diagnostics()
    vim.diagnostic.reset(State.diag_ns)
end

return M
