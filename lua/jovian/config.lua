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

    -- Render each `# %%` cell as a bordered card via extmarks:
    --   ┌─ [3] Code ────┐
    --   │ print("hi")   │
    --   └───────────────┘
    -- Opt-in because it shifts the right edge of cell lines and overlays
    -- the `# %%` header line — both meaningful visual changes a long-time
    -- user shouldn't get without asking.
    cell_frame = false,

    -- Conceal markdown punctuation (**bold**, *italic*, `code`, `#`
    -- heading markers) inside `# %% [markdown]` cells and replace them
    -- with styled virt_text. Independent of cell_frame; either can be
    -- enabled on its own. Off by default since concealing source bytes
    -- can surprise users mid-edit (we re-show the source while the
    -- cursor is on that line, but the rest of the cell stays styled).
    markdown_cell_style = false,

    -- Render the kernel's outputs (stdout/stderr/text result/error
    -- traceback) below each cell as virt_lines, jupynvim-style. Reads
    -- from the nbformat-style JSON sidecar that jovian-core (the Rust
    -- backend) writes at `.jovian_cache/<filename>/outputs.json`.
    -- Requires `cell_frame = true` (the outputs are rendered inside
    -- the cell's bottom virt_lines block). Image/HTML support comes
    -- in Phase 3; for now only text-mime outputs render.
    inline_outputs = false,

    -- Per-level highlight overrides for Phase 2 visuals. Each value can be
    -- either a string (treated as a link target — typically a colorscheme's
    -- own heading group like "@markup.heading.1.markdown") or a table of
    -- nvim_set_hl attrs (e.g. { fg = "#ff0000", bold = true }).
    -- Leave a key nil to let jovian pick from a fallback chain:
    --   @markup.heading.<n>.markdown  →  @markup.heading.<n>
    --   →  markdownH<n>  →  Title/Function/Type/Constant/Statement/Identifier
    -- That way users on tokyonight, catppuccin, gruvbox, habamax etc. all
    -- get their theme's heading colors for free, while still being able to
    -- override any group surgically.
    highlights = {
        -- Cell card outline. Two groups so code vs markdown cells are
        -- visually distinct at a glance. Defaults follow the active
        -- colorscheme by linking to whichever group from a fallback chain
        -- exists:
        --   code     → Function / @function / Identifier / DiagnosticInfo / ...
        --   markdown → WarningMsg / DiagnosticWarn / @number / Number / Constant / ...
        -- Override via string (link) or table (attrs) per group.
        cell_border_code = nil,
        cell_border_markdown = nil,
        md_h1 = nil,
        md_h2 = nil,
        md_h3 = nil,
        md_h4 = nil,
        md_h5 = nil,
        md_h6 = nil,
        md_bold = nil,
        md_em = nil,
        md_code = nil,          -- defaults to link String
        md_bullet = nil,        -- defaults to link Special
        md_quote = nil,         -- defaults to link Comment
        md_table_divider = nil, -- defaults to link Special
        md_table_header = nil,  -- defaults to bold = true
        -- Inline cell output rendering. JovianOutDivider styles the
        -- `├─ Out[N] ─┤` separator; JovianOutStdout / JovianOutStderr
        -- / JovianOutResult / JovianOutError tint the body lines.
        out_divider = nil, -- defaults to link the cell border color
        out_stdout = nil,  -- defaults to link Normal
        out_stderr = nil,  -- defaults to link WarningMsg
        out_result = nil,  -- defaults to link Identifier
        out_error = nil,   -- defaults to link ErrorMsg
    },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
    M.configured_python = M.options.python_interpreter
end

return M
