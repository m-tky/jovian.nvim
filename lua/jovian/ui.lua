local M = {}
local Config = require("jovian.config")
local State = require("jovian.state")

-- Submodules
local Windows = require("jovian.ui.windows")
local Renderers = require("jovian.ui.renderers")
local VirtualText = require("jovian.ui.virtual_text")
local Shared = require("jovian.ui.shared")

-- Re-export functions
M.open_windows = Windows.open_windows
M.close_windows = Windows.close_windows
M.toggle_windows = Windows.toggle_windows
M.open_markdown_preview = Windows.open_markdown_preview
M.toggle_variables_pane = Windows.toggle_variables_pane
M.update_variables_pane = Windows.update_variables_pane
M.pin_cell = Windows.pin_cell
M.unpin = Windows.unpin
M.toggle_pin_window = Windows.toggle_pin_window

M.render_variables_pane = Renderers.render_variables_pane
M.show_variables = Renderers.show_variables
M.show_profile_stats = Renderers.show_profile_stats
M.show_dataframe = Renderers.show_dataframe
M.show_inspection = Renderers.show_inspection
M.show_peek = Renderers.show_peek

M.flash_range = VirtualText.flash_range
M.set_cell_status = VirtualText.set_cell_status
M.clean_invalid_extmarks = VirtualText.clean_invalid_extmarks
M.clear_status_extmarks = VirtualText.clear_status_extmarks
M.get_cell_status_extmark = VirtualText.get_cell_status_extmark
M.delete_status_extmark = VirtualText.delete_status_extmark
M.clear_diagnostics = VirtualText.clear_diagnostics

M.send_notification = Shared.send_notification
M.append_to_repl = Shared.append_to_repl
M.append_stream_text = Shared.append_stream_text

function M.clear_repl()
	if State.buf.output and vim.api.nvim_buf_is_valid(State.buf.output) then
		-- Terminal buffer cannot be cleared with set_lines,
		-- so recreate the buffer (forcefully)
		vim.api.nvim_buf_delete(State.buf.output, { force = true })
		State.buf.output = nil
		State.term_chan = nil

		-- Redraw (if window is open)
        -- We need to call open_windows to recreate the buffer and attach it
        -- But open_windows checks if window is valid.
        -- If window is valid, we just need to set the new buffer.
        
        if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
             local new_buf = Windows.get_or_create_buf("JovianConsole")
             State.buf.output = new_buf
             vim.api.nvim_win_set_buf(State.win.output, new_buf)
             M.append_to_repl("[Jovian Console Cleared]", "Special")
        end
	end
end

return M
