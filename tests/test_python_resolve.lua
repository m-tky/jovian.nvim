-- Python resolver (jovian.python + config.setup auto-resolve). Headless.

vim.opt.rtp:prepend(vim.fn.getcwd())

local pass, fail = 0, 0
local function eq(actual, expected, msg)
    if actual == expected then
        pass = pass + 1
        print("  PASS " .. msg)
    else
        fail = fail + 1
        print(string.format("  FAIL %s — want %q, got %q", msg, tostring(expected), tostring(actual)))
    end
end
local function ok(cond, msg)
    if cond then
        pass = pass + 1
        print("  PASS " .. msg)
    else
        fail = fail + 1
        print("  FAIL " .. msg)
    end
end

local function fresh()
    for k in pairs(package.loaded) do
        if k:match("^jovian") then
            package.loaded[k] = nil
        end
    end
end

-- ---------------------------- candidates ----------------------------
print("\n-- candidates --")
fresh()
local Python = require("jovian.python")

local _orig_env = {
    VIRTUAL_ENV = vim.env.VIRTUAL_ENV,
    CONDA_PREFIX = vim.env.CONDA_PREFIX,
    JOVIAN_PYTHON = vim.env.JOVIAN_PYTHON,
}
local function restore_env()
    for k, v in pairs(_orig_env) do
        vim.env[k] = v
    end
end

vim.env.VIRTUAL_ENV = "/tmp/jovian_test_venv_does_not_exist"
vim.env.CONDA_PREFIX = nil
vim.env.JOVIAN_PYTHON = nil
local cands = Python.candidates()
local found_venv = false
local sources_seen = {}
for _, c in ipairs(cands) do
    sources_seen[c.source] = true
    if c.source == "$VIRTUAL_ENV" then
        found_venv = true
        eq(c.path, "/tmp/jovian_test_venv_does_not_exist/bin/python", "VIRTUAL_ENV expansion")
    end
end
ok(found_venv, "VIRTUAL_ENV produces a candidate even if path is non-existent")
ok(sources_seen[".venv"] ~= nil, ".venv candidate emitted for cwd")
ok(sources_seen["venv"] ~= nil, "venv candidate emitted for cwd")
restore_env()

-- ---------------------------- has_ipykernel cache ----------------------------
print("\n-- has_ipykernel --")
fresh()
Python = require("jovian.python")
eq(Python.has_ipykernel(nil), false, "nil is not usable")
eq(Python.has_ipykernel(""), false, "empty string is not usable")
eq(Python.has_ipykernel("/nonexistent/python_xyz"), false, "missing binary is not usable")

-- Inject a fake result so we don't need a real ipykernel install in the test.
Python._ipykernel_cache["/fake/python"] = true
eq(Python.has_ipykernel("/fake/python"), false, "cache lookup still needs executable bit")
-- Override executable() for the next check via a small monkey-patch.
local _orig_executable = vim.fn.executable
vim.fn.executable = function(p)
    if p == "/fake/python" then
        return 1
    end
    return _orig_executable(p)
end
eq(Python.has_ipykernel("/fake/python"), true, "cached true returned when executable")
vim.fn.executable = _orig_executable

-- ---------------------------- config.setup auto-resolve ----------------------------
print("\n-- config.setup explicit vs auto --")
fresh()
local Config = require("jovian.config")

-- Force the resolver to find nothing, then setup() should fall through to
-- "python3" (the documented last-resort default).
require("jovian.python").resolve = function()
    return nil, nil
end
vim.env.JOVIAN_PYTHON = nil
Config.setup({})
eq(Config.python_interpreter_explicit, false, "explicit flag false when user omitted python_interpreter")
eq(Config.options.python_interpreter, "python3", "falls back to bare 'python3' when nothing usable")
eq(Config.configured_python, "python3", "configured_python mirrors options.python_interpreter")

fresh()
Config = require("jovian.config")
require("jovian.python").resolve = function()
    return "/opt/auto/bin/python", "PATH (python3)"
end
vim.env.JOVIAN_PYTHON = nil
Config.setup({})
eq(Config.options.python_interpreter, "/opt/auto/bin/python", "auto-resolver result wins when user omitted")

fresh()
Config = require("jovian.config")
require("jovian.python").resolve = function()
    return "/opt/auto/bin/python", "PATH (python3)"
end
Config.setup({ python_interpreter = "/explicit/python" })
eq(Config.python_interpreter_explicit, true, "explicit flag true when user set python_interpreter")
eq(Config.options.python_interpreter, "/explicit/python", "explicit setup value wins over resolver")

fresh()
Config = require("jovian.config")
require("jovian.python").resolve = function()
    return nil, nil
end
vim.env.JOVIAN_PYTHON = "/env/python"
Config.setup({})
eq(Config.options.python_interpreter, "/env/python", "JOVIAN_PYTHON env wins when no explicit setting")
restore_env()

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
    os.exit(1)
end
