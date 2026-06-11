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
        end
    end
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
                -- Check if the corresponding source file exists.
                -- The cache directory name is the source filename (e.g. "script.py").
                local source_file = dir .. "/" .. name
                if vim.fn.filereadable(source_file) == 0 then
                    local cache_path = cache_root .. "/" .. name
                    vim.fn.delete(cache_path, "rf")
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

    -- Finalize the cell currently being accumulated: compare its hash to the
    -- stored one and flip done/error↔stale accordingly. Factored out so the
    -- last cell uses the exact same logic as the rest (no duplicated block).
    local function flush()
        if not (current_cell_id and #current_cell_lines > 0) then
            return
        end
        local current_hash = Cell.get_cell_hash(table.concat(current_cell_lines, "\n"))
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

    for i, line in ipairs(lines) do
        if line:match("^# %%%%") then
            -- ANY cell header is a boundary. Flush the previous cell first,
            -- then start a new one. An id-less header yields current_cell_id =
            -- nil, so its body stays untracked instead of leaking into the
            -- previous cell's hash and falsely marking it Stale.
            flush()
            current_cell_id = line:match('id="([%w%-_]+)"')
            current_cell_line = i
            current_cell_lines = {}
        elseif current_cell_id then
            table.insert(current_cell_lines, line)
        end
    end
    flush()
end

-- One reusable debounce timer driven by stop()/start(); creating and closing
-- a new timer per event raced (a superseded timer's scheduled callback could
-- close the timer that replaced it).
local structure_timer = uv.new_timer()
function M.schedule_structure_check()
    structure_timer:stop()
    structure_timer:start(200, 0, vim.schedule_wrap(M.check_structure_change))
end

-- Preview-on-cursor: render the cell under the cursor into the preview
-- pane straight from the sidecar JSON. cell_event handlers re-render the
-- same cell on new output, so the same-cell early-exit doesn't starve.
function M.check_cursor_cell()
    vim.schedule(function()
        local cell_id = Cell.get_current_cell_id(nil, false)
        if not cell_id then
            return
        end
        local src_path = vim.api.nvim_buf_get_name(0)
        if src_path == "" then
            return
        end
        if not State.buf.preview or not vim.api.nvim_buf_is_valid(State.buf.preview) then
            return
        end
        if State.current_preview_cell_id == cell_id then
            return
        end
        State.current_preview_cell_id = cell_id
        require("jovian.ui.output_render").render_to_buffer(State.buf.preview, State.win.preview, src_path, cell_id)
    end)
end

-- Wrappers around the Rust core's clear_outputs / clear_cell_output RPCs.
-- Used by :JovianClearCache to drop cached output for a single cell or
-- the whole buffer; the core also persists the sidecar in the same call.
function M.clear_current_cell_cache()
    local id = Cell.get_current_cell_id(nil, false)
    if not id then
        return
    end
    local client = require("jovian.backend.core").client()
    if not client or not State.rust_session_id then
        return vim.notify("Jovian: kernel not started", vim.log.levels.WARN)
    end
    client:request("clear_cell_output", {
        session_id = State.rust_session_id,
        cell_id = id,
    }, function(err, _)
        vim.schedule(function()
            if err then
                vim.notify("Failed to clear cell cache: " .. err, vim.log.levels.ERROR)
                return
            end
            UI.set_cell_status(0, id, "idle", "")
            require("jovian.ui.output_render").invalidate(vim.api.nvim_buf_get_name(0))
            if Config.options.inline_outputs and Config.options.cell_frame then
                require("jovian.ui.cell_frame").schedule(0)
            end
            vim.notify("Cleared cache for cell " .. id, vim.log.levels.INFO)
        end)
    end)
end

function M.clear_all_cache()
    local client = require("jovian.backend.core").client()
    if not client or not State.rust_session_id then
        return vim.notify("Jovian: kernel not started", vim.log.levels.WARN)
    end
    client:request("clear_outputs", {
        session_id = State.rust_session_id,
    }, function(err, _)
        vim.schedule(function()
            if err then
                vim.notify("Failed to clear cache: " .. err, vim.log.levels.ERROR)
                return
            end
            UI.clear_status_extmarks(0)
            require("jovian.ui.output_render").invalidate(vim.api.nvim_buf_get_name(0))
            if Config.options.inline_outputs and Config.options.cell_frame then
                require("jovian.ui.cell_frame").schedule(0)
            end
            vim.notify("Cleared all cache", vim.log.levels.INFO)
        end)
    end)
end

return M
