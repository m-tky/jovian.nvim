-- Build virt_lines for a cell's outputs.
--
-- Reads the nbformat-style sidecar JSON that jovian-core writes at
--   <file_dir>/.jovian_cache/<filename>/outputs.json
-- and turns the cell's outputs[] array into a list of chunked virt_lines
-- the cell_frame renderer can embed below the cell.
--
-- Phase 4 scope: stream (stdout/stderr), text/plain in execute_result and
-- display_data, and error tracebacks. Images and HTML are left for the
-- jupynvim-style Kitty graphics work in Phase 3.

local M = {}

local Config = require("jovian.config")

local HL = {
    Divider = "JovianOutDivider",
    Stdout = "JovianOutStdout",
    Stderr = "JovianOutStderr",
    Result = "JovianOutResult",
    Error = "JovianOutError",
}

local function apply_hl(target, user_val, fallback)
    local val = user_val
    if val == nil then val = fallback end
    if val == nil then return end
    if type(val) == "string" then
        vim.api.nvim_set_hl(0, target, { link = val, force = true })
    elseif type(val) == "table" then
        local attrs = vim.deepcopy(val)
        attrs.force = true
        vim.api.nvim_set_hl(0, target, attrs)
    end
end

function M.setup_hl(border_hl)
    -- border_hl is whichever cell_frame chose for the current cell type;
    -- the divider line inherits it so the `├` and `┤` corners align
    -- visually with the cell box.
    local user_hl = (Config.options.highlights) or {}
    apply_hl(HL.Divider, user_hl.out_divider, border_hl or "Comment")
    apply_hl(HL.Stdout, user_hl.out_stdout, "Normal")
    apply_hl(HL.Stderr, user_hl.out_stderr, "WarningMsg")
    apply_hl(HL.Result, user_hl.out_result, "Identifier")
    apply_hl(HL.Error, user_hl.out_error, "ErrorMsg")
end

-- nbformat allows text fields to be either a string or an array of strings.
-- Normalize to one flat string.
local function as_str(v)
    if type(v) == "table" then return table.concat(v, "") end
    if type(v) == "string" then return v end
    return ""
end

local function strip_ansi(s)
    s = s:gsub("\27%[[?]?[%d;]*[a-zA-Z]", "")
    s = s:gsub("\27%][^\27]*\27\\", "")
    return s
end

local function dw(s) return vim.fn.strdisplaywidth(s) end

-- Wrap a single logical line into chunks of at most `max_w` display cells.
-- Breaks at spaces when possible, hard-breaks otherwise.
local function wrap(line, max_w)
    if max_w <= 0 then return { line } end
    if dw(line) <= max_w then return { line } end
    local out, n = {}, vim.fn.strchars(line)
    local pos = 0
    while pos < n do
        local start = pos
        local cur_w, last_space = 0, -1
        while pos < n do
            local ch = vim.fn.strcharpart(line, pos, 1)
            local cw = dw(ch)
            if cur_w + cw > max_w then break end
            if ch == " " then last_space = pos end
            cur_w = cur_w + cw
            pos = pos + 1
        end
        if pos < n and last_space > start then
            table.insert(out, vim.fn.strcharpart(line, start, last_space - start))
            pos = last_space + 1
        else
            if pos == start then pos = pos + 1 end
            table.insert(out, vim.fn.strcharpart(line, start, pos - start))
        end
    end
    return out
end

-- Wrap content text into a single virt_line: `│ <content padded> │`.
-- The cell_frame's right-side bar lives at the window edge via right_align,
-- but virt_lines are full-line text that don't honor right_align. We pad
-- with spaces to the requested inner width and append our own `│`.
local function side_wrap(text, hl, inner_w, border_hl)
    local pad = math.max(inner_w - dw(text), 0)
    return {
        { "│ ", border_hl },
        { text, hl },
        { string.rep(" ", pad) .. " │", border_hl },
    }
end

-- The divider line between the cell source and its outputs:
--   ├─ Out[N] ──────────┤
local function divider_line(label, width)
    local main = "├─ " .. label .. " "
    local pad = width - dw(main) - 1 -- 1 for the closing ┤
    return main .. string.rep("─", math.max(pad, 0)) .. "┤"
