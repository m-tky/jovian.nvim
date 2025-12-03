local M = {}
local UI = require("jovian.ui")
local Config = require("jovian.config")
local State = require("jovian.state")

function M.handle_stream(msg)
    UI.append_stream_text(msg.text, msg.stream)
end

function M.handle_image_saved(msg)
    UI.append_to_repl("[Image Created]: " .. vim.fn.fnamemodify(msg.path, ":t"), "Special")
end

function M.handle_result_ready(msg)
    UI.append_to_repl("-> Done: " .. msg.cell_id, "Comment")
    State.current_preview_file = nil
    
    -- Sync content to local cache if provided (SSH or Local)
    if msg.content_md then
        local cell_id = msg.cell_id
        local filename = vim.fn.expand("%:t")
        if filename == "" then filename = "scratchpad" end
        local file_dir = vim.fn.expand("%:p:h")
        local cache_dir = file_dir .. "/.jovian_cache/" .. filename
        
        -- Ensure cache dir exists
        vim.fn.mkdir(cache_dir, "p")
        
        -- Write Images
        if msg.images then
            for img_name, b64 in pairs(msg.images) do
                local img_path = cache_dir .. "/" .. img_name
                local write_script = string.format(
                    "import base64, sys; open('%s', 'wb').write(base64.b64decode(sys.stdin.read()))",
                    img_path
                )
                vim.fn.system({Config.options.python_interpreter, "-c", write_script}, b64)
            end
        end

        -- Write MD
        local md_path = cache_dir .. "/" .. cell_id .. ".md"
        local f = io.open(md_path, "w")
        if f then
            f:write(msg.content_md)
            f:close()
            msg.file = md_path -- Update to local path
        end
    end

    UI.open_markdown_preview(msg.file)
    UI.update_variables_pane()

    local target_buf = State.cell_buf_map[msg.cell_id]
    if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
        local start_t = State.cell_start_time[msg.cell_id]
        if start_t and (os.time() - start_t) >= Config.options.notify_threshold then
            UI.send_notification("Calculation " .. msg.cell_id .. " Finished!", "info")
        end
        vim.api.nvim_buf_clear_namespace(target_buf, State.diag_ns, 0, -1)

        if msg.error or msg.status == "error" then
            UI.send_notification("Error in cell " .. msg.cell_id, "error")
            UI.set_cell_status(target_buf, msg.cell_id, "error", Config.options.ui_symbols.error)

            -- Show diagnostics if error info exists
            if msg.error then
                local start_line = State.cell_start_line[msg.cell_id] or 1
                local err_line = msg.error.line or 1
                local target_line = (start_line - 1) + (err_line - 1)
                vim.diagnostic.set(State.diag_ns, target_buf, {
                    {
                        lnum = target_line,
                        col = 0,
                        message = msg.error.msg,
                        severity = vim.diagnostic.severity.ERROR,
                        source = "Jovian",
                    },
                })
            end
        else
            UI.set_cell_status(target_buf, msg.cell_id, "done", Config.options.ui_symbols.done)
        end
    end
    State.cell_buf_map[msg.cell_id] = nil
    State.cell_start_time[msg.cell_id] = nil
    State.cell_start_line[msg.cell_id] = nil
end

function M.handle_variable_list(msg)
    local force_float = State.vars_request_force_float
    State.vars_request_force_float = false
    UI.show_variables(msg.variables, force_float)
end

function M.handle_dataframe_data(msg)
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

function M.handle_clipboard_data(msg)
    vim.fn.setreg("+", msg.content)
    vim.notify("Copied to system clipboard!", vim.log.levels.INFO)
end

function M.handle_input_request(msg)
    UI.append_to_repl("[Input Requested]: " .. msg.prompt, "Special")
    vim.ui.input({ prompt = msg.prompt }, function(input)
        local value = input or ""
        UI.append_to_repl(value)
        if State.job_id then
            local reply = vim.fn.json_encode({ command = "input_reply", value = value })
            vim.fn.chansend(State.job_id, reply .. "\n")
        end
    end)
end

return M
