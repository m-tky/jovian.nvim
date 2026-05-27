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

--- Build the virt_lines for a cell's outputs.
--- Returns an empty list when the cell has no outputs.
---
--- @param outputs table  list of nbformat output entries
--- @param execution_count number|nil for the Out[N] label
--- @param width number total cell width (including the side bars)
--- @param border_hl string the cell_frame border highlight group
--- @return table list of virt_line chunk arrays
function M.build_virt_lines(outputs, execution_count, width, border_hl)
    if not outputs or #outputs == 0 then return {} end
    local inner_w = width - 4 -- "│ " + content + " │"
    if inner_w < 1 then inner_w = 1 end

    local rows = {}
    local exec_label = execution_count and tostring(execution_count) or " "
    table.insert(rows, { { divider_line("Out[" .. exec_label .. "]", width), HL.Divider } })

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
            local tp = as_str(data["text/plain"])
            if tp ~= "" then
                tp = strip_ansi(tp):gsub("\n$", "")
                for _, line in ipairs(vim.split(tp, "\n", { plain = true })) do
                    for _, w in ipairs(wrap(line, inner_w)) do
                        table.insert(rows, side_wrap(w, HL.Result, inner_w, border_hl))
                    end
                end
            end
            -- Phase 3 will add image/png + image/gif rendering here via
            -- the Rust core's Kitty graphics protocol.
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

M._HL = HL

return M
