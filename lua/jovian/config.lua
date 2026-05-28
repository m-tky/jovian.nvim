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
    folding = false, -- set to true to enable cell-based folding for Python files
    dataframe_page_size = 50,
    remote_cwd = ".",

    -- Output (REPL) window visibility:
    --   "ondemand" : not shown by default — toggle with :JovianToggleOutput.
    --                Output still accumulates in the background buffer so the
    --                full log is there when you open it. (default)
    --   "always"   : opened automatically as a bottom split with the panels.
    --   "off"      : never shown (output is dropped, not buffered).
    -- With inline_outputs on, each cell shows its own result, so the REPL
    -- window is mostly useful for cross-cell history and live `\r` streams
    -- (tqdm) — hence on-demand by default to save screen space.
    output_window = "ondemand",

    ui = {
        -- cell_separator_highlight:
        -- "line"  : Highlight the entire line (default).
        -- "text"  : Highlight only the text.
        -- "none"  : No highlight.
        cell_separator_highlight = "text",
        -- winblend = 0,
        -- Default persistent panels. Output + Variables are intentionally
        -- absent: Variables shows as a float via :JovianVars (or a pane via
        -- :JovianToggleVars), Output is governed by `output_window` above.
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
    -- Kept as a recognised key for old setups; the legacy Python-bridge
    -- and libzmq FFI paths it gated were removed in Phase 5. Setting it
    -- has no effect.
    use_rust_core = true,

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
    -- traceback, PNG/GIF/JPEG images) below each cell as virt_lines,
    -- jupynvim-style. Reads from the nbformat-style JSON sidecar that
    -- jovian-core (the Rust backend) writes at
    -- `.jovian_cache/<filename>/outputs.json`. Requires
    -- `cell_frame = true`. Images are transmitted via the Kitty graphics
    -- protocol (Unicode placeholder mode) and only render on terminals
    -- that support it (Kitty, Ghostty 1.3+, recent WezTerm). On other
    -- terminals the placeholder unicode glyphs are visible but harmless.
    inline_outputs = false,

    -- Max rows of text output rendered inline below a cell. Longer output
    -- is elided (first lines + "… N more …" + last lines) so a cell that
    -- prints thousands of lines doesn't shove the buffer down — the full
    -- text is still in the preview pane / Output window, which scroll.
    -- Cells that produce an image aren't capped (plots are bounded by
    -- image_rows and rarely accompany huge text).
    inline_output_max_lines = 20,

    -- Placement dimensions for images in the inline output block, in
    -- terminal cells. Tweak to match your typical plot aspect ratio.
    image_rows = 14,
    image_cols = 56,

    -- Preview-pane image sizing. The renderer parses the PNG/GIF
    -- header to read each image's actual pixel dimensions and scales
    -- the placement so neither axis is clipped (letterbox-free) AND
    -- the placement is never larger than the image's native footprint
    -- in cells (small pictures aren't blown up to fill the pane).
    --
    -- preview_cell_pixel_height: pixel height of one terminal cell.
    -- 16 covers most 10–11pt fonts on hidpi-ish setups. Set this
    -- explicitly if `kitty +kitten icat` shows images at a noticeably
    -- different size than jovian renders them.
    preview_cell_pixel_height = 16,
    -- preview_cell_pixel_aspect: width / height of one cell. 0.5 is
    -- the typical monospace ratio (cells are about twice as tall as
    -- wide). Together with preview_cell_pixel_height this gives the
    -- conversion from image pixels to terminal cells.
    preview_cell_pixel_aspect = 0.5,
    -- Upper bounds. nil = "fill the preview window's text area".
    preview_image_max_cols = nil,
    preview_image_max_rows = nil,

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
        md_code = nil, -- defaults to link String
        md_bullet = nil, -- defaults to link Special
        md_quote = nil, -- defaults to link Comment
        md_table_divider = nil, -- defaults to link Special
        md_table_header = nil, -- defaults to bold = true
        -- Inline cell output rendering. JovianOutDivider styles the
        -- `├─ Out[N] ─┤` separator; JovianOutStdout / JovianOutStderr
        -- / JovianOutResult / JovianOutError tint the body lines.
        out_divider = nil, -- defaults to link the cell border color
        out_stdout = nil, -- defaults to link Normal
        out_stderr = nil, -- defaults to link WarningMsg
        out_result = nil, -- defaults to link Identifier
        out_error = nil, -- defaults to link ErrorMsg
    },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
    M.configured_python = M.options.python_interpreter
end

return M
