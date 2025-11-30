local M = {}

M.defaults = {
	-- UI
	preview_width_percent = 35,
	preview_width_percent = 35,
	repl_height_percent = 30,
    vars_pane_width_percent = 30, -- Width of the variables pane (percent of editor width)
    toggle_var = false, -- Automatically toggle variables pane with UI

	-- Visuals
	flash_highlight_group = "Visual",
	flash_duration = 300,
	float_border = "rounded", -- Border style for floating windows (single, double, rounded, solid, shadow)

	-- Python Environment
	python_interpreter = "python3",

	-- Behavior
	notify_threshold = 10,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
