local M = {}
local Config = require("jovian.config")
local Core = require("jovian.core")
local Session = require("jovian.session")

function M.setup(opts)
	Config.setup(opts)
	require("jovian.diagnostics").setup()
	require("jovian.highlights").setup()

	-- TreeSitter Queries
    local Queries = require("jovian.treesitter_queries")
    
	if vim.treesitter.query.set then
        local md_opt = Config.options.treesitter.markdown_injection
        if md_opt then
            local query = (type(md_opt) == "string") and md_opt or Queries.python_injections
            vim.treesitter.query.set("python", "injections", query)
        end
        
        local magic_opt = Config.options.treesitter.magic_command_highlight
        if magic_opt then
            local query = (type(magic_opt) == "string") and magic_opt or Queries.python_highlights
            vim.treesitter.query.set("python", "highlights", query)
        end
	end
		-- vim.opt.rtp:prepend(queries_path)

		-- Register custom predicate for magic command highlighting
		local ok, err = pcall(function()
			vim.treesitter.query.add_predicate("same-line?", function(match, pattern, bufnr, predicate)
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

				local r1, _, _, _ = node1:range()
				local r2, _, _, _ = node2:range()
				return r1 == r2
			end, true) -- force=true to overwrite if exists
		end)

	-- Register Commands
	require("jovian.commands").setup()

	-- Fold
	vim.opt.foldmethod = "expr"
	vim.opt.foldexpr = "getline(v:lnum)=~'^#\\ %%'?'0':'1'"
	vim.opt.foldlevel = 99

	-- Keymaps (Optional, user can define their own)
	if Config.options.keymaps then
		-- Example keymaps (user can define their own in config)
		-- vim.keymap.set("n", "<leader>jn", "<cmd>JovianNextCell<CR>", { desc = "Jovian: Next Cell" })
		-- vim.keymap.set("n", "<leader>jp", "<cmd>JovianPrevCell<CR>", { desc = "Jovian: Previous Cell" })
		-- vim.keymap.set("n", "<leader>jr", "<cmd>JovianRun<CR>", { desc = "Jovian: Run Cell" })
		-- vim.keymap.set("v", "<leader>jr", "<cmd>JovianSendSelection<CR>", { desc = "Jovian: Run Selection" })
		-- vim.keymap.set("n", "<leader>jR", "<cmd>JovianRunAll<CR>", { desc = "Jovian: Run All Cells" })
		-- vim.keymap.set("n", "<leader>ja", "<cmd>JovianNewCellAbove<CR>", { desc = "Jovian: New Cell Above" })
		-- vim.keymap.set("n", "<leader>jb", "<cmd>JovianNewCellBelow<CR>", { desc = "Jovian: New Cell Below" })
		-- vim.keymap.set("n", "<leader>jd", "<cmd>JovianDeleteCell<CR>", { desc = "Jovian: Delete Cell" })
		-- vim.keymap.set("n", "<leader>jm", "<cmd>JovianMergeBelow<CR>", { desc = "Jovian: Merge Cell Below" })
		-- vim.keymap.set("n", "<leader>js", "<cmd>JovianSplitCell<CR>", { desc = "Jovian: Split Cell" })
		-- vim.keymap.set("n", "<leader>jU", "<cmd>JovianMoveCellUp<CR>", { desc = "Jovian: Move Cell Up" })
		-- vim.keymap.set("n", "<leader>jD", "<cmd>JovianMoveCellDown<CR>", { desc = "Jovian: Move Cell Down" })
		-- vim.keymap.set("n", "<leader>jo", "<cmd>JovianOpen<CR>", { desc = "Jovian: Open UI" })
		-- vim.keymap.set("n", "<leader>jt", "<cmd>JovianToggle<CR>", { desc = "Jovian: Toggle UI" })
		-- vim.keymap.set("n", "<leader>jc", "<cmd>JovianClear<CR>", { desc = "Jovian: Clear REPL" })
		-- vim.keymap.set("n", "<leader>jv", "<cmd>JovianVars<CR>", { desc = "Jovian: Show Variables" })
		-- vim.keymap.set("n", "<leader>jV", "<cmd>JovianView<CR>", { desc = "Jovian: View Dataframe" })
		-- vim.keymap.set("n", "<leader>jC", "<cmd>JovianCopy<CR>", { desc = "Jovian: Copy Variable" })
		-- vim.keymap.set("n", "<leader>jP", "<cmd>JovianProfile<CR>", { desc = "Jovian: Profile Cell" })
		-- vim.keymap.set("n", "<leader>ji", "<cmd>JovianInterrupt<CR>", { desc = "Jovian: Interrupt Kernel" })
		-- vim.keymap.set("n", "<leader>jS", "<cmd>JovianStart<CR>", { desc = "Jovian: Start Kernel" })
		-- vim.keymap.set("n", "<leader>jX", "<cmd>JovianRestart<CR>", { desc = "Jovian: Restart Kernel" })
		-- vim.keymap.set("n", "<leader>j?", "<cmd>JovianDoc<CR>", { desc = "Jovian: Inspect Object" })
		-- vim.keymap.set("n", "<leader>j.", "<cmd>JovianPeek<CR>", { desc = "Jovian: Peek Symbol" })
		-- vim.keymap.set("n", "<leader>jn", "<cmd>JovianRunAndNext<CR>", { desc = "Jovian: Run and Next" })
		-- vim.keymap.set("n", "<leader>jl", "<cmd>JovianRunLine<CR>", { desc = "Jovian: Run Line" })
		-- vim.keymap.set("n", "<leader>ja", "<cmd>JovianRunAbove<CR>", { desc = "Jovian: Run Above" })
	end

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
end

return M
