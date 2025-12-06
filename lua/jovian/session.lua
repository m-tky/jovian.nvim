local M = {}
local State = require("jovian.state")
local Config = require("jovian.config")
local UI = require("jovian.ui")
local Cell = require("jovian.cell")

function M.clean_stale_cache(bufnr)
	if not State.job_id then
		return
	end
    
    -- Handle command opts table or nil
    if type(bufnr) == "table" or not bufnr then
        bufnr = 0
    end
    
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

	local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
	if filename == "" then
		return
	end
    
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local valid_ids = {}
	for _, line in ipairs(lines) do
		local id = line:match('id="([%w%-_]+)"')
		if id then
			table.insert(valid_ids, id)
		end
	end
    
    local file_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
    local cache_dir = file_dir .. "/.jovian_cache/" .. filename
    
	local msg = vim.json.encode({
		command = "purge_cache",
		filename = filename,
		file_dir = cache_dir,
		ids = valid_ids,
	})
    pcall(vim.api.nvim_chan_send, State.job_id, msg .. "\n")
    vim.notify("Cleaned stale cache for " .. filename, vim.log.levels.INFO)
end

function M.clear_cache(ids)
    if not State.job_id then return end
    local filename = vim.fn.expand("%:t")
    if filename == "" then return end
    local file_dir = vim.fn.expand("%:p:h")
    local cache_dir = file_dir .. "/.jovian_cache/" .. filename
    
    local msg = vim.json.encode({
        command = "remove_cache",
        filename = filename,
        file_dir = cache_dir,
        ids = ids
    })
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")
end

function M.clear_current_cell_cache()
    local id = Cell.get_current_cell_id(nil, false)
    if not id then return end
    M.clear_cache({id})
    UI.set_cell_status(0, id, nil, nil) -- Clear status
    vim.notify("Cleared cache for cell " .. id, vim.log.levels.INFO)
end

function M.clear_all_cache()
    local ids = vim.tbl_keys(Cell.get_all_ids(0))
    M.clear_cache(ids)
    UI.clear_status_extmarks(0)
    vim.notify("Cleared all cache", vim.log.levels.INFO)
end

function M.clean_orphaned_caches(dir)
    dir = dir or vim.fn.getcwd()
    local cache_root = dir .. "/.jovian_cache"
    
    if vim.fn.isdirectory(cache_root) == 0 then
        return
    end
    
    -- Iterate over directories in .jovian_cache
    local scanner = vim.loop.fs_scandir(cache_root)
    if scanner then
        while true do
            local name, type = vim.loop.fs_scandir_next(scanner)
            if not name then break end
            
            if type == "directory" then
                -- Check if the corresponding source file exists
                -- The cache directory name is the filename (e.g., "script.py")
                local source_file = dir .. "/" .. name
                if vim.fn.filereadable(source_file) == 0 then
                    -- Source file missing, delete cache
                    local cache_path = cache_root .. "/" .. name
                    vim.fn.delete(cache_path, "rf")
                    -- vim.notify("Cleaned orphaned cache: " .. name, vim.log.levels.INFO)
                end
            end
        end
    end
end

