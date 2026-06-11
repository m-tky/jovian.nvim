local M = {}

M.job_id = nil
M.term_chan = nil

M.win = {
    output = nil,
    preview = nil,
    variables = nil, -- Add: Variables pane window
    pin = nil,
}

M.buf = {
    output = nil,
    variables = nil, -- Add: Variables pane buffer
    preview = nil,
    pin = nil,
}

-- Highlight Namespaces
M.hl_ns = vim.api.nvim_create_namespace("JovianCellHighlight")
M.status_ns = vim.api.nvim_create_namespace("JovianStatus")
M.diag_ns = vim.api.nvim_create_namespace("JovianDiagnostics")

-- Mappings
M.cell_buf_map = {} -- { cell_id: bufnr }
M.cell_start_time = {} -- { cell_id: timestamp }
M.cell_status_extmarks = {} -- { [cell_id] = { bufnr, id } }
M.cell_hashes = {} -- { [cell_id] = hash_string }

M.on_ready_callbacks = {} -- List of functions to call when kernel is ready

-- Active batch run (RunAll / RunAbove), or nil. Used by set_final to emit
-- progress notifications and a final summary. Cleared when every cell in
-- `pending` has reported back.
--   { total = N, done = K, started_at_ns = hrtime, pending = { [cell_id] = true } }
M.batch = nil

M.is_starting_kernel = false
M.running_cells = {} -- { [cell_id] = true }

M.virt_text_hidden_bufs = {} -- { [bufnr] = true }

-- Per-cell collapse-outputs state. When a cell_id is set, cell_frame
-- renders a single "├─ Out[N] (collapsed) ─┤" line instead of the full
-- output block. Buffer-keyed so two python files can have different
-- cells collapsed independently; entries are GC'd by the existing
-- BufDelete autocmd in init.lua.
M.collapsed_outputs = {} -- { [bufnr] = { [cell_id] = true } }
M.cell_status_cache = {} -- { [cell_id] = { status, msg, bufnr } }

M.dataframe_sessions = {} -- { [var_name] = { total, offset, limit, columns } }

-- Currently pinned cell — { src = absolute source path, cell_id = "abc123" }
-- or nil. Replaces the old `current_pin_file` which pointed at a per-cell
-- markdown file written by the now-removed Python bridge.
M.current_pin = nil

-- Rust core (jovian-core) state.
-- `job_id` is set to the sentinel string "rust" so `if State.job_id`
-- gates still pass; never call vim.fn.jobstop / jobpid on it.
M.rust_active = false
M.rust_session_id = nil

-- Tracks which cell the preview window is currently showing, so cell_event
-- handlers can decide whether to refresh it. nil when no cell is loaded
-- (either preview window is closed or we're on the legacy markdown path).
M.current_preview_cell_id = nil

-- Cell ids that have been executed in the CURRENT kernel session. Outputs
-- for cells not in this set were loaded from the sidecar JSON (a previous
-- nvim session's run) — the renderers append "(cached)" so the user
-- doesn't mistake them for fresh results. Cleared on kernel restart.
M.fresh_cells = {}

return M
