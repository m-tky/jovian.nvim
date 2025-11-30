local M = {}

M.defaults = {
	-- UI
	preview_width_percent = 35,
	repl_height_percent = 30,
    vars_pane_width_percent = 20, -- Width of the variables pane (percent of editor width)
    toggle_var = true, -- Automatically toggle variables pane with UI

	-- Visuals
	flash_highlight_group = "Visual",
	flash_duration = 300,
	float_border = "rounded", -- Border style for floating windows (single, double, rounded, solid, shadow)

	-- Python Environment
	python_interpreter = "python3",

	-- Behavior
	notify_threshold = 10,
    
    -- UI Symbols
    ui_symbols = {
        running = " Running...",
        done = " Done",
        error = "✘ Error",
        interrupted = " Interrupted",
    },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
