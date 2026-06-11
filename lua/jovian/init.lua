local M = {}
local Config = require("jovian.config")
local Session = require("jovian.session")

function M.setup(opts)
    -- Flag for plugin/jovian.lua's auto-setup safety net: if the user
    -- called setup() themselves, the VimEnter fallback no-ops.
    vim.g.jovian_setup_done = 1
    -- One augroup for every autocmd registered here, cleared on each
    -- setup() so a second call (or a plugin re-source) replaces the
    -- handlers instead of stacking a duplicate of each one.
    local group = vim.api.nvim_create_augroup("Jovian", { clear = true })
    Config.setup(opts)
    -- Restore the persisted active host AFTER Config.setup() rebuilt the
    -- options table — the old module-load restore raced that and got wiped.
    pcall(function()
        require("jovian.hosts").restore_active()
    end)
    require("jovian.diagnostics").setup()
    require("jovian.highlights").setup()

    -- Register custom predicate for magic command highlighting
    pcall(function()
        vim.treesitter.query.add_predicate("same-line?", function(match, _pattern, _bufnr, predicate)
            local node1 = match[predicate[2]]
            local node2 = match[predicate[3]]
            if not node1 or not node2 then
                return false
            end

            if type(node1) == "table" then
                node1 = node1[1]
            end
            if type(node2) == "table" then
                node2 = node2[1]
            end

            local r1 = node1:start()
            local r2 = node2:start()
            return r1 == r2
        end, true) -- force=true to overwrite if exists
    end)

    -- Register Commands
    require("jovian.commands").setup()

    -- Completion
    M.Complete = require("jovian.complete")

    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "python",
        callback = function(ev)
            M.Complete.setup_omnifunc()
            if Config.options.folding then
                vim.opt_local.foldmethod = "expr"
                vim.opt_local.foldexpr = "getline(v:lnum)=~'^# %%'?'>1':'1'"
                vim.opt_local.foldlevel = 99
            end
            if Config.options.default_keymaps then
                require("jovian.keymaps").apply(ev.buf)
            end
        end,
    })
    -- Preview refresh on cursor move. We used to gate on CursorHold but
    -- that waits for `updatetime` (4s default) to fire — far too sluggish
    -- when stepping between cells. CursorMoved fires on every movement;
    -- a 150ms uv-timer debounce keeps the rate sane and check_cursor_cell
    -- itself early-returns when the cursor stays within the same cell.
    -- One reusable debounce timer driven by stop()/start(). Creating a new
    -- timer per event (and closing the previous one) raced: a scheduled
    -- callback from a superseded timer could close the timer that replaced
    -- it, dropping the pending refresh.
    local _cursor_timer = (vim.uv or vim.loop).new_timer()
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        pattern = "*",
        callback = function()
            if vim.bo.filetype ~= "python" then
                return
            end
            _cursor_timer:stop()
            _cursor_timer:start(
                150,
                0,
                vim.schedule_wrap(function()
                    Session.check_cursor_cell()
                end)
            )
        end,
    })
    vim.api.nvim_create_autocmd({ "BufWritePost", "VimLeavePre", "BufUnload", "BufWinEnter" }, {
        group = group,
        pattern = "*.py",
        callback = function(ev)
            Session.clean_stale_cache(ev.buf)
        end,
    })

    -- Drop per-cell state attached to a buffer that's being wiped or
    -- deleted, so cell ids from a previous incarnation don't linger in
    -- global maps and confuse future lookups for a recycled bufnr.
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = group,
        pattern = "*",
        callback = function(ev)
            local State = require("jovian.state")
            local bufnr = ev.buf
            for cell_id, b in pairs(State.cell_buf_map) do
                if b == bufnr then
                    State.cell_buf_map[cell_id] = nil
                    State.cell_status_extmarks[cell_id] = nil
                    State.cell_start_time[cell_id] = nil
                    State.cell_status_cache[cell_id] = nil
                    State.running_cells[cell_id] = nil
                end
            end
            -- cell_status_cache entries can outlive cell_buf_map (the latter
            -- is cleared on cell completion). Sweep them too.
            for cell_id, cached in pairs(State.cell_status_cache) do
                if cached and cached.bufnr == bufnr then
                    State.cell_status_cache[cell_id] = nil
                end
            end
            -- Drop the buffer's collapsed-outputs map. Toggled cells in a
            -- newly-opened buffer with the same bufnr would otherwise
            -- inherit the old buffer's collapse state.
            State.collapsed_outputs[bufnr] = nil
        end,
    })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = group,
        pattern = "*.py",
        callback = function()
            Session.schedule_structure_check()
        end,
    })
    vim.api.nvim_create_autocmd({ "VimEnter", "VimLeavePre" }, {
        group = group,
        pattern = "*",
        callback = function()
            -- Run for the current working directory
            Session.clean_orphaned_caches(vim.fn.getcwd())

            -- Also run for the directory of the current file if it's different
            local buf_name = vim.api.nvim_buf_get_name(0)
            if buf_name ~= "" then
                local buf_dir = vim.fn.fnamemodify(buf_name, ":p:h")
                if buf_dir ~= vim.fn.getcwd() then
                    Session.clean_orphaned_caches(buf_dir)
                end
            end
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
        group = group,
        pattern = "*",
        callback = function()
            require("jovian.ui").resize_windows()
        end,
    })

    local function setup_cell_highlighting()
        if vim.bo.filetype ~= "python" then
            return
        end

        local mode = Config.options.ui.cell_separator_highlight
        local ns_id = vim.api.nvim_create_namespace("jovian_cells")

        if vim.b.jovian_highlight_augroup then
            pcall(vim.api.nvim_del_augroup_by_id, vim.b.jovian_highlight_augroup)
            vim.b.jovian_highlight_augroup = nil
        end
        if vim.w.jovian_cell_match_id then
            pcall(vim.fn.matchdelete, vim.w.jovian_cell_match_id)
            vim.w.jovian_cell_match_id = nil
        end
        vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

        if mode == "text" then
            vim.w.jovian_cell_match_id = vim.fn.matchadd("JovianCellMarker", "^# %%\\+.*")
        elseif mode == "line" then
            local function update_extmarks()
                vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
                for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
                    if line:match("^# %%") then
                        vim.api.nvim_buf_set_extmark(0, ns_id, i - 1, 0, {
                            line_hl_group = "JovianCellMarker",
                            priority = 200,
                        })
                    end
                end
            end
            update_extmarks()
            local augroup =
                vim.api.nvim_create_augroup("JovianCellHighlight_" .. vim.api.nvim_get_current_buf(), { clear = true })
            vim.b.jovian_highlight_augroup = augroup
            vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
                group = augroup,
                buffer = 0,
                callback = update_extmarks,
            })
        end
    end

    vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType" }, {
        group = group,
        pattern = "*",
        callback = setup_cell_highlighting,
    })

    -- Phase 2: cell card frame + markdown styling. Autocmds are always
    -- registered (so :JovianToggleCellFrame at runtime works seamlessly);
    -- the render functions early-return when their flag is off.
    do
        local CellFrame = require("jovian.ui.cell_frame")
        local MarkdownCell = require("jovian.ui.markdown_cell")

        local function refresh_buffer(bufnr, winid)
            if vim.bo[bufnr].filetype ~= "python" then
                return
            end
            CellFrame.schedule(bufnr, winid)
            MarkdownCell.schedule(bufnr)
        end

        -- conceallevel/concealcursor are WINDOW options. We bump conceallevel
        -- to 2 (concealed chars vanish entirely) only when at least one of
        -- the Phase 2 features is on, and only if the user hasn't set a
        -- higher value themselves. concealcursor stays empty so the cursor's
        -- line reveals raw source for editing — without that, the user
        -- can't see the `# ` prefix or `**bold**` markers they're typing.
        local function apply_window_options(winid)
            if not vim.api.nvim_win_is_valid(winid) then
                return
            end
            if not (Config.options.cell_frame or Config.options.markdown_cell_style) then
                return
            end
            local buf = vim.api.nvim_win_get_buf(winid)
            if vim.bo[buf].filetype ~= "python" then
                return
            end
            local cur = vim.api.nvim_get_option_value("conceallevel", { win = winid })
            if cur < 2 then
                vim.api.nvim_set_option_value("conceallevel", 2, { win = winid })
            end
            vim.api.nvim_set_option_value("concealcursor", "", { win = winid })
        end

        vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType", "WinEnter" }, {
            group = group,
            pattern = "*",
            callback = function(ev)
                if vim.bo[ev.buf].filetype == "python" then
                    local win = vim.api.nvim_get_current_win()
                    apply_window_options(win)
                    refresh_buffer(ev.buf, win)
                end
            end,
        })

        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            group = group,
            pattern = "*.py",
            callback = function(ev)
                refresh_buffer(ev.buf)
            end,
        })

        -- Anti-conceal: re-render markdown styling when the cursor changes
        -- LINE so the rendered overlay on the line being edited is dropped
        -- (raw source shown) and restored when the cursor leaves — matching
        -- render-markdown.nvim. Gated on a line change so horizontal motion
        -- within a line is free; the render is itself debounced.
        --
        -- Same hook re-applies the cell_frame wrap-chrome winhighlight so
        -- the `showbreak = "│ "` color follows the cursor between code and
        -- markdown cells (showbreak is window-global, so we update it on
        -- cell-boundary crossings).
        local _md_line = {}
        vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
            group = group,
            pattern = "*.py",
            callback = function(ev)
                local line = vim.api.nvim_win_get_cursor(0)[1]
                if _md_line[ev.buf] == line then
                    return
                end
                _md_line[ev.buf] = line
                if Config.options.cell_frame then
                    CellFrame.refresh_wrap_chrome(ev.buf, vim.api.nvim_get_current_win())
                end
                if Config.options.markdown_cell_style then
                    MarkdownCell.schedule(ev.buf)
                end
            end,
        })

        -- WinResized / VimResized: re-render every python buffer in every
        -- visible window. The original code only refreshed the current
        -- buffer, which left borders stale when the resize affected a
        -- python window that wasn't focused (e.g. resizing the preview
        -- pane changed the source pane's width too).
        vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
            group = group,
            pattern = "*",
            callback = function()
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    local buf = vim.api.nvim_win_get_buf(win)
                    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "python" then
                        refresh_buffer(buf, win)
                    end
                end
                -- Re-render the preview too so its image rescales to the
                -- new geometry. Find a python window to know which file's
                -- sidecar to read from.
                local State = require("jovian.state")
                if
                    State.current_preview_cell_id
                    and State.buf.preview
                    and vim.api.nvim_buf_is_valid(State.buf.preview)
                then
                    for _, w in ipairs(vim.api.nvim_list_wins()) do
                        local b = vim.api.nvim_win_get_buf(w)
                        if vim.bo[b].filetype == "python" then
                            local src = vim.api.nvim_buf_get_name(b)
                            if src ~= "" then
                                require("jovian.ui.output_render").render_to_buffer(
                                    State.buf.preview,
                                    State.win.preview,
                                    src,
                                    State.current_preview_cell_id
                                )
                                break
                            end
                        end
                    end
                end
            end,
        })

        -- ColorScheme: re-resolve our highlight groups so they follow the
        -- newly-loaded theme's heading/markdown colors. Each renderer
        -- re-runs set_default_hl() on its next call; we just need to
        -- force a redraw so the re-resolution happens immediately.
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = group,
            pattern = "*",
            callback = function()
                for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "python" then
                        local wins = vim.fn.win_findbuf(buf)
                        refresh_buffer(buf, wins[1])
                    end
                end
            end,
        })
    end

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        pattern = "*",
        callback = function()
            pcall(function()
                require("jovian.core").stop_kernel()
            end)
        end,
    })
end

return M
