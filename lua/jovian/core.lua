local M = {}
local State = require("jovian.state")
local Config = require("jovian.config")
local UI = require("jovian.ui")
local Utils = require("jovian.utils")

local function is_window_open()
    return State.win.output and vim.api.nvim_win_is_valid(State.win.output)
end

local function on_stdout(chan_id, data, name)
    if not data then return end
    
    -- バッファリング処理
    if not State.stdout_buffer then State.stdout_buffer = "" end
    
    -- データを結合
    -- data はテーブル (lines) なので、まずは結合する
    -- ただし、最後の要素が空文字列でない場合、それは「行の途中」を意味する可能性がある
    -- vim.fn.jobstart の仕様上、data の最後の要素は通常、次のチャンクへの続きか、改行後の空文字
    
    local chunk = table.concat(data, "\n")
    State.stdout_buffer = State.stdout_buffer .. chunk
    
    -- 改行で分割して処理
    local lines = vim.split(State.stdout_buffer, "\n")
    
    -- 最後の要素は「不完全な行」の可能性が高いので、バッファに戻す
    -- もし最後の要素が空文字なら、直前は改行で終わっていたということなので、
    -- バッファは空にしてよい。
    State.stdout_buffer = table.remove(lines)
    
    for _, line in ipairs(lines) do
        if line ~= "" then
            local ok, msg = pcall(vim.fn.json_decode, line)
            if ok and msg then
                vim.schedule(function()
                    if msg.type == "stream" then
                        UI.append_stream_text(msg.text, msg.stream)
                    elseif msg.type == "image_saved" then
                        UI.append_to_repl("[Image Created]: " .. vim.fn.fnamemodify(msg.path, ":t"), "Special")
                    elseif msg.type == "result_ready" then
                        UI.append_to_repl("-> Done: " .. msg.cell_id, "Comment")
                        State.current_preview_file = nil 
                        UI.open_markdown_preview(msg.file)
                        
                        local target_buf = State.cell_buf_map[msg.cell_id]
                        if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
                            local start_t = State.cell_start_time[msg.cell_id]
                            if start_t and (os.time() - start_t) >= Config.options.notify_threshold then
                                UI.send_notification("Calculation " .. msg.cell_id .. " Finished!")
                            end
                            vim.api.nvim_buf_clear_namespace(target_buf, State.diag_ns, 0, -1)
                            
                            -- ★ 修正: status フィールドもチェックする
                            if msg.error or msg.status == "error" then
                                UI.set_cell_status(target_buf, msg.cell_id, "error", "✘ Error")
                                
                                -- エラー情報があれば診断を表示
                                if msg.error then
                                    local start_line = State.cell_start_line[msg.cell_id] or 1
                                    local target_line = (start_line - 1) + (msg.error.line - 1)
                                    vim.diagnostic.set(State.diag_ns, target_buf, {{
                                        lnum = target_line, col = 0, message = msg.error.msg,
                                        severity = vim.diagnostic.severity.ERROR, source = "Jovian",
                                    }})
                                end
                            else
                                UI.set_cell_status(target_buf, msg.cell_id, "done", " Done")
                            end
                        end
                        State.cell_buf_map[msg.cell_id] = nil
                        State.cell_start_time[msg.cell_id] = nil
                        State.cell_start_line[msg.cell_id] = nil

                    elseif msg.type == "variable_list" then
                        UI.show_variables(msg.variables)
                    elseif msg.type == "dataframe_data" then
                        UI.show_dataframe(msg)
                    elseif msg.type == "profile_stats" then
                        UI.show_profile_stats(msg.text)
                    elseif msg.type == "inspection_data" then
                        UI.show_inspection(msg.data)
                    elseif msg.type == "peek_data" then
                        UI.show_peek(msg.data or msg)
                    elseif msg.type == "clipboard_data" then
                        vim.fn.setreg("+", msg.content)
                        vim.notify("Copied to system clipboard!", vim.log.levels.INFO)
                    elseif msg.type == "input_request" then
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
                end)
            end
        end
    end
end

