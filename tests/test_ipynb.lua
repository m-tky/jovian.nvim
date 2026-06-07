-- End-to-end tests for the .ipynb support: import/export commands +
-- the BufReadCmd/BufWriteCmd hijack. Exercises the Rust core through
-- the real RPC client so we get an honest signal on protocol drift.

vim.opt.rtp:prepend(vim.fn.getcwd())

local pass, fail = 0, 0
local function assert_true(cond, msg)
    if cond then
        pass = pass + 1
        print("  PASS " .. msg)
    else
        fail = fail + 1
        print("  FAIL " .. msg)
    end
end

require("jovian").setup({})
-- `nvim -l` skips plugin/ sourcing, so the BufReadCmd from
-- plugin/jovian.lua won't register on its own. Wire it up by hand.
require("jovian.ipynb_open").setup()

local function spin_until(pred, timeout_ms)
    local deadline = vim.uv.hrtime() + (timeout_ms or 5000) * 1e6
    while vim.uv.hrtime() < deadline do
        if pred() then
            return true
        end
        vim.wait(50)
    end
    return false
end

local function read_file(p)
    local f = io.open(p, "rb")
    if not f then
        return nil
    end
    local d = f:read("*a")
    f:close()
    return d
end

local function write_file(p, content)
    local dir = vim.fn.fnamemodify(p, ":h")
    vim.fn.mkdir(dir, "p")
    local f = io.open(p, "wb")
    f:write(content)
    f:close()
end

local function fresh_dir()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d
end

-- A representative nbformat v4 doc covering the cases we care about:
-- code cell with outputs + tags, markdown cell with multi-line source,
-- and a code cell with no id (older nbformat).
local function sample_ipynb()
    return vim.json.encode({
        cells = {
            {
                cell_type = "code",
                id = "a1",
                metadata = { tags = { "slow", "skip" } },
                source = { "x = 1\n", "y = 2" },
                execution_count = 3,
                outputs = {
                    { output_type = "stream", name = "stdout", text = "hi\n" },
                },
            },
            {
                cell_type = "markdown",
                id = "m1",
                metadata = vim.empty_dict(),
                source = { "# Title\n", "\n", "body" },
            },
            {
                cell_type = "code",
                metadata = vim.empty_dict(),
                source = { "pass\n" },
            },
        },
        metadata = {
            kernelspec = { display_name = "Python 3", language = "python", name = "python3" },
        },
        nbformat = 4,
        nbformat_minor = 5,
    })
end

print("-- :JovianImport file→file --")
do
    local dir = fresh_dir()
    local ipynb = dir .. "/nb.ipynb"
    write_file(ipynb, sample_ipynb())
    vim.cmd("JovianImport " .. ipynb)
    local py = dir .. "/nb.py"
    assert_true(
        spin_until(function()
            return vim.fn.filereadable(py) == 1
        end, 5000),
        ".py was written by :JovianImport"
    )
    local py_text = read_file(py)
    assert_true(py_text:find('# %%%% id="a1"') ~= nil, ".py header includes id=a1")
    assert_true(py_text:find('tags=%["slow","skip"%]') ~= nil, "tags carried over verbatim")
    assert_true(py_text:find("x = 1") ~= nil, "code body preserved")
    assert_true(py_text:find("# # Title") ~= nil, "markdown got the `# ` prefix")
    assert_true(py_text:find('id="imported2"') ~= nil, "fallback id assigned to id-less cell")

    local side = read_file(dir .. "/.jovian_cache/nb.py/outputs.json")
    assert_true(side ~= nil, "sidecar JSON was written next to the .py")
    assert_true(side:find('"execution_count": 3') ~= nil, "execution_count carried over")
    assert_true(side:find("hi\\n") ~= nil, "stream output carried over")
end

print("\n-- :JovianExport round-trip --")
do
    local dir = fresh_dir()
    local py = dir .. "/rt.py"
    write_file(py, '# %% id="c1" tags=["one"]\nprint(42)\n')
    write_file(
        dir .. "/.jovian_cache/rt.py/outputs.json",
        vim.json.encode({
            version = 1,
            cells = {
                c1 = {
                    execution_count = 7,
                    outputs = { { output_type = "stream", name = "stdout", text = "42\n" } },
                },
            },
        })
    )
    -- We have to open the .py first so :JovianExport reads from the buffer's path
    vim.cmd("edit " .. py)
    vim.cmd("JovianExport " .. dir .. "/rt.ipynb")
    assert_true(
        spin_until(function()
            return vim.fn.filereadable(dir .. "/rt.ipynb") == 1
        end, 5000),
        ".ipynb was written by :JovianExport"
    )
    local nb = vim.json.decode(read_file(dir .. "/rt.ipynb"))
    assert_true(nb.nbformat == 4, "nbformat version is 4")
    assert_true(#nb.cells == 1, "one cell in exported nb")
    assert_true(nb.cells[1].id == "c1", "cell id preserved")
    assert_true(vim.deep_equal(nb.cells[1].metadata.tags, { "one" }), "tags preserved")
    assert_true(nb.cells[1].execution_count == 7, "execution_count from sidecar")
    assert_true(nb.cells[1].outputs[1].text == "42\n", "outputs from sidecar")
end

print("\n-- native open: :edit foo.ipynb hijack --")
do
    local dir = fresh_dir()
    local ipynb = dir .. "/native.ipynb"
    write_file(ipynb, sample_ipynb())
    vim.cmd("edit " .. ipynb)
    -- ipynb_decode is async; spin until the buffer fills with our rendered view.
    assert_true(
        spin_until(function()
            local first = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""
            return first:find('# %%%% id="a1"') ~= nil
        end, 5000),
        "buffer was rebuilt as the rendered cell view"
    )
    assert_true(vim.bo.buftype == "acwrite", "buftype=acwrite so :w routes through us")
    assert_true(vim.bo.filetype == "python", "filetype=python for LSP/treesitter")
    assert_true(
        vim.fn.filereadable(dir .. "/.jovian_cache/native.ipynb/outputs.json") == 1,
        "sidecar written at open time so outputs render immediately"
    )

    -- Modify a cell body (line 2 is `x = 1`), save, and verify the
    -- .ipynb on disk reflects the edit while preserving outputs.
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "x = 999" })
    vim.cmd("write")
    assert_true(
        spin_until(function()
            local d = read_file(ipynb)
            return d ~= nil and d:find("999") ~= nil
        end, 5000),
        ":w persisted the buffer edit back into the .ipynb"
    )
    local roundtripped = vim.json.decode(read_file(ipynb))
    local a1 = roundtripped.cells[1]
    assert_true(a1.id == "a1", "cell id stable across read/write")
    assert_true(a1.outputs[1].text == "hi\n", "original outputs preserved through round-trip")
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
