local M = {}
local State = require("jovian.state")

-- Submodules
local Windows = require("jovian.ui.windows")
local Layout = require("jovian.ui.layout")
local Renderers = require("jovian.ui.renderers")
local VirtualText = require("jovian.ui.virtual_text")
local Shared = require("jovian.ui.shared")

-- Re-export functions
M.open_windows = Layout.open_windows
M.close_windows = Windows.close_windows
M.toggle_windows = Layout.toggle_windows
M.resize_windows = Layout.resize_windows
M.toggle_variables_pane = Layout.toggle_variables_pane
M.update_variables_pane = Layout.update_variables_pane
M.open_output_window = Layout.open_output_window
M.toggle_output_window = Layout.toggle_output_window
M.pin_cell = Windows.pin_cell
M.unpin = Windows.unpin
M.toggle_pin_window = Layout.toggle_pin_window

M.render_variables_pane = Renderers.render_variables_pane
M.show_variables = Renderers.show_variables

M.show_dataframe = Renderers.show_dataframe

M.flash_range = VirtualText.flash_range
M.set_cell_status = VirtualText.set_cell_status
M.clean_invalid_extmarks = VirtualText.clean_invalid_extmarks
M.clear_status_extmarks = VirtualText.clear_status_extmarks
M.get_cell_status_extmark = VirtualText.get_cell_status_extmark
M.delete_status_extmark = VirtualText.delete_status_extmark
M.clear_diagnostics = VirtualText.clear_diagnostics
M.toggle_status_visibility = VirtualText.toggle_status_visibility

M.send_notification = Shared.send_notification
M.append_to_repl = Shared.append_to_repl
M.append_stream_text = Shared.append_stream_text

function M.clear_repl()
    if not (State.buf.output and vim.api.nvim_buf_is_valid(State.buf.output)) then
        return
    end
    local old_buf = State.buf.output

    -- Drop the old pair and free the "JovianOutput" name BEFORE rebuilding:
    -- otherwise ensure_output_buf → get_or_create_buf("JovianOutput") would
    -- find this very buffer by name, hand it back, and we'd then force-delete
    -- the buffer the window is showing (the old clear_repl bug, where the
    -- second invocation deleted the live console).
    State.buf.output = nil
    State.term_chan = nil
    pcall(vim.api.nvim_buf_set_name, old_buf, "")

    local new_buf = Windows.ensure_output_buf()
    if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
        vim.api.nvim_win_set_buf(State.win.output, new_buf)
        Windows.apply_window_options(State.win.output, { wrap = true })
    end

    if vim.api.nvim_buf_is_valid(old_buf) then
        vim.api.nvim_buf_delete(old_buf, { force = true })
    end

    M.append_to_repl("[Jovian Console Cleared]", "Special")
end

return M