function M.clean_stale_cache()
    if not State.job_id then return end
    local filename = vim.fn.expand("%:t")
    if filename == "" then return end
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local valid_ids = {}
    for _, line in ipairs(lines) do
        local id = line:match("id=\"([%w%-_]+)\"")
        if id then table.insert(valid_ids, id) end
    end
    local msg = vim.fn.json_encode({
        command = "clean_cache", filename = filename, valid_ids = valid_ids
    })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

function M.start_kernel()
    if State.job_id then return end
    
    -- Ensure IDs are unique before starting
    Utils.fix_duplicate_ids(0)
    
    local script_path = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h") .. "/lua/jovian/backend/main.py"
    local backend_dir = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h") .. "/lua/jovian/backend"
    local cmd = {}

    -- ★ 追加: SSH対応
    if Config.options.ssh_host then
        local host = Config.options.ssh_host
        local remote_python = Config.options.ssh_python
        
        -- ローカルの backend ディレクトリをリモートに転送
        -- 1. scp -r でディレクトリごと転送
        -- 2. sshで実行 (python3 -m jovian.backend.main ではなく、直接 main.py を指定)
        -- リモート側の配置先: /tmp/jovian_backend
        
        -- まずリモートの古いディレクトリを消す（念のため）
        vim.fn.system(string.format("ssh %s 'rm -rf /tmp/jovian_backend'", host))
        
        local scp_cmd = string.format("scp -r %s %s:/tmp/jovian_backend", backend_dir, host)
        vim.fn.system(scp_cmd) -- 同期実行で確実にファイルを送る
        
        cmd = {"ssh", host, remote_python, "-u", "/tmp/jovian_backend/main.py"}
        UI.append_to_repl("[Jovian] Connecting to remote: " .. host, "Special")
    else
        -- ローカル実行
        cmd = vim.split(Config.options.python_interpreter, " ")
        table.insert(cmd, script_path)
    end

    State.job_id = vim.fn.jobstart(cmd, {
        on_stdout = on_stdout, on_stderr = on_stdout, stdout_buffered = false,
        on_exit = function() State.job_id = nil end
    })
    UI.append_to_repl("[Jovian Kernel Started]")
    vim.defer_fn(function() M.clean_stale_cache() end, 500)
end

function M.restart_kernel()
    if State.job_id then vim.fn.jobstop(State.job_id); State.job_id = nil end
    UI.append_to_repl("[Kernel Restarting...]", "WarningMsg")
    M.start_kernel()
end

function M.send_payload(code, cell_id, filename)
    if not State.job_id then M.start_kernel() end
    local current_buf = vim.api.nvim_get_current_buf()
    
    State.cell_buf_map[cell_id] = current_buf
    State.cell_start_time[cell_id] = os.time()
    
    local lines = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)
    for i, line in ipairs(lines) do
        if line:find('id="' .. cell_id .. '"', 1, true) then
            State.cell_start_line[cell_id] = i + 1 
            break
        end
    end

    vim.diagnostic.reset(State.diag_ns, current_buf)
    vim.api.nvim_buf_clear_namespace(current_buf, State.diag_ns, 0, -1)
    
    UI.set_cell_status(current_buf, cell_id, "running", " Running...")
    
    UI.append_to_repl({"In [" .. cell_id .. "]:"}, "Type")
    local code_lines = vim.split(code, "\n")
    local indented = {}
    for _, l in ipairs(code_lines) do table.insert(indented, "    " .. l) end
    UI.append_to_repl(indented)
    UI.append_to_repl({""})

    local msg = vim.fn.json_encode({
        command = "execute", code = code, cell_id = cell_id, filename = filename
    })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

-- ★ 追加: プロファイリング
function M.profile_cell(code, cell_id)
    if not State.job_id then M.start_kernel() end
    local msg = vim.fn.json_encode({
        command = "profile", code = code, cell_id = cell_id
    })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

-- ★ 追加: コピー
function M.copy_variable(args)
    if not State.job_id then return vim.notify("Kernel not started", vim.log.levels.WARN) end
    local var_name = args.args
    if var_name == "" then var_name = vim.fn.expand("<cword>") end
    local msg = vim.fn.json_encode({ command = "copy_to_clipboard", name = var_name })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

