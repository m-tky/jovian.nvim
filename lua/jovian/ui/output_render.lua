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
local Shared = require("jovian.ui.shared")
local Highlights = require("jovian.ui.hl_utils")
local CellFrame = require("jovian.ui.cell_frame")
local strip_ansi = Shared.strip_ansi
local dw = Highlights.dw

local HL = {
    Divider = "JovianOutDivider",
    Stdout = "JovianOutStdout",
    Stderr = "JovianOutStderr",
    Result = "JovianOutResult",
    Error = "JovianOutError",
}

function M.setup_hl(border_hl)
    -- border_hl is whichever cell_frame chose for the current cell type;
    -- the divider line inherits it so the `├` and `┤` corners align
    -- visually with the cell box.
    local user_hl = Config.options.highlights or {}
    Highlights.apply(HL.Divider, user_hl.out_divider, border_hl or "Comment")
    Highlights.apply(HL.Stdout, user_hl.out_stdout, "Normal")
    Highlights.apply(HL.Stderr, user_hl.out_stderr, "WarningMsg")
    Highlights.apply(HL.Result, user_hl.out_result, "Identifier")
    Highlights.apply(HL.Error, user_hl.out_error, "ErrorMsg")
end

-- nbformat allows text fields to be either a string or an array of strings.
-- Normalize to one flat string.
local function as_str(v)
    if type(v) == "table" then
        return table.concat(v, "")
    end
    if type(v) == "string" then
        return v
    end
    return ""
end

