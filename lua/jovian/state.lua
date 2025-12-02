local M = {}

M.job_id = nil
M.term_chan = nil

M.win = {
    output = nil,
    preview = nil,
    variables = nil, -- Add: Variables pane window
}

M.buf = {
    output = nil,
    variables = nil, -- Add: Variables pane buffer
    preview = nil
}

-- Highlight Namespaces
M.hl_ns = vim.api.nvim_create_namespace("JovianCellHighlight")
M.status_ns = vim.api.nvim_create_namespace("JovianStatus")
M.diag_ns = vim.api.nvim_create_namespace("JovianDiagnostics")

M.current_preview_file = nil

-- Mappings
M.cell_buf_map = {} -- { cell_id: bufnr }
M.cell_start_time = {} -- { cell_id: timestamp }
M.cell_status_extmarks = {} -- { [cell_id] = extmark_id }
M.cell_hashes = {} -- { [cell_id] = hash_string }
M.cell_start_line = {} -- { cell_id: line_num }

return M
