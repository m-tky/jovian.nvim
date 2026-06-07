-- Transparent `.ipynb` editing, modeled on jupynvim's BufReadCmd/
-- BufWriteCmd hijack. The on-disk file stays a Jupyter notebook; the
-- buffer is the rendered `# %%`-style view. Outputs live in the
-- existing sidecar so :JovianRun / inline rendering work the same as
-- for .py files.

local M = {}

local function backend()
    return require("jovian.backend.core")
end

local function sidecar_path_for(ipynb_abs)
    local dir = vim.fn.fnamemodify(ipynb_abs, ":h")
    local fname = vim.fn.fnamemodify(ipynb_abs, ":t")
    return dir .. "/.jovian_cache/" .. fname .. "/outputs.json"
end

-- Read the raw bytes of a file. Returns nil if the file doesn't exist
-- (BufNewFile path) or is unreadable.
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, content)
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end
    local f = io.open(path, "wb")
    if not f then
        return false, "cannot open " .. path
    end
    f:write(content)
    f:close()
    return true
end

local function set_buf_lines(buf, text)
    local lines = vim.split(text, "\n", { plain = true })
    -- vim.split of "a\n" → {"a", ""}; drop a trailing empty so we don't
    -- gain a phantom blank line on every reload.
    if lines[#lines] == "" then
        table.remove(lines)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

-- Hijack: open an .ipynb file. Decodes the JSON via the Rust core, puts
-- the rendered `# %%` text into the buffer, and writes the sidecar to
-- disk so :JovianRun / output_render find the cached results.
function M.read(buf, path)
    local abs = vim.fn.fnamemodify(path, ":p")
    local raw = read_file(abs)
    if raw == nil then
        -- BufNewFile: start with one empty code cell so the user has
        -- something to edit. Rendered without an id; jovian assigns one
        -- on first :JovianRun.
        set_buf_lines(buf, "# %%\n\n")
        M._mark_pristine(buf)
        return
    end

    local client = backend().client() or backend().ensure()
    if not client then
        vim.notify("jovian-core unavailable; showing raw .ipynb JSON", vim.log.levels.WARN)
        set_buf_lines(buf, raw)
        return
    end
    client:request("ipynb_decode", { json = raw }, function(err, result)
        vim.schedule(function()
            if err then
                vim.notify("ipynb_decode failed: " .. err, vim.log.levels.ERROR)
                -- Fall back to raw JSON so the user can at least see the
                -- file rather than getting an empty buffer.
                set_buf_lines(buf, raw)
                return
            end
            set_buf_lines(buf, result.py_source or "")
            -- Persist the original outputs so output_render's read path
            -- has them on first paint, before any :JovianRun.
            if result.sidecar_json and result.sidecar_json ~= "" then
                local ok, werr = write_file(sidecar_path_for(abs), result.sidecar_json)
                if not ok then
                    vim.notify("ipynb sidecar write: " .. werr, vim.log.levels.WARN)
                end
            end
            M._mark_pristine(buf)
        end)
    end)
end

-- Hijack: write the buffer back as a Jupyter notebook. Reads current
-- buffer text + sidecar, encodes via the Rust core, writes the JSON
-- atomically over the on-disk .ipynb.
function M.write(buf, path)
    local abs = vim.fn.fnamemodify(path, ":p")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local py_source = table.concat(lines, "\n")
    local sidecar = read_file(sidecar_path_for(abs)) or ""

    local client = backend().client() or backend().ensure()
    if not client then
        return vim.notify("jovian-core unavailable; cannot save .ipynb", vim.log.levels.ERROR)
    end
    client:request("ipynb_encode", {
        py_source = py_source,
        sidecar_json = sidecar,
    }, function(err, result)
        vim.schedule(function()
            if err then
                vim.notify("ipynb_encode failed: " .. err, vim.log.levels.ERROR)
                return
            end
            local ok, werr = write_file(abs, result.json or "")
            if not ok then
                vim.notify("ipynb write: " .. werr, vim.log.levels.ERROR)
                return
            end
            M._mark_pristine(buf)
            vim.notify("Wrote " .. abs, vim.log.levels.INFO)
        end)
    end)
end

-- Mark the buffer as saved and not modified. Used after a successful
-- read or write to clear vim's modified flag without confusing the
-- swapfile machinery.
function M._mark_pristine(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.api.nvim_buf_call(buf, function()
        vim.bo[buf].modified = false
    end)
end

-- Register the autocmds. Idempotent — re-registering replaces the
-- group; called from plugin/jovian.lua at VimEnter.
function M.setup()
    local group = vim.api.nvim_create_augroup("JovianIpynb", { clear = true })

    vim.api.nvim_create_autocmd("BufReadCmd", {
        group = group,
        pattern = { "*.ipynb" },
        callback = function(args)
            local buf = args.buf
            -- acwrite forces :w through our BufWriteCmd; without it Neovim
            -- can fall through to its built-in write that would dump the
            -- rendered cell text to disk as if it were the .ipynb.
            vim.bo[buf].buftype = "acwrite"
            vim.bo[buf].swapfile = false
            vim.bo[buf].filetype = "python"
            M.read(buf, args.file)
        end,
    })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = group,
        pattern = { "*.ipynb" },
        callback = function(args)
            M.write(args.buf, args.file)
        end,
    })

    vim.api.nvim_create_autocmd("BufNewFile", {
        group = group,
        pattern = { "*.ipynb" },
        callback = function(args)
            local buf = args.buf
            vim.bo[buf].buftype = "acwrite"
            vim.bo[buf].swapfile = false
            vim.bo[buf].filetype = "python"
            M.read(buf, args.file)
        end,
    })
end

return M