end

-- Pick the first image MIME present in a display_data / execute_result's
-- mime bundle. Order matters: PNG is the highest fidelity Jupyter normally
-- emits; GIF is preferred over JPEG for animated payloads.
local IMAGE_MIMES = { "image/png", "image/gif", "image/jpeg" }
local function find_image_b64(data)
    if type(data) ~= "table" then return nil end
    for _, m in ipairs(IMAGE_MIMES) do
        local v = data[m]
        if type(v) == "table" then v = table.concat(v, "") end
        if type(v) == "string" and v ~= "" then return v end
    end
    return nil
end

-- Wrap a Kitty placeholder row (already chunked by jovian.ui.kitty into
-- one chunk per cell column) with the box-drawing side bars + right-pad
-- so it sits inside the cell frame at `inner_w` wide.
local function image_row_with_sides(placeholder_chunks, cols, inner_w, border_hl)
    local pad = math.max(inner_w - cols, 0)
    local out = { { "│ ", border_hl } }
    for _, c in ipairs(placeholder_chunks) do
        table.insert(out, c)
    end
    table.insert(out, { string.rep(" ", pad) .. " │", border_hl })
    return out
end

--- Build the virt_lines for a cell's outputs.
--- Returns an empty list when the cell has no outputs.
---
--- @param outputs table  list of nbformat output entries
--- @param execution_count number|nil for the Out[N] label
--- @param width number total cell width (including the side bars)
--- @param border_hl string the cell_frame border highlight group
--- @param refresh_cb function|nil called when an async image transmit
---   completes, so the cell_frame caller can re-render with the image
--- @return table list of virt_line chunk arrays
function M.build_virt_lines(outputs, execution_count, width, border_hl, refresh_cb)
    if not outputs or #outputs == 0 then return {} end
    local inner_w = width - 4 -- "│ " + content + " │"
    if inner_w < 1 then inner_w = 1 end

    local rows = {}
    local exec_label = execution_count and tostring(execution_count) or " "
    table.insert(rows, { { divider_line("Out[" .. exec_label .. "]", width), HL.Divider } })

    -- Lazy-require Config so build_virt_lines stays usable in tests that
    -- haven't called setup().
    local Config = require("jovian.config")
    local Kitty -- lazily required only when an image output appears

    for _, o in ipairs(outputs) do
        local kind = o.output_type
        if kind == "stream" then
            local hl = (o.name == "stderr") and HL.Stderr or HL.Stdout
            local text = strip_ansi(as_str(o.text))
            -- Trim a single trailing newline so we don't add a blank row
            -- after every print() call.
            text = text:gsub("\n$", "")
            for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
                for _, w in ipairs(wrap(line, inner_w)) do
                    table.insert(rows, side_wrap(w, hl, inner_w, border_hl))
                end
            end
        elseif kind == "execute_result" or kind == "display_data" then
            local data = o.data or {}
            local img_b64 = find_image_b64(data)
            local tp = as_str(data["text/plain"])
            local has_img = img_b64 ~= nil
            -- Matplotlib emits "<Figure size NxM with K Axes>" as the
            -- text/plain alongside the PNG. Suppressing it keeps the
            -- output area tidy when the image is the real content.
            if has_img and (tp == ""
                or tp:match("^<Figure ")
                or tp:match("^<[%w._]+ object>$")
                or tp:match("^<[%w._]+ object at 0x[%x]+>$"))
            then
                tp = ""
            end
            if tp ~= "" then
                tp = strip_ansi(tp):gsub("\n$", "")
                for _, line in ipairs(vim.split(tp, "\n", { plain = true })) do
                    for _, w in ipairs(wrap(line, inner_w)) do
                        table.insert(rows, side_wrap(w, HL.Result, inner_w, border_hl))
                    end
                end
            end
            if has_img then
                Kitty = Kitty or require("jovian.ui.kitty")
                local image_rows = Config.options.image_rows or 14
                local image_cols = math.min(Config.options.image_cols or 56, inner_w)
                local id = Kitty.ensure_transmitted(img_b64, refresh_cb, image_cols, image_rows)
                if id then
                    local placement = Kitty.build_virt_lines(id, image_rows, image_cols)
                    for _, prow in ipairs(placement) do
                        table.insert(rows, image_row_with_sides(prow, image_cols, inner_w, border_hl))
                    end
                else
                    -- Reserve blank space while the transmit is in flight;
                    -- the refresh_cb will re-trigger render with the real
                    -- placeholders once the image_id arrives.
                    for _ = 1, image_rows do
                        table.insert(rows, side_wrap("", HL.Result, inner_w, border_hl))
                    end
                end
            end
        elseif kind == "error" then
            local head = as_str(o.ename) .. ": " .. as_str(o.evalue)
            if head == ": " then head = "Error" end
            for _, w in ipairs(wrap(head, inner_w)) do
                table.insert(rows, side_wrap(w, HL.Error, inner_w, border_hl))
            end
            for _, tb in ipairs(o.traceback or {}) do
                local plain = strip_ansi(as_str(tb))
                for _, line in ipairs(vim.split(plain, "\n", { plain = true })) do
                    for _, w in ipairs(wrap(line, inner_w)) do
                        table.insert(rows, side_wrap(w, HL.Error, inner_w, border_hl))
                    end
                end
            end
        end
        -- Other output types (e.g. clear_output) intentionally skipped.
    end

    return rows