function M.send_cell()
    if not is_window_open() then return vim.notify("Jovian windows are closed. Use :JovianOpen or :JovianToggle first.", vim.log.levels.WARN) end
    local src_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(src_win)
    local s, e = Utils.get_cell_range()
    UI.flash_range(s, e)
    local lines = vim.api.nvim_buf_get_lines(0, s-1, e, false)
    if #lines > 0 and lines[1]:match("^# %%%%") then table.remove(lines, 1) end
    local id = Utils.get_current_cell_id(s)
    local fn = vim.fn.expand("%:t")
    if fn == "" then fn = "untitled" end
    M.send_payload(table.concat(lines, "\n"), id, fn)
end

-- ★ 追加: 現在のセルをプロファイル
function M.run_profile_cell()
    if not is_window_open() then return vim.notify("Jovian windows are closed.", vim.log.levels.WARN) end
    local src_win = vim.api.nvim_get_current_win()
    local s, e = Utils.get_cell_range()
    local lines = vim.api.nvim_buf_get_lines(0, s-1, e, false)
    if #lines > 0 and lines[1]:match("^# %%%%") then table.remove(lines, 1) end
    local id = Utils.get_current_cell_id(s)
    M.profile_cell(table.concat(lines, "\n"), id)
end

function M.send_selection()
    if not is_window_open() then return vim.notify("Jovian windows are closed.", vim.log.levels.WARN) end
    local src_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(src_win)
    local _, csrow, _, _ = unpack(vim.fn.getpos("'<"))
    local _, cerow, _, _ = unpack(vim.fn.getpos("'>"))
    local lines = vim.api.nvim_buf_get_lines(0, csrow - 1, cerow, false)
    if #lines == 0 then return end
    UI.flash_range(csrow, cerow)
    local id = Utils.get_current_cell_id(csrow)
    local fn = vim.fn.expand("%:t")
    if fn == "" then fn = "untitled" end
    M.send_payload(table.concat(lines, "\n"), id, fn)
end

function M.run_and_next()
    M.send_cell()
    local _, e = Utils.get_cell_range()
    local total = vim.api.nvim_buf_line_count(0)
    if e < total then
        vim.api.nvim_win_set_cursor(0, {e + 1, 0})
        -- If the next line is a header, we are good. If it's a gap, we might want to skip empty lines?
        -- For now, simple jump is sufficient.
    end
end

function M.run_line()
    if not is_window_open() then return vim.notify("Jovian windows are closed.", vim.log.levels.WARN) end
    local src_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(src_win)
    
    local line = vim.api.nvim_get_current_line()
    if line == "" then return end
    
    UI.flash_range(vim.fn.line("."), vim.fn.line("."))
    
    -- For single line execution, we can use a generic ID or try to attribute it to the current cell?
    -- Attributing to current cell is better for context, but we don't want to mark the whole cell as "Running".
    -- Let's use "scratchpad" or a temp ID to avoid UI status conflict, OR just use send_payload but suppress status update?
    -- send_payload updates status. 
    -- Let's use a special ID suffix or just "line_exec".
    local id = "line_" .. os.time()
    local fn = vim.fn.expand("%:t")
    
    -- We use send_payload but maybe we want a lighter version?
    -- send_payload does: status update, append to repl, send json.
    -- It's fine to use it.
    M.send_payload(line, id, fn)
end

function M.run_all_cells()
    if not is_window_open() then return vim.notify("Jovian windows are closed.", vim.log.levels.WARN) end
    local src_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(src_win)
    if not State.job_id then M.start_kernel() end
    local fn = vim.fn.expand("%:t")
    if fn == "" then fn = "untitled" end
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local blk, bid, is_code = {}, "scratchpad", true
    for i, line in ipairs(lines) do
        if line:match("^# %%%%") then
            if #blk > 0 and is_code then M.send_payload(table.concat(blk, "\n"), bid, fn) end
            blk, bid = {}, Utils.ensure_cell_id(i, line)
            is_code = not line:lower():match("^# %%%%+%s*%[markdown%]")
        else
            if is_code then table.insert(blk, line) end
        end
    end
    if #blk > 0 and is_code then M.send_payload(table.concat(blk, "\n"), bid, fn) end
