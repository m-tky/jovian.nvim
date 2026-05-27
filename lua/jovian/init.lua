local M = {}
local Config = require("jovian.config")
local Session = require("jovian.session")
local uv = vim.uv or vim.loop

function M.setup(opts)
    Config.setup(opts)
    require("jovian.diagnostics").setup()
    require("jovian.highlights").setup()

    -- Start ZMQ discovery in background for zero-config Native mode
    if Config.options.use_lua_native_shell then
        local State = require("jovian.state")
        State.is_discovering_zmq = true
        require("jovian.backend.zmq").discover_bundled(Config.options.python_interpreter, function(_, _)
            State.is_discovering_zmq = false
        end)
    end

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
        pattern = "python",
        callback = function()
            M.Complete.setup_omnifunc()
            if Config.options.folding then
                vim.opt_local.foldmethod = "expr"
                vim.opt_local.foldexpr = "getline(v:lnum)=~'^# %%'?'>1':'1'"
                vim.opt_local.foldlevel = 99
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
        pattern = "*",
        callback = function()
            if vim.bo.filetype == "python" then
                Session.check_cursor_cell()
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "BufWritePost", "VimLeavePre", "BufUnload", "BufWinEnter" }, {
        pattern = "*.py",
        callback = function(ev)
            Session.clean_stale_cache(ev.buf)
        end,
    })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        pattern = "*.py",
        callback = function()
            Session.schedule_structure_check()
        end,
    })
    vim.api.nvim_create_autocmd({ "VimEnter", "VimLeavePre" }, {
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
            if vim.bo[bufnr].filetype ~= "python" then return end
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
            if not vim.api.nvim_win_is_valid(winid) then return end
            if not (Config.options.cell_frame or Config.options.markdown_cell_style) then
                return
            end
            local buf = vim.api.nvim_win_get_buf(winid)
            if vim.bo[buf].filetype ~= "python" then return end
            local cur = vim.api.nvim_get_option_value("conceallevel", { win = winid })
            if cur < 2 then
                vim.api.nvim_set_option_value("conceallevel", 2, { win = winid })
            end
            vim.api.nvim_set_option_value("concealcursor", "", { win = winid })
        end

        vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType", "WinEnter" }, {
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
            pattern = "*.py",
            callback = function(ev)
                refresh_buffer(ev.buf)
            end,
        })

        -- WinResized: re-render so the top/bottom border dashes match the
        -- new text-area width and the right_align bars sit at the new edge.
        vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
            pattern = "*",
            callback = function()
                local buf = vim.api.nvim_get_current_buf()
                if vim.bo[buf].filetype == "python" then
                    refresh_buffer(buf, vim.api.nvim_get_current_win())
                end
            end,
        })

        -- ColorScheme: re-resolve our highlight groups so they follow the
        -- newly-loaded theme's heading/markdown colors. Each renderer
        -- re-runs set_default_hl() on its next call; we just need to
        -- force a redraw so the re-resolution happens immediately.
        vim.api.nvim_create_autocmd("ColorScheme", {
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

    if Config.options.inline_images then
        local inline_render_timer = nil
        local function schedule_inline_render(bufnr)
            if inline_render_timer then
                inline_render_timer:close()
            end
            inline_render_timer = uv.new_timer()
            inline_render_timer:start(
                Config.options.inline_image_debounce or 500,
                0,
                vim.schedule_wrap(function()
                    require("jovian.inline_images").render_for_buffer(bufnr)
                    if inline_render_timer then
                        pcall(inline_render_timer.close, inline_render_timer)
                        inline_render_timer = nil
                    end
                end)
            )
        end

        vim.api.nvim_create_autocmd("BufWritePre", {
            pattern = { "*.ipynb", "*.py" },
            callback = function(ev)
                if vim.bo[ev.buf].filetype == "python" then
                    require("jovian.inline_images").restore_buffer_for_save(ev.buf)
                end
            end,
        })

        vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWritePost" }, {
            pattern = { "*.ipynb", "*.py" },
            callback = function(ev)
                if vim.bo[ev.buf].filetype == "python" then
                    schedule_inline_render(ev.buf)
                end
            end,
        })

        vim.api.nvim_create_autocmd("BufUnload", {
            pattern = { "*.ipynb", "*.py" },
            callback = function(ev)
                require("jovian.inline_images").clear_for_buffer(ev.buf)
            end,
        })
    end
    vim.api.nvim_create_autocmd("VimLeavePre", {
        pattern = "*",
        callback = function()
            pcall(function()
                require("jovian.core").stop_kernel()
            end)
        end,
    })
end

return M
