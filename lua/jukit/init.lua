local M = {}
local job_id = nil
local output_buf = nil
local output_win = nil
local preview_buf = nil
local preview_win = nil

-- STDOUTバッファリング
local stdout_buffer = {}

-- === ID管理 ===

local function generate_id()
    -- ランダムなIDを生成
    math.randomseed(os.time())
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    local id = ""
    for i = 1, 8 do
        local rand = math.random(#chars)
        id = id .. string.sub(chars, rand, rand)
    end
    return id
end

local function get_cell_id(line_num)
    local line
    if line_num then
        local lines = vim.api.nvim_buf_get_lines(0, line_num - 1, line_num, false)
        if #lines > 0 then line = lines[1] else line = "" end
    else
        line = vim.api.nvim_get_current_line()
    end
    
    -- Jupytext形式: # %% id="foo"
    local id = line:match("# %%%% id=\"([%w%-_]+)\"")
    
    if not id then
        id = generate_id()
        -- マーカー行が含まれている場合のみIDを追記
        if line:match("^# %%%%") then
             -- 既存のマーカーの後ろに id="..." を追加
             -- 既に他のオプションがある場合は考慮していない簡易実装
             local new_line = line .. " id=\"" .. id .. "\""
             if line_num then
                 vim.api.nvim_buf_set_lines(0, line_num - 1, line_num, false, {new_line})
             else
                 vim.api.nvim_set_current_line(new_line)
             end
        end
    end
    return id
end

-- === ハンドラ ===

local function on_stdout(chan_id, data, name)
    if not data then return end

    if #stdout_buffer > 0 then
        data[1] = table.concat(stdout_buffer) .. data[1]
        stdout_buffer = {}
    end

    if #data > 0 then
        stdout_buffer = { table.remove(data, #data) }
    end

    for _, line in ipairs(data) do
        if line ~= "" then
            local ok, msg = pcall(vim.fn.json_decode, line)
            
            if ok and msg then
                -- ★ここを修正: テキストファイル通知を受け取る
                if msg.type == "text_file" then
                    vim.schedule(function()
                        if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
                            -- ファイルを読み込む
                            local f = io.open(msg.payload, "r")
                            if f then
                                local content = f:read("*a")
                                f:close()
                                
                                -- 内容があれば表示
                                if content and content ~= "" then
                                    local lines = vim.split(content, "\n")
                                    if lines[#lines] == "" then table.remove(lines, #lines) end
                                    
                                    -- Previewバッファに追記
                                    vim.api.nvim_buf_set_lines(preview_buf, -1, -1, false, lines)
                                    
                                    -- スクロール
                                    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
                                        local count = vim.api.nvim_buf_line_count(preview_buf)
                                        vim.api.nvim_win_set_cursor(preview_win, {count, 0})
                                    end
                                end
                            end
                        end
                    end)

                -- ★ここを修正: 画像ファイル通知を受け取る
                elseif msg.type == "image_file" then
                    vim.schedule(function()
                        if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
                             -- 画像表示用のダミー行を追加
                             vim.api.nvim_buf_set_lines(preview_buf, -1, -1, false, {""})
                             local last_line = vim.api.nvim_buf_line_count(preview_buf)

                             local ok_img, image = pcall(require, "image")
                             if ok_img then
                                 local img = image.from_file(msg.payload, {
                                     buffer = preview_buf,
                                     window = preview_win,
                                     x = 0,
                                     y = 0,
                                     width = 50, -- サイズはお好みで
                                     height = 20,
                                     with_virtual_padding = true,
                                     inline = true,
                                     range_start = {last_line - 1, 0} -- 最後の行に画像をアンカーする
                                 })
                                 if img then img:render() end
                             else
                                 -- image.nvimがない場合
                                 vim.api.nvim_buf_set_lines(preview_buf, -1, -1, false, {"[Image]: " .. msg.payload})
                             end
                             
                             -- スクロール
                             if preview_win and vim.api.nvim_win_is_valid(preview_win) then
                                 local count = vim.api.nvim_buf_line_count(preview_buf)
                                 vim.api.nvim_win_set_cursor(preview_win, {count, 0})
                             end
                        end
                    end)

                -- エラー表示
                elseif msg.type == "error" then
                    vim.schedule(function()
                         -- エラーもPreviewに出す？それともOutput？ここではPreviewに出してみる
                         if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
                             local lines = vim.split(msg.payload, "\n")
                             table.insert(lines, 1, "--- ERROR ---")
                             vim.api.nvim_buf_set_lines(preview_buf, -1, -1, false, lines)
                         end
                    end)
                end
            end
        end
    end
end

-- === ウィンドウ管理 ===

function M.init_windows()
    local code_win = vim.api.nvim_get_current_win()
    
    -- 1. Preview Window (右側)
    if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
        vim.cmd("vsplit")
        vim.cmd("wincmd L")
        preview_win = vim.api.nvim_get_current_win()
        preview_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_option(preview_buf, "buftype", "nofile")
        vim.api.nvim_buf_set_name(preview_buf, "JukitPreview")
        vim.api.nvim_win_set_buf(preview_win, preview_buf)
    end
    
    vim.api.nvim_set_current_win(code_win)
    
    -- 2. Output/REPL Window (下側) - ここはログやステータス用にする
    if not (output_win and vim.api.nvim_win_is_valid(output_win)) then
        vim.cmd("split")
        vim.cmd("wincmd j")
        vim.api.nvim_win_set_height(0, 10) -- 高さを少し小さく
        output_win = vim.api.nvim_get_current_win()
        output_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_option(output_buf, "buftype", "nofile")
        vim.api.nvim_buf_set_name(output_buf, "JukitConsole")
        vim.api.nvim_win_set_buf(output_win, output_buf)
        vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, {"[Jukit Kernel Console Ready]"})
    end
    
    vim.api.nvim_set_current_win(code_win)
end

-- === カーネル起動 ===

function M.start_kernel()
    if job_id then return end
    
    local source = debug.getinfo(1).source:sub(2)
    local root = vim.fn.fnamemodify(source, ":h:h:h")
    local script_path = root .. "/lua/jukit/kernel.py"

    job_id = vim.fn.jobstart({"python3", script_path}, {
        on_stdout = on_stdout,
        on_stderr = on_stdout,
        stdout_buffered = false, 
    })
    
    if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
         vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, {"Kernel Job ID: " .. job_id})
    end
end

-- === コード送信 ===

function M.send_cell()
    -- ウィンドウがなければ作る
    if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
        M.init_windows()
    end
    if not job_id then M.start_kernel() end
    
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    
    -- セル範囲特定
    local start_line = cursor_line
    local end_line = cursor_line
    local total_lines = vim.api.nvim_buf_line_count(0)
    
    while start_line > 1 do
        local l = vim.api.nvim_buf_get_lines(0, start_line - 1, start_line, false)[1]
        if l:match("^# %%%%") then break end
        start_line = start_line - 1
    end
    
    while end_line < total_lines do
        local l = vim.api.nvim_buf_get_lines(0, end_line, end_line + 1, false)[1]
        if l:match("^# %%%%") then break end
        end_line = end_line + 1
    end
    
    local cell_lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
    if #cell_lines > 0 and cell_lines[1]:match("^# %%%%") then
        table.remove(cell_lines, 1)
    end
    
    local cell_id = get_cell_id(start_line)
    local code = table.concat(cell_lines, "\n")
    
    -- ファイル名取得
    local filename = vim.fn.expand("%:t")
    if filename == "" then filename = "untitled" end

    -- Previewへ区切り線を表示
    if preview_buf then
        vim.api.nvim_buf_set_lines(preview_buf, -1, -1, false, {
            "", 
            "--- Executing: " .. filename .. " [" .. cell_id .. "] ---"
        })
    end

    local msg = vim.fn.json_encode({
        command = "execute",
        code = code,
        cell_id = cell_id,
        filename = filename
    })
    
    vim.fn.chansend(job_id, msg .. "\n")
end

function M.setup(opts)
    vim.api.nvim_create_user_command("JukitStart", M.start_kernel, {})
    vim.api.nvim_create_user_command("JukitRun", M.send_cell, {})
    vim.api.nvim_create_user_command("JukitInit", M.init_windows, {})
end

return M
