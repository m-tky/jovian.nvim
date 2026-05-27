local M = {}

M.defaults = {
    -- UI

    -- Visuals
    flash_highlight_group = "Visual",
    flash_duration = 300,
    float_border = "rounded", -- Border style for floating windows (single, double, rounded, solid, shadow)

    -- Python Environment
    python_interpreter = os.getenv("JOVIAN_PYTHON") or "python3",

    -- Behavior
    notify_threshold = 10,
    notify_mode = "all", -- "all", "error", "none"
    show_execution_time = true,
    plot_view_mode = "inline", -- "inline", "window"
    inline_image_debounce = 500, -- mmilliseconds to wait before rendering images after write
    inline_images = false, -- set to true to enable inline image rendering (requires image.nvim)
    folding = false, -- set to true to enable cell-based folding for Python files
    dataframe_page_size = 50,
    remote_cwd = ".",

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
    use_lua_native_shell = true,

    -- Route kernel I/O through the jovian-core Rust backend instead of
    -- kernel_bridge.py + libzmq FFI. Phase 1 milestone: spawn + execute
    -- + REPL streaming + cell status work. Variable inspection, DataFrame
    -- view, clipboard, image saving, SSH/tunnel kernels DO NOT YET work
    -- on this path — they still require the Python bridge. Leave this
    -- false unless you're actively testing the migration.
    use_rust_core = false,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
    M.configured_python = M.options.python_interpreter
end

return M
