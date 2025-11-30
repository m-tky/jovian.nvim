local M = {}
local UI = require("jovian.ui")

-- Seed random number generator once
math.randomseed(os.time() + math.floor(os.clock() * 1000))

function M.generate_id(existing_ids)
	local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
	local id = ""
	local max_attempts = 100

	for _ = 1, max_attempts do
		id = ""
		for i = 1, 12 do
			local rand = math.random(#chars)
			id = id .. string.sub(chars, rand, rand)
		end

		if not existing_ids or not existing_ids[id] then
			return id
		end
	end
	return id .. "_" .. os.time() -- Fallback
end

function M.get_all_ids(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false)
	local ids = {}
	for _, line in ipairs(lines) do
		local id = line:match('id="([%w%-_]+)"')
		if id then
			ids[id] = true
		end
	end
	return ids
end

function M.fix_duplicate_ids(bufnr)
	local buf = bufnr or 0
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local seen_ids = {}
	local updates = {}

	for i, line in ipairs(lines) do
		local id = line:match('id="([%w%-_]+)"')
		if id then
			if seen_ids[id] then
				-- Duplicate found, generate new unique ID
				-- We pass seen_ids to ensure the new ID doesn't conflict with what we've seen so far
				local new_id = M.generate_id(seen_ids)
				local new_line = line:gsub('id="[%w%-_]+"', 'id="' .. new_id .. '"')
				table.insert(updates, { lnum = i - 1, line = new_line })
				seen_ids[new_id] = true
			else
				seen_ids[id] = true
			end
		end
	end

	-- Apply updates in reverse order to avoid index shifting issues (though set_lines handles ranges)
	-- Here we just update specific lines
	for _, update in ipairs(updates) do
		vim.api.nvim_buf_set_lines(buf, update.lnum, update.lnum + 1, false, { update.line })
	end

	if #updates > 0 then
		vim.notify("Jovian: Fixed " .. #updates .. " duplicate cell IDs", vim.log.levels.INFO)
	end
end

function M.get_cell_range(lnum)
	local cursor = lnum or vim.fn.line(".")
	local total = vim.api.nvim_buf_line_count(0)
	local s, e = cursor, cursor
	while s > 1 do
		local line = vim.api.nvim_buf_get_lines(0, s - 1, s, false)[1]
		if line:match("^# %%%%") then
			break
		end
		s = s - 1
	end
	while e < total do
		local line = vim.api.nvim_buf_get_lines(0, e, e + 1, false)[1]
		if line:match("^# %%%%") then
			break
		end
		e = e + 1
	end
	return s, e
end

function M.ensure_cell_id(line_num, line_content)
	local id = line_content:match('id="([%w%-_]+)"')
	if id then
		-- Check if this ID is actually unique in the buffer?
		-- Performing a full scan here might be expensive but ensures correctness.
		-- For now, we assume existing IDs are unique unless we are generating a NEW one.
		-- If we want to be strictly safe, we should check duplicates here too,
		-- but fix_duplicate_ids should be called on load.
		return id
	end

	local all_ids = M.get_all_ids(0)
	id = M.generate_id(all_ids)

	if line_content:match("^# %%%%") then
		local new_line = line_content .. ' id="' .. id .. '"'
		vim.api.nvim_buf_set_lines(0, line_num - 1, line_num, false, { new_line })
	end
	return id
end

function M.get_current_cell_id(lnum)
	local s, _ = M.get_cell_range(lnum)
	local lines = vim.api.nvim_buf_get_lines(0, s - 1, s, false)
	local line = lines[1] or ""
	local id = line:match('id="([%w%-_]+)"')
	if id then
		return id
	end
	if line:match("^# %%%%") then
		return M.ensure_cell_id(s, line)
	end
	return "scratchpad"
end

-- Cell Editing Features

function M.delete_cell()
	local s, e = M.get_cell_range()
	local total = vim.api.nvim_buf_line_count(0)

	-- Check if the next line is a header
	if e < total then
		local next_line = vim.api.nvim_buf_get_lines(0, e, e + 1, false)[1]
		if next_line and not next_line:match("^# %%%%") then
			-- If next line is NOT a header (e.g. empty line), delete it too
			e = e + 1
		end
	end

	-- Clear status for the range being deleted + next line (if it was a header that moved up)
    -- Actually, we are deleting lines s-1 to e.
    -- We should clear status on these lines before deletion to be safe,
    -- AND clear status on the line that will *become* the new s-1 (which is currently e+1)
    -- because if we delete a cell, the next cell moves up.
    -- But simpler: just clear the range we are about to delete.
    -- AND clear the *entire buffer* status? No, that's too aggressive.
    -- Let's clear the range [s, e] (1-based)
    UI.clear_status_extmarks(0, s, s) -- Only clear the header line of the deleted cell
    
    -- Also clear the line *after* the deleted block because it will shift up
    -- and might inherit some ghost mark if we are not careful (though extmarks usually move with text).
    -- The issue is often that the *previous* mark stays.
    -- Let's clear a bit more context to be safe.
    -- UI.clear_status_extmarks(0, math.max(1, s - 1), e + 1) -- Removed aggressive clear

	vim.api.nvim_buf_set_lines(0, s - 1, e, false, {})
end

function M.move_cell_up()
	local s, e = M.get_cell_range()
	if s <= 1 then
		return
	end -- Already at top

	-- Find previous cell
	local prev_e = s - 1
	local prev_s, _ = M.get_cell_range(prev_e)

	-- Get contents
	local curr_lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
	local prev_lines = vim.api.nvim_buf_get_lines(0, prev_s - 1, prev_e, false)

    -- Clear status (User requested to remove virtual text of both cells)
    UI.clear_status_extmarks(0, s, s)
    UI.clear_status_extmarks(0, prev_s, prev_s)

	-- Swap using single atomic set_lines to fix undo
    -- Range to replace: prev_s to e (inclusive 1-based) -> prev_s-1 to e (exclusive 0-based)
    -- New content: curr_lines + prev_lines
    local new_lines = {}
    for _, line in ipairs(curr_lines) do table.insert(new_lines, line) end
    for _, line in ipairs(prev_lines) do table.insert(new_lines, line) end

    vim.api.nvim_buf_set_lines(0, prev_s - 1, e, false, new_lines)

	-- Move cursor to new position of moved cell
	vim.api.nvim_win_set_cursor(0, { prev_s, 0 })
end

function M.move_cell_down()
	local s, e = M.get_cell_range()
	local total = vim.api.nvim_buf_line_count(0)
	if e >= total then
		return
	end -- Already at bottom

	-- Find next cell
	local next_s = e + 1
	local _, next_e = M.get_cell_range(next_s)

	-- Get contents
	local curr_lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
	local next_lines = vim.api.nvim_buf_get_lines(0, next_s - 1, next_e, false)

    -- Clear status (User requested to remove virtual text of both cells)
    UI.clear_status_extmarks(0, s, s)
    UI.clear_status_extmarks(0, next_s, next_s)

	-- Swap using single atomic set_lines to fix undo
    -- Range to replace: s to next_e (inclusive 1-based) -> s-1 to next_e (exclusive 0-based)
    -- New content: next_lines + curr_lines
    local new_lines = {}
    for _, line in ipairs(next_lines) do table.insert(new_lines, line) end
    for _, line in ipairs(curr_lines) do table.insert(new_lines, line) end

    vim.api.nvim_buf_set_lines(0, s - 1, next_e, false, new_lines)

	-- Move cursor
	vim.api.nvim_win_set_cursor(0, { s + #next_lines, 0 })
end

function M.split_cell()
	local cursor_row = vim.fn.line(".")

	local id = M.generate_id(M.get_all_ids(0))
	local header = '# %% id="' .. id .. '"'

	-- Insert AFTER the current line
	-- Add empty line before and after header for clarity
	vim.api.nvim_buf_set_lines(0, cursor_row, cursor_row, false, { "", header })
    
    -- Clear status on the new lines
    UI.clear_status_extmarks(0, cursor_row + 1, cursor_row + 2)
end

return M
