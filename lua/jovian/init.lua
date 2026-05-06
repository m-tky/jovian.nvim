local M = {}
local Config = require("jovian.config")
local Session = require("jovian.session")
local uv = vim.uv or vim.loop

function M.setup(opts)
    Config.setup(opts)
    require("jovian.diagnostics").setup()
    require("jovian.highlights").setup()

    -- require("jovian.diagnostics").setup()
    -- vim.opt.rtp:prepend(queries_path)

    -- Register custom predicate for magic command highlighting
    local _ = pcall(function()
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

    -- Fold (Buffer-local for Python)
    vim.api.nvim_create_autocmd("FileType", {
        pattern = "python",
        callback = function()
            vim.opt_local.foldmethod = "expr"
            vim.opt_local.foldexpr = "getline(v:lnum)=~'^#\\ %%'?'0':'1'"
            vim.opt_local.foldlevel = 99
        end,
    })

    -- Keymaps (Optional, user can define their own)
    -- Keymaps (Optional, user can define their own)

    vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
        pattern = "*",
        callback = function()
            if vim.bo.filetype == "python" then
                Session.check_cursor_cell()
            end
        end,
    })

    -- Add: Clean stale cache on save, close, and exit
    vim.api.nvim_create_autocmd({ "BufWritePost", "VimLeavePre", "BufUnload", "BufWinEnter" }, {
        pattern = "*.py",
        callback = function(ev)
            Session.clean_stale_cache(ev.buf)
        end,
    })

    -- Add: Debounced structure check on text change
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        pattern = "*.py",
        callback = function()
            Session.schedule_structure_check()
        end,
    })

    -- Add: Clean orphaned caches on open and close
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

    -- Add: Resize handling
    vim.api.nvim_create_autocmd("VimResized", {
        pattern = "*",
        callback = function()
            require("jovian.ui").resize_windows()
        end,
    })

    -- Add: Highlight cell separators
    vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType" }, {
        pattern = "*",
        callback = function()
            if vim.bo.filetype == "python" then
                local mode = Config.options.ui.cell_separator_highlight

                -- 1. Cleanup existing highlighting (Extmarks & Matchadd)

                -- Cleanup buffer-local autocmds (for extmark updates)
                if vim.b.jovian_highlight_augroup then
                    pcall(vim.api.nvim_del_augroup_by_id, vim.b.jovian_highlight_augroup)
                    vim.b.jovian_highlight_augroup = nil
                end

                -- Cleanup matchadd (window-local)
                if vim.w.jovian_cell_match_id then
                    pcall(vim.fn.matchdelete, vim.w.jovian_cell_match_id)
                    vim.w.jovian_cell_match_id = nil
                end

                -- Cleanup extmarks (buffer-local)
                local ns_id = vim.api.nvim_create_namespace("jovian_cells")
                vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

                -- 2. Apply new highlighting
                if mode == "text" then
                    vim.w.jovian_cell_match_id = vim.fn.matchadd("JovianCellMarker", "^# %%\\+.*")
                elseif mode == "line" then
                    local function update_extmarks()
                        local current_ns = vim.api.nvim_create_namespace("jovian_cells")
                        vim.api.nvim_buf_clear_namespace(0, current_ns, 0, -1)
                        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
                        for i, line in ipairs(lines) do
                            if line:match("^# %%") then
                                vim.api.nvim_buf_set_extmark(0, current_ns, i - 1, 0, {
                                    line_hl_group = "JovianCellMarker",
                                    priority = 200,
                                })
                            end
                        end
                    end

                    update_extmarks()

                    local augroup = vim.api.nvim_create_augroup(
                        "JovianCellHighlight_" .. vim.api.nvim_get_current_buf(),
                        { clear = true }
                    )
                    vim.b.jovian_highlight_augroup = augroup

                    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
                        group = augroup,
                        buffer = 0,
                        callback = update_extmarks,
                    })
                end
            end
        end,
    })

    -- Add: Inline Notebook Images handling
    local inline_render_timer = nil

    vim.api.nvim_create_autocmd({ "BufWritePre" }, {
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
                if inline_render_timer then
                    inline_render_timer:close()
                end
                inline_render_timer = uv.new_timer()
                inline_render_timer:start(
                    Config.options.inline_image_debounce or 500,
                    0,
                    vim.schedule_wrap(function()
                        require("jovian.inline_images").render_for_buffer(ev.buf)
                        if inline_render_timer then
                            pcall(function()
                                inline_render_timer:close()
                            end)
                            inline_render_timer = nil
                        end
                    end)
                )
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufUnload", {
        pattern = { "*.ipynb", "*.py" },
        callback = function(ev)
            require("jovian.inline_images").clear_for_buffer(ev.buf)
        end,
    })

    -- Add: Explicitly stop kernel on exit
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
