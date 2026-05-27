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
    preview = nil,
}

-- Highlight Namespaces
M.hl_ns = vim.api.nvim_create_namespace("JovianCellHighlight")
M.status_ns = vim.api.nvim_create_namespace("JovianStatus")
M.diag_ns = vim.api.nvim_create_namespace("JovianDiagnostics")

M.current_preview_file = nil

-- Mappings
M.msg_id_cell_map = {} -- { msg_id: cell_id }
M.cell_buf_map = {} -- { cell_id: bufnr }
M.cell_start_time = {} -- { cell_id: timestamp }
M.cell_status_extmarks = {} -- { [cell_id] = extmark_id }
M.cell_hashes = {} -- { [cell_id] = hash_string }
M.cell_start_line = {} -- { cell_id: line_num }

M.on_ready_callbacks = {} -- List of functions to call when kernel is ready

M.batch_execution = nil -- { total = int, current = int, start_time = timestamp }

M.inline_images = {} -- { [bufnr] = { images = {}, mtime = 0 } }
M.is_starting_kernel = false
M.running_cells = {} -- { [cell_id] = true }
M.stdout_buffer = ""
M.stderr_buffer = ""

M.virt_text_hidden_bufs = {} -- { [bufnr] = true }
M.cell_status_cache = {} -- { [cell_id] = { status, msg, bufnr } }

M.dataframe_sessions = {} -- { [var_name] = { total, offset, limit, columns } }

M.tunnel_job_id = nil
M.tunnel_host = nil
M.remote_kernel_pid = nil
M.has_warned_native_unavailable = false

M.last_completion_results = nil
M.last_stream_type = nil
M.last_stream_tail = nil
M.vars_request_force_float = false
M.current_pin_file = nil

-- Native ZMQ / Lua Messenger state
M.is_discovering_zmq = false
M.lua_shell_socket = nil
M.lua_zmq_key = nil
M.lua_messenger_stop = nil

-- Rust core (jovian-core) state. Only populated when use_rust_core=true.
-- `job_id` is set to the sentinel string "rust" so legacy `if State.job_id`
-- checks still gate execution, but vim.fn.jobstop / jobpid must NOT be
-- called on it — branch on `rust_active` first.
M.rust_active = false
M.rust_session_id = nil

return M
