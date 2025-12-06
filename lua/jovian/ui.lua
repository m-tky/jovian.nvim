local M = {}
local Config = require("jovian.config")
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
M.open_markdown_preview = Windows.open_markdown_preview
M.toggle_variables_pane = Layout.toggle_variables_pane
M.update_variables_pane = Layout.update_variables_pane
M.pin_cell = Windows.pin_cell
M.unpin = Windows.unpin
M.toggle_pin_window = Layout.toggle_pin_window

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
        local old_buf = State.buf.output
        
        -- Create new buffer first
        local new_buf = Windows.get_or_create_buf("JovianConsole")
        State.buf.output = new_buf
        
        -- If window is open, switch to new buffer immediately
        if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
             vim.api.nvim_win_set_buf(State.win.output, new_buf)
             Windows.apply_window_options(State.win.output, { wrap = true })
        end
        
        -- Now safe to delete old buffer
		vim.api.nvim_buf_delete(old_buf, { force = true })
        -- State.term_chan is updated by get_or_create_buf
        
        M.append_to_repl("[Jovian Console Cleared]", "Special")
	end
end

return M