-- Apply carriage-return overwrite semantics: within each logical (\n)
-- line, a \r returns to the start of the line, so only the LAST
-- \r-terminated segment survives. This collapses tqdm / progress-bar
-- spam (which re-prints the bar after every \r) to its final frame,
-- instead of rendering every intermediate state concatenated. The REPL
-- terminal buffer handles \r natively; this is for the text renderers.
local function process_cr(s)
    if not s:find("\r", 1, true) then
        return s
    end
    local out = {}
    for chunk in (s .. "\n"):gmatch("([^\n]*)\n") do
        local last = ""
        for seg in (chunk .. "\r"):gmatch("([^\r]*)\r") do
            last = seg
        end
        table.insert(out, last)
    end
    if out[#out] == "" then
        table.remove(out)
    end
    return table.concat(out, "\n")
end

-- Wrap a single logical line into chunks of at most `max_w` display cells.
-- Breaks at spaces when possible, hard-breaks otherwise.
local function wrap(line, max_w)
    if max_w <= 0 then
        return { line }
    end
    if dw(line) <= max_w then
        return { line }
    end
    local out, n = {}, vim.fn.strchars(line)
    local pos = 0
    while pos < n do
        local start = pos
        local cur_w, last_space = 0, -1
        while pos < n do
            local ch = vim.fn.strcharpart(line, pos, 1)
            local cw = dw(ch)
            if cur_w + cw > max_w then
                break
            end
            if ch == " " then
                last_space = pos
            end
            cur_w = cur_w + cw
            pos = pos + 1
        end
        if pos < n and last_space > start then
            table.insert(out, vim.fn.strcharpart(line, start, last_space - start))
            pos = last_space + 1
        else
            if pos == start then
                pos = pos + 1
            end
            table.insert(out, vim.fn.strcharpart(line, start, pos - start))
        end
    end
    return out
end

-- The frame chrome helpers (left+right side bars padded to a width) live in
-- cell_frame.lua — they're the same trick markdown_table / markdown_cell use
-- for any virt_line that has to sit inside a cell's frame.
local side_wrap = CellFrame.frame_wrap
local image_row_with_sides = CellFrame.frame_image_row

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
    if type(data) ~= "table" then
        return nil
    end
    for _, m in ipairs(IMAGE_MIMES) do
        local v = data[m]
        if type(v) == "table" then
            v = table.concat(v, "")
        end
        if type(v) == "string" and v ~= "" then
            return v
        end
    end
    return nil
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
function M.build_virt_lines(outputs, execution_count, width, border_hl, refresh_cb, cell_id)
    if not outputs or #outputs == 0 then
        return {}
    end
    local inner_w = math.max(width - 4, 1) -- "│ " + content + " │"

    local exec_label = execution_count and tostring(execution_count) or " "
    -- Outputs loaded from the sidecar JSON without a fresh re-run in the
    -- current kernel session get a "(cached)" suffix so the user can tell
    -- them apart from this-session results.
    local State = require("jovian.state")
    local label = "Out[" .. exec_label .. "]"
    if cell_id and not State.fresh_cells[cell_id] then
        label = label .. " (cached)"
    end

    local Kitty -- lazily required only when an image output appears

    -- Collect the output rows into `body` (the divider is prepended after
    -- capping). has_image disables the line cap — plots are bounded and
    -- rarely sit next to thousands of text lines.
    local body = {}
    local has_image = false
    local function emit(row)
        body[#body + 1] = row
    end

    for _, o in ipairs(outputs) do
        local kind = o.output_type
        if kind == "stream" then
            local hl = (o.name == "stderr") and HL.Stderr or HL.Stdout
            local text = process_cr(strip_ansi(as_str(o.text)))
            text = text:gsub("\n$", "")
            for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
                for _, w in ipairs(wrap(line, inner_w)) do
                    emit(side_wrap(w, hl, inner_w, border_hl))
                end
            end
        elseif kind == "execute_result" or kind == "display_data" then
            local data = o.data or {}
            local img_b64 = find_image_b64(data)
            local tp = as_str(data["text/plain"])
            local img = img_b64 ~= nil
            if
                img
                and (
                    tp == ""
                    or tp:match("^<Figure ")
                    or tp:match("^<[%w._]+ object>$")
                    or tp:match("^<[%w._]+ object at 0x[%x]+>$")
                )
            then
                tp = ""
            end
            if tp ~= "" then
                tp = strip_ansi(tp):gsub("\n$", "")
                for _, line in ipairs(vim.split(tp, "\n", { plain = true })) do
                    for _, w in ipairs(wrap(line, inner_w)) do
                        emit(side_wrap(w, HL.Result, inner_w, border_hl))
                    end
                end
            end
            if img then
                has_image = true
                Kitty = Kitty or require("jovian.ui.kitty")
                local image_rows = Config.options.image_rows or 14
                local image_cols = math.min(Config.options.image_cols or 56, inner_w)
                local id = Kitty.ensure_transmitted(img_b64, refresh_cb, image_cols, image_rows)
                if id then
                    local placement = Kitty.build_virt_lines(id, image_rows, image_cols)
                    for _, prow in ipairs(placement) do
                        emit(image_row_with_sides(prow, image_cols, inner_w, border_hl))
                    end
                else
                    for _ = 1, image_rows do
                        emit(side_wrap("", HL.Result, inner_w, border_hl))
                    end
                end
            end
        elseif kind == "error" then
            local head = as_str(o.ename) .. ": " .. as_str(o.evalue)
            if head == ": " then
                head = "Error"
            end
            for _, w in ipairs(wrap(head, inner_w)) do
                emit(side_wrap(w, HL.Error, inner_w, border_hl))
            end
            for _, tb in ipairs(o.traceback or {}) do
                local plain = strip_ansi(as_str(tb))
                for _, line in ipairs(vim.split(plain, "\n", { plain = true })) do
                    for _, w in ipairs(wrap(line, inner_w)) do
                        emit(side_wrap(w, HL.Error, inner_w, border_hl))
                    end
                end
            end
        end
        -- Other output types (e.g. clear_output) intentionally skipped.
    end

    -- Cap long text output: keep the first chunk + last few lines with a
    -- "… N more …" notice between, so the inline block stays bounded.
    local max = Config.options.inline_output_max_lines or 20
    if not has_image and max > 0 and #body > max then
        local tail = math.min(3, math.max(1, math.floor(max / 4)))
        local head = max - tail - 1 -- 1 row for the notice
        if head < 1 then
            head = 1
        end
        local hidden = #body - head - tail
        local capped = {}
        for i = 1, head do
            capped[#capped + 1] = body[i]
        end
        capped[#capped + 1] = side_wrap(
            ("… %d more line(s) — open preview / :JovianToggleOutput …"):format(hidden),
            HL.Divider,
            inner_w,
            border_hl
        )
        for i = #body - tail + 1, #body do
            capped[#capped + 1] = body[i]
        end
        body = capped
    end

    local rows = { { { divider_line(label, width), HL.Divider } } }
    for _, r in ipairs(body) do
        rows[#rows + 1] = r
    end
    return rows
end

-- ---------- Sidecar JSON reader ----------

local function sidecar_path(source_path)
    if not source_path or source_path == "" then
        return nil
    end
    local dir = vim.fn.fnamemodify(source_path, ":p:h")
    local fname = vim.fn.fnamemodify(source_path, ":t")
    if fname == "" then
        return nil
    end
    return dir .. "/.jovian_cache/" .. fname .. "/outputs.json"
end

local _cache = {} -- path → { mtime = number, data = table }

--- Read the sidecar JSON for a source file. Cached by file mtime so
--- repeated reads from the renderer don't pound the disk on each
--- TextChanged tick.
function M.read_sidecar(source_path)
    local path = sidecar_path(source_path)
    if not path then
        return nil
    end
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
    if not f then
        return nil
    end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    _cache[path] = { mtime = stat.mtime.sec, data = decoded }
    return decoded
end

--- Convenience: fetch one cell's { execution_count, outputs }.
function M.cell_outputs(source_path, cell_id)
    local sidecar = M.read_sidecar(source_path)
    if not sidecar or not sidecar.cells then
        return nil
    end
    return sidecar.cells[cell_id]
end

--- Drop the in-process cache. Used when an explicit invalidation event
--- (e.g. RPC cell_event) arrives faster than the filesystem mtime
--- granularity would reveal.
function M.invalidate(source_path)
    local path = sidecar_path(source_path)
    if path then
        _cache[path] = nil
    end
end

-- ---------- Preview buffer renderer ----------
--
-- The side preview window doesn't honour right_align / virt_text, so we
-- can't reuse the chunked `│ ... │` form the cell_frame uses inline.
-- Instead we write plain text lines into the buffer and apply per-line
-- highlight extmarks. Same color groups as inline outputs so the two
-- views read consistently.

local PREVIEW_NS = vim.api.nvim_create_namespace("jovian_preview_outputs")

-- Parse the dimensions (pixels) out of an image's base64 header.
-- Returns width, height or nil for unknown formats. Only PNG and GIF
-- carry width/height at fixed offsets close enough to the start that
-- decoding the first 32 base64 chars (= 24 bytes) is sufficient.
-- JPEG falls through to nil and the caller uses the default aspect.
local function decode_b64_head(b64)
    local head = b64:sub(1, 32):gsub("[\r\n]", "")
    while #head % 4 ~= 0 do
        head = head .. "="
    end
    local ok, raw = pcall(vim.base64.decode, head)
    if not ok or type(raw) ~= "string" then
        return nil
    end
    return raw
end

local function image_pixel_dims(b64)
    if not b64 or #b64 < 32 then
        return nil
    end
    local raw = decode_b64_head(b64)
    if not raw or #raw < 24 then
        return nil
    end
    local b = function(i)
        return raw:byte(i) or 0
    end
    -- PNG: 89 50 4E 47 ... then IHDR at byte 13, width/height at 17/21.
    if b(1) == 0x89 and b(2) == 0x50 and b(3) == 0x4E and b(4) == 0x47 then
        local w = b(17) * 0x1000000 + b(18) * 0x10000 + b(19) * 0x100 + b(20)
        local h = b(21) * 0x1000000 + b(22) * 0x10000 + b(23) * 0x100 + b(24)
        if w > 0 and h > 0 then
            return w, h
        end
    end
    -- GIF: "GIF" then version then width/height (little-endian u16).
    if b(1) == 0x47 and b(2) == 0x49 and b(3) == 0x46 then
        local w = b(7) + b(8) * 256
        local h = b(9) + b(10) * 256
        if w > 0 and h > 0 then
            return w, h
        end
    end
    return nil
end

-- Returns the available text-area dimensions of the preview window.
-- We reserve 4 rows for the Out[N] header + breathing room and 2 cols
-- of side margin so the image doesn't kiss the edge.
local function preview_available_area(win)
    local max_cols_cap = Config.options.preview_image_max_cols
    local max_rows_cap = Config.options.preview_image_max_rows

    local win_w, win_h
    if win and vim.api.nvim_win_is_valid(win) then
        local info = vim.fn.getwininfo(win)[1] or {}
        local textoff = info.textoff or 0
        win_w = vim.api.nvim_win_get_width(win) - textoff
        win_h = vim.api.nvim_win_get_height(win)
    end
    local avail_w = math.max((max_cols_cap or win_w or 80) - 2, 10)
    local avail_h = math.max((max_rows_cap or win_h or 24) - 4, 5)
    return avail_w, avail_h
end

-- Compute the placement size (cols × rows) for one specific image,
-- preserving its actual pixel aspect. Letterbox-free, AND capped at
-- the image's native cell footprint so a 200×100 png isn't stretched
-- to fill a 200×60 cell pane.
local function fit_image_in_area(b64, max_cols, max_rows)
    local cell_pixel_aspect = Config.options.preview_cell_pixel_aspect or 0.5
    local cell_pixel_height = Config.options.preview_cell_pixel_height or 16
    local cell_pixel_width = cell_pixel_height * cell_pixel_aspect
    local w_px, h_px = image_pixel_dims(b64)

    local cell_aspect, natural_cols, natural_rows
    if w_px and h_px and cell_pixel_width > 0 then
        cell_aspect = (w_px / h_px) / cell_pixel_aspect
        natural_cols = math.floor(w_px / cell_pixel_width)
        natural_rows = math.floor(h_px / cell_pixel_height)
    else
        cell_aspect = 2.0 -- safe fallback (jpeg etc.)
        natural_cols = max_cols
        natural_rows = max_rows
    end

    -- Upper bound: never larger than the image's native cell count.
    local upper_w = math.min(max_cols, math.max(natural_cols, 1))
    local upper_h = math.min(max_rows, math.max(natural_rows, 1))

    -- Fit aspect-preserved inside upper_w × upper_h.
    local cols, rows
    local rows_for_cols = math.floor(upper_w / cell_aspect)
    if rows_for_cols <= upper_h then
        cols, rows = upper_w, rows_for_cols
    else
        rows = upper_h
        cols = math.floor(upper_h * cell_aspect)
    end
    if cols < 4 then
        cols = 4
    end
    if rows < 2 then
        rows = 2
    end
    return cols, rows
end

local function outputs_to_preview_lines(outputs, refresh_cb, max_cols, max_rows)
    local lines, hls = {}, {}
    local function push(text, hl)
        for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
            table.insert(lines, line)
            table.insert(hls, hl)
        end
    end
    local Kitty -- lazily required only when an image appears
    for _, o in ipairs(outputs) do
        local kind = o.output_type
        if kind == "stream" then
            local hl = (o.name == "stderr") and HL.Stderr or HL.Stdout
            local text = process_cr(strip_ansi(as_str(o.text))):gsub("\n$", "")
            if text ~= "" then
                push(text, hl)
            end
        elseif kind == "execute_result" or kind == "display_data" then
            local data = o.data or {}
            local img_b64 = find_image_b64(data)
            local tp = as_str(data["text/plain"])
            local has_img = img_b64 ~= nil
            if
                has_img
                and tp ~= ""
                and (
                    tp:match("^<Figure ")
                    or tp:match("^<[%w._]+ object>$")
                    or tp:match("^<[%w._]+ object at 0x[%x]+>$")
                )
            then
                tp = ""
            end
            if tp ~= "" then
                push(strip_ansi(tp):gsub("\n$", ""), HL.Result)
            end
            if has_img then
                Kitty = Kitty or require("jovian.ui.kitty")
                local cols, rows = fit_image_in_area(img_b64, max_cols or 56, max_rows or 14)
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
            if head ~= ": " then
                push(head, HL.Error)
            end
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
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    M.setup_hl(nil)

    local max_cols, max_rows = preview_available_area(win)

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
        body_lines, body_hls = outputs_to_preview_lines(co.outputs or {}, refresh_cb, max_cols, max_rows)
    end
    if exec == nil then
        exec = execution_count_hint
    end

    -- Header: "Out[N]" + an underline. Falls back to a hint if the cell
    -- has no outputs yet so the user still gets the cell identifier.
    -- "(cached)" suffix tells the user this output isn't from the
    -- current kernel session (loaded from the sidecar JSON).
    local State = require("jovian.state")
    local lines, hls = {}, {}
    local label = "Out[" .. (exec and tostring(exec) or " ") .. "]"
    if cell_id and not State.fresh_cells[cell_id] then
        label = label .. " (cached)"
    end
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
M._process_cr = process_cr
-- Aspect-preserving image sizing (PNG/GIF header → terminal cells, capped to
-- max_cols × max_rows, never upscaled). Reused by markdown_cell for inline
-- data-URI images.
M.fit_image_in_area = fit_image_in_area

return M
