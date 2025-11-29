local M = {}

-- Seed random number generator once
math.randomseed(os.time() + math.floor(os.clock() * 1000))

function M.generate_id(existing_ids)
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    local id = ""
    local max_attempts = 100
    
    for _ = 1, max_attempts do
        id = ""
        for i = 1, 8 do
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
        local id = line:match("id=\"([%w%-_]+)\"")
        if id then ids[id] = true end
    end
    return ids
end

function M.fix_duplicate_ids(bufnr)
    local buf = bufnr or 0
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local seen_ids = {}
    local updates = {}
    
    for i, line in ipairs(lines) do
        local id = line:match("id=\"([%w%-_]+)\"")
        if id then
            if seen_ids[id] then
                -- Duplicate found, generate new unique ID
                -- We pass seen_ids to ensure the new ID doesn't conflict with what we've seen so far
                local new_id = M.generate_id(seen_ids)
                local new_line = line:gsub("id=\"[%w%-_]+\"", "id=\"" .. new_id .. "\"")
                table.insert(updates, {lnum = i - 1, line = new_line})
                seen_ids[new_id] = true
            else
                seen_ids[id] = true
            end
        end
    end
    
    -- Apply updates in reverse order to avoid index shifting issues (though set_lines handles ranges)
    -- Here we just update specific lines
    for _, update in ipairs(updates) do
        vim.api.nvim_buf_set_lines(buf, update.lnum, update.lnum + 1, false, {update.line})
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
        if line:match("^# %%%%") then break end
        s = s - 1
    end
    while e < total do
        local line = vim.api.nvim_buf_get_lines(0, e, e + 1, false)[1]
        if line:match("^# %%%%") then break end
        e = e + 1
    end
    return s, e
end

function M.ensure_cell_id(line_num, line_content)
    local id = line_content:match("id=\"([%w%-_]+)\"")
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
        local new_line = line_content .. " id=\"" .. id .. "\""
        vim.api.nvim_buf_set_lines(0, line_num - 1, line_num, false, {new_line})
    end
    return id
end

function M.get_current_cell_id(lnum)
    local s, _ = M.get_cell_range(lnum)
    local lines = vim.api.nvim_buf_get_lines(0, s - 1, s, false)
    local line = lines[1] or ""
    local id = line:match("id=\"([%w%-_]+)\"")
    if id then return id end
    if line:match("^# %%%%") then return M.ensure_cell_id(s, line) end
    return "scratchpad"
end

return M