end

-- ---------- Sidecar JSON reader ----------

local function sidecar_path(source_path)
    if not source_path or source_path == "" then return nil end
    local dir = vim.fn.fnamemodify(source_path, ":p:h")
    local fname = vim.fn.fnamemodify(source_path, ":t")
    if fname == "" then return nil end
    return dir .. "/.jovian_cache/" .. fname .. "/outputs.json"
end

local _cache = {} -- path → { mtime = number, data = table }

--- Read the sidecar JSON for a source file. Cached by file mtime so
--- repeated reads from the renderer don't pound the disk on each
--- TextChanged tick.
function M.read_sidecar(source_path)
    local path = sidecar_path(source_path)
    if not path then return nil end
    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(path)
    if not stat then
        _cache[path] = nil
        return nil
    end
    local cached = _cache[path]
    if cached and cached.mtime == stat.mtime.sec then
        return cached.data
    end
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return nil end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then return nil end
    _cache[path] = { mtime = stat.mtime.sec, data = decoded }
    return decoded
end

--- Convenience: fetch one cell's { execution_count, outputs }.
function M.cell_outputs(source_path, cell_id)
    local sidecar = M.read_sidecar(source_path)
    if not sidecar or not sidecar.cells then return nil end
    return sidecar.cells[cell_id]
end

--- Drop the in-process cache. Used when an explicit invalidation event
--- (e.g. RPC cell_event) arrives faster than the filesystem mtime
--- granularity would reveal.
function M.invalidate(source_path)
    local path = sidecar_path(source_path)
    if path then _cache[path] = nil end
end

-- ---------- Preview buffer renderer ----------
--
-- The side preview window doesn't honour right_align / virt_text, so we
-- can't reuse the chunked `│ ... │` form the cell_frame uses inline.
-- Instead we write plain text lines into the buffer and apply per-line
-- highlight extmarks. Same color groups as inline outputs so the two
-- views read consistently.

local PREVIEW_NS = vim.api.nvim_create_namespace("jovian_preview_outputs")

