local M = {}

M.defaults = {
	-- UI

	-- Visuals
	flash_highlight_group = "Visual",
	flash_duration = 300,
	float_border = "rounded", -- Border style for floating windows (single, double, rounded, solid, shadow)

	-- Python Environment
	python_interpreter = "python3",

	-- Behavior
	notify_threshold = 10,
	notify_mode = "all", -- "all", "error", "none"
	show_execution_time = true,
	plot_view_mode = "inline", -- "inline", "window"

	ui = {
		-- cell_separator_highlight:
		-- "line"  : Highlight the entire line (default).
		-- "text"  : Highlight only the text.
		-- "none"  : No highlight.
		cell_separator_highlight = "text",
		-- winblend = 0,
		layouts = {
			{
				elements = {
					{ id = "preview", size = 0.70 },
					{ id = "pin", size = 0.30 },
				},
				-- position: "left", "right", "top", "bottom"
				position = "left",
				size = 0.35,
			},
			{
				elements = {
					{ id = "output", size = 0.55 },
					{ id = "variables", size = 0.45 },
				},
				position = "bottom",
				size = 0.25,
			},
		},
	},

	-- UI Symbols
	ui_symbols = {
		running = " Running...",
		done = " Done",
		error = " Error",
		interrupted = " Interrupted",
		stale = " Stale",
	},

	-- Magic Commands
	suppress_magic_command_errors = true,

	-- TreeSitter
	treesitter = {
		-- Can be true (default), false (disable), or a string (custom query)
		markdown_injection = true,
		magic_command_highlight = true,
	},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
	M.configured_python = M.options.python_interpreter
end

return M