end

function M.view_dataframe(args)
    if not State.job_id then return vim.notify("Kernel not started", vim.log.levels.WARN) end
    local var_name = args.args
    if var_name == "" then var_name = vim.fn.expand("<cword>") end
    local msg = vim.fn.json_encode({ command = "view_dataframe", name = var_name })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

function M.show_variables()
    if not State.job_id then return vim.notify("Kernel not started", vim.log.levels.WARN) end
    local msg = vim.fn.json_encode({ command = "get_variables" })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

function M.check_cursor_cell()
    if not State.job_id then return end
    vim.schedule(function()
        local cell_id = Utils.get_current_cell_id()
        local filename = vim.fn.expand("%:t")
        if filename == "" then filename = "scratchpad" end
        local cache_dir = ".jovian_cache/" .. filename
        local rel_path = cache_dir .. "/" .. cell_id .. ".md"
        local md_path = vim.fn.fnamemodify(rel_path, ":p")
        if State.current_preview_file ~= md_path and vim.fn.filereadable(md_path) == 1 then
            UI.open_markdown_preview(md_path)
        end
    end)
end

function M.interrupt_kernel()
    if not State.job_id then return vim.notify("Kernel not running", vim.log.levels.WARN) end
    
    -- job_id から PID を取得して SIGINT (Ctrl+C相当) を送る
    local pid = vim.fn.jobpid(State.job_id)
    if pid then
        -- Unix系なら kill -2、Windowsなら別の方法が必要だが、今回はLinux/Mac前提
        vim.loop.kill(pid, 2) -- 2 = SIGINT
        UI.append_to_repl("[Kernel Interrupted!]", "WarningMsg")
        
        -- 実行中のステータスがあればErrorに変えておく
        for cell_id, buf in pairs(State.cell_buf_map) do
            UI.set_cell_status(buf, cell_id, "error", "⛔ Interrupted")
        end
        State.cell_buf_map = {} -- クリア
    else
        vim.notify("Could not get PID for kernel", vim.log.levels.ERROR)
    end
end

-- ★ 追加: セッション保存コマンド
function M.save_session(args)
    if not State.job_id then return end
    local filename = args.args
    if filename == "" then filename = "jovian_session.pkl" end -- デフォルト名
    
    local msg = vim.fn.json_encode({ command = "save_session", filename = filename })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

-- ★ 追加: セッション読み込みコマンド
function M.load_session(args)
    if not State.job_id then M.start_kernel() end
    local filename = args.args
    if filename == "" then filename = "jovian_session.pkl" end
    
    local msg = vim.fn.json_encode({ command = "load_session", filename = filename })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

-- ★ 追加: TUIプロット
function M.plot_tui(args)
    if not State.job_id then return end
    local var_name = args.args
    if var_name == "" then var_name = vim.fn.expand("<cword>") end

    if State.win.output and vim.api.nvim_win_is_valid(State.win.output) then
        -- ウィンドウ幅から行番号表示などの分（-5文字くらい）を引く
        width = vim.api.nvim_win_get_width(State.win.output) - 5
        if width < 20 then width = 20 end -- 最低幅保証
    end
    
    local msg = vim.fn.json_encode({ command = "plot_tui", name = var_name, width = width })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

-- コマンド関数を追加
function M.inspect_object(args)
    if not State.job_id then return vim.notify("Kernel not started", vim.log.levels.WARN) end
    local var_name = args.args
    if var_name == "" then var_name = vim.fn.expand("<cword>") end
    
    local msg = vim.fn.json_encode({ command = "inspect", name = var_name })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

function M.peek_symbol(args)
    if not State.job_id then return vim.notify("Kernel not started", vim.log.levels.WARN) end
    local var_name = args.args
    if var_name == "" then var_name = vim.fn.expand("<cword>") end
    
    local msg = vim.fn.json_encode({ command = "peek", name = var_name })
    vim.fn.chansend(State.job_id, msg .. "\n")
end

return M
