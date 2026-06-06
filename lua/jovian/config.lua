local M = {}

M.defaults = {
    -- UI

    -- Visuals
    flash_highlight_group = "Visual",
    flash_duration = 300,
    float_border = "rounded", -- Border style for floating windows (single, double, rounded, solid, shadow)

    -- Python Environment
    --
    -- When unset (the default), jovian auto-resolves a usable python at
    -- setup time: it probes PATH `python3`/`python`, $VIRTUAL_ENV,
    -- $CONDA_PREFIX, ./.venv, ./venv (in that order) and picks the first
    -- one that can `import ipykernel`. Set this explicitly to opt out and
    -- pin a specific interpreter — the value is then used verbatim, even
    -- if ipykernel is missing (a health warning is surfaced instead).
    --
    -- Absolute paths bypass Jupyter kernelspec lookup: jovian-core launches
    -- `<python> -m ipykernel_launcher` directly, so no `kernel.json` needs
    -- to exist on the system. Bare names like "python3" still go through
    -- kernelspec discovery on the Rust side as a last resort.
    --
    -- JOVIAN_PYTHON env var, if set, wins over the auto-resolver — this
    -- matches what the bundled flake's devShell hook exports.
    python_interpreter = nil,

    -- Pin a specific Jupyter kernelspec by name (e.g. "python3", "ir").
    -- Forwarded to jovian-core's start_kernel as `kernel_name`. Mutually
    -- exclusive with python_interpreter (which builds a synthetic spec on
    -- the fly); when both are set, python_interpreter wins. Most users
    -- leave this nil — the picker (`:JovianPickPython`) sets it when a
    -- registered kernelspec is chosen.
    kernel_name = nil,

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

    -- Install a small default keymap on `FileType python` buffers. Off by
    -- default — every Neovim user has opinions about <leader> bindings,
    -- so we never claim them unless asked. When true, the bindings
    -- documented in README's "Recommended Keybindings" section are
    -- installed buffer-locally for python files only. Pass `false` (or
    -- omit) and bind whichever subset you want yourself.
    default_keymaps = false,

    -- Render each `# %%` cell as a bordered card via extmarks:
    --   ┌─ [3] Code ────┐   (cell_frame_style = "square", default)
    --   │ print("hi")   │
    --   └───────────────┘
    --
    --   ╭─ [3] Code ────╮   (cell_frame_style = "rounded")
    --   │ print("hi")   │
    --   ╰───────────────╯
    --
    -- Opt-in because it shifts the right edge of cell lines and overlays
    -- the `# %%` header line — both meaningful visual changes a long-time
    -- user shouldn't get without asking.
    cell_frame = false,

    -- Corner style for the cell card frame. Naming follows Neovim's
    -- `nvim_open_win` border vocabulary ("rounded", not "round") so users
    -- who already set `float_border = "rounded"` see the same key here.
    --   "square"  : ┌┐└┘  (default)
    --   "rounded" : ╭╮╰╯
    cell_frame_style = "square",

    -- Reserve N columns of empty space to the right of the cell frame's
    -- right border (the `│`). Useful when a scrollbar plugin like
    -- nvim-scrollbar / nvim-scrollview also wants to draw in the rightmost
    -- column — at 0 (default) the cell frame and the scrollbar fight for
    -- the same column; setting this to 1 (or 2) pulls the right border
    -- inward by that many columns so the scrollbar has space to live.
    -- Affects the frame width: the top/bottom dashes and any inline
    -- content (output blocks, tables, images, math) shrink to match.
    cell_frame_right_pad = 0,

    -- Extmark priority of the cell-frame side bars (the left/right `│`).
    -- This decides who wins when an indent-guide plugin draws a vertical
    -- line in the same column as the frame's left bar:
    --   • Keep it low (default) to let the indent / scope guide win — the
    --     cell is still bounded by the top/bottom borders, header, and the
    --     right bar.
    --   • Raise it (e.g. 4096, above indent-blankline's scope priority of
    --     1024) to draw the frame on top of the indent guide instead.
    -- Safe at any value: the bars are inline / right_align virt_text, so
    -- they never overlay (hide) the source code — priority only orders them
    -- against other virtual text.
    cell_frame_priority = 100,

    -- Conceal markdown punctuation (**bold**, *italic*, `code`, `#`
    -- heading markers) inside `# %% [markdown]` cells and replace them
    -- with styled virt_text. Independent of cell_frame; either can be
    -- enabled on its own. Off by default since concealing source bytes
    -- can surprise users mid-edit (we re-show the source while the
    -- cursor is on that line, but the rest of the cell stays styled).
    markdown_cell_style = false,

    -- Border style for rendered markdown tables, à la render-markdown.nvim:
    --   "round"  : ╭─┬─╮ rounded corners (default)
    --   "none"   : ┌─┬─┐ square corners
    --   "heavy"  : ┏━┳━┓ thick lines
    --   "double" : ╔═╦═╗ double lines
    -- The delimiter row marks explicit `:--` / `:-:` / `--:` alignment with a
    -- contrasting indicator, exactly like render-markdown.
    table_border = "round",

    -- LaTeX math in markdown cells (render-markdown.nvim style): `$…$` inline
    -- and `$$…$$` blocks are converted to a Unicode approximation. The
    -- converter is built in (Greek, operators, super/subscripts, \frac, \sqrt,
    -- … — no external dependency). For fuller coverage, set `converter` to an
    -- external command (render-markdown's "latex2text" / "utftex", or a list
    -- tried in order); the built-in is the fallback. Only renders when
    -- markdown_cell_style is on.
    -- position (render-markdown semantics): where a block formula is drawn
    -- relative to its `$$…$$`:
    --   "center" : single-line blocks (and inline `$…$`) are concealed and the
    --              Unicode is overlaid in place; multi-line blocks fall back to
    --              "above" (center needs a single line).
    --   "above" / "below" : the Unicode is drawn as a virtual line above/below
    --              the block and the raw LaTeX source stays visible.
    math = {
        enabled = true,
        position = "center",
        converter = nil,
    },

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
        md_math = nil, -- inline/block math (defaults to link Special)
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

-- True iff the user explicitly set `python_interpreter` in setup(). Used to
-- skip the auto-resolver and respect the user's pin verbatim (matches the
-- "そのまま使う" answer to the explicit-override question in the design).
M.python_interpreter_explicit = false

-- Resolved absolute python path picked by the auto-resolver, or whatever
-- the user pinned. Filled in by `setup()` and mirrored back to
-- `options.python_interpreter` so the rest of the plugin (rust_kernel.lua,
-- session.lua, health.lua, hosts.lua) can read a single field.
M.configured_python = nil

function M.setup(opts)
    opts = opts or {}
    M.python_interpreter_explicit = opts.python_interpreter ~= nil
    M.options = vim.tbl_deep_extend("force", M.defaults, opts)

    local resolved
    if M.options.python_interpreter and M.options.python_interpreter ~= "" then
        -- Explicit setup() value wins, no probing. Health surfaces a warning
        -- if ipykernel is missing instead of overriding the user's choice.
        resolved = M.options.python_interpreter
    else
        local env = os.getenv("JOVIAN_PYTHON")
        if env and env ~= "" then
            resolved = env
        else
            local Python = require("jovian.python")
            resolved = Python.resolve() or "python3"
        end
    end
    M.options.python_interpreter = resolved
    M.configured_python = resolved
end

return M
