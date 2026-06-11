-- Python interpreter resolution for jovian.
--
-- Goal: by default, find a python with `ipykernel` available without making
-- the user register a Jupyter kernelspec. We probe the conventional sources
-- in order and pick the first one that can actually import ipykernel, then
-- hand its absolute path to jovian-core so it can spawn the kernel directly
-- (`python -m ipykernel_launcher`) — no `kernel.json` required.
--
-- If nothing usable is found, we leave the configured value as-is so the
-- Rust side still tries its own kernelspec discovery as a last resort.

local M = {}

local function is_executable(path)
    return path and path ~= "" and vim.fn.executable(path) == 1
end

local function exepath(name)
    local p = vim.fn.exepath(name)
    if p and p ~= "" then
        return p
    end
    return nil
end

-- Cache of `python -> bool` for the ipykernel probe. Each entry costs a
-- subprocess call (~50–200 ms), so we keep the result for the session.
M._ipykernel_cache = {}

function M.has_ipykernel(python)
    if not is_executable(python) then
        return false
    end
    if M._ipykernel_cache[python] ~= nil then
        return M._ipykernel_cache[python]
    end
    -- Exit code is the authoritative signal. The old extra `out:match
    -- "[Ee]rror"` check false-rejected a perfectly good interpreter whose
    -- stderr happened to carry a warning containing "error"/"Error".
    vim.fn.system({ python, "-c", "import ipykernel" })
    local ok = vim.v.shell_error == 0
    M._ipykernel_cache[python] = ok
    return ok
end

-- Each entry: { path = "/abs/path/python", source = "label" }. We collect
-- everything that *could* be a python (executable bit only) and filter on
-- `has_ipykernel` later — that way the picker can show why a candidate was
-- rejected ("python3 on PATH, missing ipykernel") instead of silently
-- skipping it.
function M.candidates()
    local seen = {}
    local out = {}
    local function add(path, source)
        if not path or path == "" then
            return
        end
        local abs = vim.fn.fnamemodify(path, ":p")
        if seen[abs] then
            return
        end
        seen[abs] = true
        table.insert(out, { path = abs, source = source })
    end

    -- 1. PATH python3 / python — the nix devshell case the user cares about
    --    most: `nix develop` puts a python with ipykernel first on PATH.
    add(exepath("python3"), "PATH (python3)")
    add(exepath("python"), "PATH (python)")

    -- 2. Active venv / conda env (these are explicit per-shell choices)
    local venv = vim.env.VIRTUAL_ENV
    if venv and venv ~= "" then
        add(venv .. "/bin/python", "$VIRTUAL_ENV")
    end
    local conda = vim.env.CONDA_PREFIX
    if conda and conda ~= "" then
        add(conda .. "/bin/python", "$CONDA_PREFIX")
    end

    -- 3. Project-local venvs (poetry / uv / vanilla)
    local cwd = vim.fn.getcwd()
    add(cwd .. "/.venv/bin/python", ".venv")
    add(cwd .. "/venv/bin/python", "venv")

    return out
end

--- First candidate whose python can `import ipykernel`. Returns
--- `path, source` or `nil, nil` if nothing matched.
function M.resolve()
    for _, c in ipairs(M.candidates()) do
        if M.has_ipykernel(c.path) then
            return c.path, c.source
        end
    end
    return nil, nil
end

--- Async wrapper around the core `list_kernels` RPC. `cb(specs|nil, err|nil)`.
--- Returns the discovered Jupyter kernelspecs (`kernel.json` files registered
--- on disk). Used by the picker — orthogonal to `resolve()`, which doesn't
--- need any kernelspec to exist.
function M.list_kernelspecs(cb)
    local ok, Core = pcall(require, "jovian.backend.core")
    if not ok then
        return cb(nil, "jovian-core backend unavailable")
    end
    local client = Core.ensure()
    client:request("list_kernels", {}, function(err, result)
        if err then
            return cb(nil, err)
        end
        cb(result or {}, nil)
    end)
end

return M
