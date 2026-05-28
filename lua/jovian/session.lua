local M = {}
local State = require("jovian.state")
local Config = require("jovian.config")
local UI = require("jovian.ui")
local Cell = require("jovian.cell")

local uv = vim.uv or vim.loop

function M.clean_stale_cache(bufnr)
    -- Handle command opts table or nil
    if type(bufnr) == "table" or not bufnr then
        bufnr = 0
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
    if filename == "" then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local valid_ids_set = {}
    for _, line in ipairs(lines) do
        local id = line:match('id="([%w%-_]+)"')
        if id then
            valid_ids_set[id] = true
        end
    end

    local file_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
    local cache_dir = file_dir .. "/.jovian_cache/" .. filename

    if vim.fn.isdirectory(cache_dir) == 0 then
        return
    end

    local files = vim.fn.readdir(cache_dir)
    local deleted_count = 0

    for _, f in ipairs(files) do
        local file_id = nil
        if f:match("%.md$") then
            file_id = f:sub(1, -4)
        elseif f:match("%.png$") then
            -- Try matching timestamped format: ID_timestamp_counter.png
            file_id = f:match("^(.*)_%d+_%d+%.png$")

            -- Fallback to legacy/simple format: ID_counter.png
            if not file_id then
                file_id = f:match("^(.*)_%d+%.png$")
            end
        end

        -- Only delete if we successfully parsed an ID and it's not valid
        -- If we couldn't parse ID, safer to leave it (or it's weird garbage)
        if file_id and not valid_ids_set[file_id] then
            local full_path = cache_dir .. "/" .. f
            vim.fn.delete(full_path)
            deleted_count = deleted_count + 1
        end
    end
end

function M.clear_cache(ids)
    if not State.job_id then
        return
    end
    local filename = vim.fn.expand("%:t")
    if filename == "" then
        return
    end
    local file_dir = vim.fn.expand("%:p:h")
    local cache_dir = file_dir .. "/.jovian_cache/" .. filename

    local msg = vim.json.encode({
        command = "remove_cache",
        filename = filename,
        file_dir = cache_dir,
        ids = ids,
    })
    vim.api.nvim_chan_send(State.job_id, msg .. "\n")
end

function M.clear_current_cell_cache()
    local id = Cell.get_current_cell_id(nil, false)
    if not id then
        return
    end
    M.clear_cache({ id })
    UI.set_cell_status(0, id, "idle", "")
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
    local scanner = uv.fs_scandir(cache_root)
    if scanner then
        while true do
            local name, type = uv.fs_scandir_next(scanner)
            if not name then
                break
            end

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
    structure_timer = uv.new_timer()
    structure_timer:start(
        200,
        0,
        vim.schedule_wrap(function()
            M.check_structure_change()
            if structure_timer then
                structure_timer:close()
                structure_timer = nil
            end
        end)
    )
end

function M.check_cursor_cell()
    vim.schedule(function()
        local cell_id = Cell.get_current_cell_id(nil, false)
        if not cell_id then
            return
        end
        -- Rust backend path: render the cell's nbformat outputs directly
        -- from the sidecar JSON into the preview buffer. No .md round-trip.
        if Config.options.use_rust_core then
            local src_path = vim.api.nvim_buf_get_name(0)
            if src_path == "" then
                return
            end
            if not State.buf.preview or not vim.api.nvim_buf_is_valid(State.buf.preview) then
                return
            end
            -- Skip duplicate renders when the cursor stays on the same cell;
            -- cell_event handlers explicitly re-trigger when new output
            -- arrives so this gate doesn't starve fresh content.
            if State.current_preview_cell_id == cell_id then
                return
            end
            State.current_preview_cell_id = cell_id
            State.current_preview_file = nil
            require("jovian.ui.output_render").render_to_buffer(State.buf.preview, State.win.preview, src_path, cell_id)
            return
        end

        -- Legacy path: kernel_bridge.py writes a markdown file per cell
        -- and we load it into the preview verbatim.
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

function M.sync_remote_file(remote_path, on_complete)
    if not Config.options.ssh_host then
        if on_complete then
            on_complete()
        end
        return
    end

    local host = Config.options.ssh_host
    local local_path = remote_path -- We assume paths match because we sent the local path as file_dir

    -- Ensure local directory exists
    local dir = vim.fn.fnamemodify(local_path, ":h")
    vim.fn.mkdir(dir, "p")

    local cmd = { "scp", string.format("%s:%s", host, remote_path), local_path }
    vim.fn.jobstart(cmd, {
        on_exit = function(_, code)
            if code ~= 0 then
                vim.notify("Failed to sync remote file: " .. remote_path, vim.log.levels.ERROR)
            end
            if on_complete then
                on_complete()
            end
        end,
    })
end

function M.save_execution_result(msg, on_complete)
    local function finish()
        -- Write MD (This is usually small and fast, so we do it synchronously or via io.open)
        if msg.content_md then
            local cell_id = msg.cell_id
            local filename = vim.fn.expand("%:t")
            if filename == "" then
                filename = "scratchpad"
            end
            local file_dir = vim.fn.expand("%:p:h")
            local cache_dir = file_dir .. "/.jovian_cache/" .. filename

            -- Ensure cache dir exists
            vim.fn.mkdir(cache_dir, "p")

            local md_path = cache_dir .. "/" .. cell_id .. ".md"
            local f = io.open(md_path, "w")
            if f then
                f:write(msg.content_md)
                f:close()
                msg.file = md_path -- Update to local path
            end
        end

        if on_complete then
            on_complete()
        end
    end

    local function handle_images()
        if not msg.images or vim.tbl_count(msg.images) == 0 then
            finish()
            return
        end

        local filename = vim.fn.expand("%:t")
        if filename == "" then
            filename = "scratchpad"
        end
        local cache_dir = vim.fn.expand("%:p:h") .. "/.jovian_cache/" .. filename
        vim.fn.mkdir(cache_dir, "p")

        if vim.base64 then
            for img_name, b64 in pairs(msg.images) do
                local decoded = vim.base64.decode(b64)
                local f = io.open(cache_dir .. "/" .. img_name, "wb")
                if f then
                    f:write(decoded)
                    f:close()
                end
            end
            finish()
        else
            -- Fallback for Neovim < 0.9: spawn Python per image
            local queue = {}
            for img_name, b64 in pairs(msg.images) do
                table.insert(queue, { name = img_name, data = b64 })
            end
            local function process_next(idx)
                if idx > #queue then
                    finish()
                    return
                end
                local item = queue[idx]
                local img_path = cache_dir .. "/" .. item.name
                local script = string.format(
                    "import base64,sys; open('%s','wb').write(base64.b64decode(sys.stdin.read()))",
                    img_path
                )
                local job_id = vim.fn.jobstart({ Config.options.python_interpreter, "-c", script }, {
                    on_exit = function()
                        process_next(idx + 1)
                    end,
                    rpc = false,
                })
                if job_id > 0 then
                    vim.fn.chansend(job_id, item.data)
                    vim.fn.chanclose(job_id, "stdin")
                end
            end
            process_next(1)
        end
    end

    if Config.options.ssh_host then
        M.sync_remote_file(msg.file, handle_images)
    else
        handle_images()
    end
end

return M
