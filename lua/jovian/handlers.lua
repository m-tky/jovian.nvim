local M = {}
local UI = require("jovian.ui")
local Config = require("jovian.config")
local State = require("jovian.state")
local Session = require("jovian.session")

function M.handle_stream(msg)
    -- If Native Lua messenger is active, it handles streams directly with lower latency.
    -- We skip the Python bridge's stream messages to avoid duplicates.
    if State.lua_shell_socket then
        return
    end
    UI.append_stream_text(msg.text, msg.stream)
end

function M.handle_image_saved(msg)
    UI.append_to_repl("[Image Created]: " .. vim.fn.fnamemodify(msg.path, ":t"), "Special")
end

function M.handle_debug(msg)
    UI.append_to_repl("[Debug]: " .. msg.msg, "Comment")
end

function M.handle_kernel_log(msg)
    local hl = msg.stream == "stderr" and "ErrorMsg" or "Comment"
    UI.append_to_repl("[Kernel " .. msg.stream .. "]: " .. msg.msg, hl)
end

function M.handle_ready(_msg)
    State.is_starting_kernel = false
    -- Execute all registered callbacks
    for _, callback in ipairs(State.on_ready_callbacks) do
        callback()
    end
    State.on_ready_callbacks = {}

    -- Initial setup
    Session.clean_stale_cache()
    if State.win.variables and vim.api.nvim_win_is_valid(State.win.variables) then
        require("jovian.core").show_variables()
    end

    if Config.options.plot_view_mode and type(State.job_id) == "number" then
        local init_msg = vim.json.encode({ command = "set_plot_mode", mode = Config.options.plot_view_mode })
        vim.api.nvim_chan_send(State.job_id, init_msg .. "\n")
    end
end

function M.handle_execution_started(msg)
    if msg.msg_id then
        State.msg_id_cell_map[msg.msg_id] = msg.cell_id
    end
    UI.append_to_repl({ "In [" .. msg.cell_id .. "]:" }, "Type")
    local code_lines = vim.split(msg.code, "\n")
    local indented = {}
    for _, l in ipairs(code_lines) do
        table.insert(indented, "    " .. l)
    end
    UI.append_to_repl(indented)
    UI.append_to_repl({ "" })
end

function M.handle_result_ready(msg)
    State.current_preview_file = nil

    Session.save_execution_result(msg, function()
        UI.open_markdown_preview(msg.file)
        UI.update_variables_pane()

        local target_buf = State.cell_buf_map[msg.cell_id]
        if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
            local should_notify = false
            local notify_msg = "Calculation " .. msg.cell_id .. " Finished!"

            if State.batch_execution then
                State.batch_execution.current = State.batch_execution.current + 1
                if State.batch_execution.current >= State.batch_execution.total then
                    local batch_dur = os.time() - State.batch_execution.start_time
                    should_notify = true
                    notify_msg = string.format("Jovian: %s finished (%ds)", State.batch_execution.name or "Batch", batch_dur)
                    State.batch_execution = nil
                end
            else
                local start_t = State.cell_start_time[msg.cell_id]
                if start_t and (os.time() - start_t) >= Config.options.notify_threshold then
                    should_notify = true
                end
            end

            if should_notify then
                UI.send_notification(notify_msg, "info")
            end
            vim.api.nvim_buf_clear_namespace(target_buf, State.diag_ns, 0, -1)

            local timestamp = ""
            if Config.options.show_execution_time then
                timestamp = " (" .. os.date("%H:%M:%S") .. ")"
            end

            if msg.error or msg.status == "error" then
                UI.send_notification("Error in cell " .. msg.cell_id, "error")
                UI.set_cell_status(target_buf, msg.cell_id, "error", Config.options.ui_symbols.error .. timestamp)

                -- Show diagnostics if error info exists
                if msg.error then
                    require("jovian.core").show_error_diagnostics(target_buf, msg.cell_id, msg.error)
                end

                -- If in a batch and this is an error, clear the batch state and only the PENDING spinners
                if State.batch_execution then
                    State.batch_execution = nil
                    -- Clear ALL cells that are currently in 'running' state
                    for id, _ in pairs(State.running_cells) do
                        if id ~= msg.cell_id then
                            local bufnr = State.cell_buf_map[id]
                            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                                UI.set_cell_status(bufnr, id, "idle", "")
                            end
                        end
                    end
                    -- Clear the running_cells table
                    State.running_cells = {}
                end
                -- Note: UI.set_cell_status for this error was already called at line 97
                State.running_cells[msg.cell_id] = nil
            else
                UI.set_cell_status(target_buf, msg.cell_id, "done", Config.options.ui_symbols.done .. timestamp)
                State.running_cells[msg.cell_id] = nil
            end
        end
        State.cell_buf_map[msg.cell_id] = nil
        State.cell_start_time[msg.cell_id] = nil
        State.cell_start_line[msg.cell_id] = nil
    end)
end

function M.handle_variable_list(msg)
    UI.show_variables(msg, State.vars_request_force_float)
    State.vars_request_force_float = false
end

function M.handle_dataframe_data(msg)
    State.dataframe_sessions[msg.name] = {
        total = msg.total_rows,
        offset = msg.offset,
        limit = msg.limit,
        columns = msg.columns,
    }
    UI.show_dataframe(msg)
end

function M.handle_profile_stats(msg)
    UI.show_profile_stats(msg.text)
end

function M.handle_inspection_data(msg)
    UI.show_inspection(msg.data)
end

function M.handle_peek_data(msg)
    UI.show_peek(msg.data or msg)
end

function M.handle_complete_data(msg)
    State.last_completion_results = msg.matches
end

function M.handle_clipboard_data(msg)
    vim.fn.setreg("+", msg.content)
    vim.notify("Copied to system clipboard!", vim.log.levels.INFO)
    -- Debug for tests
    if vim.g.jovian_test_mode then
        vim.g.jovian_last_clipboard = msg.content
    end
end

function M.handle_input_request(msg)
    UI.append_to_repl("[Input Requested]: " .. msg.prompt, "Special")
    vim.ui.input({ prompt = msg.prompt }, function(input)
        local value = input or ""
        UI.append_to_repl(value)
        if State.job_id then
            local reply = vim.json.encode({ command = "input_reply", value = value })
            vim.fn.chansend(State.job_id, reply .. "\n")
        end
    end)
end

function M.handle_batch_aborted(msg)
    UI.send_notification(msg.msg, "warn")

    -- Clear batch state
    State.batch_execution = nil

    -- Clear all 'running' status indicators
    for id, _ in pairs(State.running_cells) do
        local bufnr = State.cell_buf_map[id]
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            UI.set_cell_status(bufnr, id, "idle", "")
        end
    end

    -- Final cleanup of local state
    State.running_cells = {}
    State.cell_start_time = {}
    State.cell_buf_map = {}
end

return M