function M.check_structure_change()
    local bufnr = vim.api.nvim_get_current_buf()
    UI.clean_invalid_extmarks(bufnr)
    
    -- Check for stale cells
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local current_cell_id = nil
    local current_cell_line = nil
    local current_cell_lines = {}
    
    for i, line in ipairs(lines) do
        local id = line:match('id="([%w%-_]+)"')
        if id then
            -- Process previous cell
            if current_cell_id and #current_cell_lines > 0 then
                local code = table.concat(current_cell_lines, "\n")
                local current_hash = Cell.get_cell_hash(code)
                local stored_hash = State.cell_hashes[current_cell_id]
                
                if stored_hash and stored_hash ~= current_hash then
                    local mark = UI.get_cell_status_extmark(bufnr, current_cell_line)
                    if mark and (mark.status == "done" or mark.status == "error") then
                         UI.set_cell_status(bufnr, current_cell_id, "stale", "? Stale")
                    end
                elseif stored_hash and stored_hash == current_hash then
                     local mark = UI.get_cell_status_extmark(bufnr, current_cell_line)
                     if mark and mark.status == "stale" then
                         UI.set_cell_status(bufnr, current_cell_id, "done", Config.options.ui_symbols.done)
                     end
                end
            end
            
            current_cell_id = id
            current_cell_line = i -- Record the line number of the header
            current_cell_lines = {}
        elseif current_cell_id then
             if not line:match("^# %%%%") then
                 table.insert(current_cell_lines, line)
             end
        end
    end
    
    -- Process last cell
    if current_cell_id and #current_cell_lines > 0 then
        local code = table.concat(current_cell_lines, "\n")
        local current_hash = Cell.get_cell_hash(code)
        local stored_hash = State.cell_hashes[current_cell_id]
        
        if stored_hash and stored_hash ~= current_hash then
            local mark = UI.get_cell_status_extmark(bufnr, current_cell_line)
            if mark and (mark.status == "done" or mark.status == "error") then
                 UI.set_cell_status(bufnr, current_cell_id, "stale", "? Stale")
            end
        elseif stored_hash and stored_hash == current_hash then
             local mark = UI.get_cell_status_extmark(bufnr, current_cell_line)
             if mark and mark.status == "stale" then
                 UI.set_cell_status(bufnr, current_cell_id, "done", Config.options.ui_symbols.done)
             end
        end
    end
end

local structure_timer = nil
function M.schedule_structure_check()
    if structure_timer then
        structure_timer:close()
    end
    structure_timer = vim.loop.new_timer()
    structure_timer:start(200, 0, vim.schedule_wrap(function()
        M.check_structure_change()
        if structure_timer then
            structure_timer:close()
            structure_timer = nil
        end
    end))
end

function M.check_cursor_cell()
	-- if not State.job_id then return end -- Allow checking cache even if kernel is not running
	vim.schedule(function()
		local cell_id = Cell.get_current_cell_id(nil, false)
        if not cell_id then return end
		local filename = vim.fn.expand("%:t")
		if filename == "" then
			filename = "scratchpad"
		end
        local file_dir = vim.fn.expand("%:p:h")
		local cache_dir = file_dir .. "/.jovian_cache/" .. filename
		local rel_path = cache_dir .. "/" .. cell_id .. ".md"
		local md_path = vim.fn.fnamemodify(rel_path, ":p")
		if State.current_preview_file ~= md_path and vim.fn.filereadable(md_path) == 1 then
			UI.open_markdown_preview(md_path)
		end
	end)
end

function M.sync_remote_file(remote_path)
    if not Config.options.ssh_host then return end
    
    local host = Config.options.ssh_host
    local local_path = remote_path -- We assume paths match because we sent the local path as file_dir
    
    -- Ensure local directory exists
    local dir = vim.fn.fnamemodify(local_path, ":h")
    vim.fn.mkdir(dir, "p")
    
    local cmd = string.format("scp %s:%s %s", host, remote_path, local_path)
    vim.fn.system(cmd)
end

function M.save_execution_result(msg)
    if Config.options.ssh_host then
        M.sync_remote_file(msg.file)
        -- Images are handled by base64 writing below or implicit sync if they were files
    end

    -- Sync content to local cache if provided (SSH or Local)
    if msg.content_md then
        local cell_id = msg.cell_id
        local filename = vim.fn.expand("%:t")
        if filename == "" then filename = "scratchpad" end
        local file_dir = vim.fn.expand("%:p:h")
        local cache_dir = file_dir .. "/.jovian_cache/" .. filename
        
        -- Ensure cache dir exists
        vim.fn.mkdir(cache_dir, "p")
        
        -- Write Images
        if msg.images then
            for img_name, b64 in pairs(msg.images) do
                local img_path = cache_dir .. "/" .. img_name
                local write_script = string.format(
                    "import base64, sys; open('%s', 'wb').write(base64.b64decode(sys.stdin.read()))",
                    img_path
                )
                vim.fn.system({Config.options.python_interpreter, "-c", write_script}, b64)
            end
        end

        -- Write MD
        local md_path = cache_dir .. "/" .. cell_id .. ".md"
        local f = io.open(md_path, "w")
        if f then
            f:write(msg.content_md)
            f:close()
            msg.file = md_path -- Update to local path
        end
    end
end

return M