local function outputs_to_preview_lines(outputs, refresh_cb)
    local lines, hls = {}, {}
    local function push(text, hl)
        for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
            table.insert(lines, line)
            table.insert(hls, hl)
        end
    end
    local Config = require("jovian.config")
    local Kitty -- lazily required only when an image appears
    for _, o in ipairs(outputs) do
        local kind = o.output_type
        if kind == "stream" then
            local hl = (o.name == "stderr") and HL.Stderr or HL.Stdout
            local text = strip_ansi(as_str(o.text)):gsub("\n$", "")
            if text ~= "" then push(text, hl) end
        elseif kind == "execute_result" or kind == "display_data" then
            local data = o.data or {}
            local img_b64 = find_image_b64(data)
            local tp = as_str(data["text/plain"])
            local has_img = img_b64 ~= nil
            if has_img and tp ~= ""
                and (tp:match("^<Figure ")
                    or tp:match("^<[%w._]+ object>$")
                    or tp:match("^<[%w._]+ object at 0x[%x]+>$"))
            then
                tp = ""
            end
            if tp ~= "" then
                push(strip_ansi(tp):gsub("\n$", ""), HL.Result)
            end
            if has_img then
                Kitty = Kitty or require("jovian.ui.kitty")
                local rows = Config.options.image_rows or 14
                local cols = Config.options.image_cols or 56
                local id = Kitty.ensure_transmitted(img_b64, refresh_cb, cols, rows)
                if id then
                    -- Each row of the placement is a list of per-cell chunks
                    -- (all sharing the same JovianKittyImg_<id> hl). For the
                    -- preview buffer we concatenate them into one string per
                    -- line — kitty intercepts the placeholders the same way
                    -- whether they came from virt_text or real buffer bytes.
                    local placement = Kitty.build_virt_lines(id, rows, cols)
                    for _, row_chunks in ipairs(placement) do
                        local parts = {}
                        for _, chunk in ipairs(row_chunks) do
                            table.insert(parts, chunk[1])
                        end
                        table.insert(lines, table.concat(parts))
                        table.insert(hls, row_chunks[1][2])
                    end
                else
                    -- Reserve blank rows while the transmit is in flight;
                    -- the refresh_cb re-runs render_to_buffer once the
                    -- image_id arrives.
                    for _ = 1, rows do
                        table.insert(lines, "")
                        table.insert(hls, HL.Result)
                    end
                end
            end
        elseif kind == "error" then
            local head = as_str(o.ename) .. ": " .. as_str(o.evalue)
            if head ~= ": " then push(head, HL.Error) end
            for _, tb in ipairs(o.traceback or {}) do
                push(strip_ansi(as_str(tb)), HL.Error)
            end
        end
    end
    return lines, hls
end

--- Render a cell's outputs into a buffer (the side preview pane or a pin).
--- Writes text lines + applies highlight extmarks per line. Safe to call
--- on every cursor move; cheap because we don't allocate per-row chunks.
function M.render_to_buffer(buf, win, source_path, cell_id, execution_count_hint)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    M.setup_hl(nil)

    local co = M.cell_outputs(source_path, cell_id)
    local exec
    -- Async Kitty image transmits arrive after render returns; re-call
    -- ourselves when they land so the preview swaps reserved blank rows
    -- for the actual placeholder chars.
    local refresh_cb = function()
        if vim.api.nvim_buf_is_valid(buf) then
            vim.schedule(function()
                M.render_to_buffer(buf, win, source_path, cell_id, execution_count_hint)
            end)
        end
    end
    local body_lines, body_hls = {}, {}
    if co then
        exec = co.execution_count
        body_lines, body_hls = outputs_to_preview_lines(co.outputs or {}, refresh_cb)
    end
    if exec == nil then exec = execution_count_hint end

    -- Header: "Out[N]" + an underline. Falls back to a hint if the cell
    -- has no outputs yet so the user still gets the cell identifier.
    local lines, hls = {}, {}
    local label = "Out[" .. (exec and tostring(exec) or " ") .. "]"
    table.insert(lines, label)
    table.insert(hls, HL.Divider)
    table.insert(lines, string.rep("─", math.max(#label, 12)))
    table.insert(hls, HL.Divider)

    if #body_lines == 0 then
        table.insert(lines, "(no output)")
        table.insert(hls, HL.Divider)
    else
        for i, l in ipairs(body_lines) do
            table.insert(lines, l)
            table.insert(hls, body_hls[i])
        end
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    vim.api.nvim_buf_clear_namespace(buf, PREVIEW_NS, 0, -1)
    for i, hl in ipairs(hls) do
        if hl then
            pcall(vim.api.nvim_buf_set_extmark, buf, PREVIEW_NS, i - 1, 0, {
                end_row = i,
                end_col = 0,
                hl_eol = true,
                hl_group = hl,
                priority = 100,
            })
        end
    end

    -- Scroll to top so the user sees Out[N] first, not the tail.
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    end
end

M._HL = HL

return M
