-- Download a prebuilt jovian-core binary from GitHub releases, or fall back
-- to `cargo build --release` if the host platform isn't covered.
--
-- Used by the lazy.nvim `build` hook so users don't need a Rust toolchain
-- on supported platforms. Nix users bypass this entirely — the flake's
-- vimPlugin derivation drops the prebuilt binary at the expected path
-- during postPatch, and the Lua locator finds it there.

local M = {}

local REPO = "m-tky/jovian.nvim"

local function detect_target()
    local u = (vim.uv or vim.loop).os_uname()
    local sys, mach = u.sysname, u.machine
    if sys == "Darwin" then
        if mach == "arm64" then
            return "aarch64-apple-darwin"
        end
        if mach == "x86_64" then
            return "x86_64-apple-darwin"
        end
    elseif sys == "Linux" then
        if mach == "x86_64" then
            return "x86_64-unknown-linux-gnu"
        end
        if mach == "aarch64" then
            return "aarch64-unknown-linux-gnu"
        end
    end
    return nil
end

local function detect_tag(plugin_dir)
    local out = vim.fn.system({ "git", "-C", plugin_dir, "describe", "--tags", "--exact-match" })
    if vim.v.shell_error == 0 then
        return vim.trim(out)
    end
    -- No `--abbrev=0` fallback: it returned the nearest OLDER tag, so the
    -- prebuilt binary's wire protocol could mismatch this checkout's Lua.
    -- When HEAD isn't exactly on a tag, return nil and build from source.
    return nil
end

local function build_from_source(plugin_dir)
    local manifest = plugin_dir .. "/core/Cargo.toml"
    if vim.fn.executable("cargo") == 0 then
        error(
            "jovian: cargo not found in PATH.\n"
                .. "Install Rust (https://rustup.rs) or use a supported prebuilt platform."
        )
    end
    vim.notify("jovian: building jovian-core from source via cargo...", vim.log.levels.INFO)
    local out = vim.fn.system({ "cargo", "build", "--release", "--manifest-path", manifest })
    if vim.v.shell_error ~= 0 then
        error(("jovian: cargo build failed: %s"):format(out))
    end
end

function M.run(plugin)
    local plugin_dir = (plugin and plugin.dir) or vim.fn.expand("~/.local/share/nvim/lazy/jovian.nvim")

    local target = detect_target()
    local tag = target and detect_tag(plugin_dir)
    if not target or not tag then
        build_from_source(plugin_dir)
        return false
    end

    local url = string.format("https://github.com/%s/releases/download/%s/jovian-core-%s", REPO, tag, target)
    local dest_dir = plugin_dir .. "/core/target/release"
    vim.fn.mkdir(dest_dir, "p")
    local dest = dest_dir .. "/jovian-core"

    vim.notify(("jovian: downloading prebuilt %s..."):format(tag), vim.log.levels.INFO)
    local curl = { "curl", "-fsSL", "--retry", "3", "--retry-delay", "2", "-o", dest, url }
    local failed, detail
    if vim.system then
        -- curl writes its error to stderr; vim.fn.system only returns stdout
        -- (usually empty on failure), so the old warning was blank. Capture
        -- stderr via vim.system.
        local res = vim.system(curl, { text = true }):wait()
        failed = res.code ~= 0
        detail = (res.stderr ~= "" and res.stderr) or res.stdout or ("exit " .. tostring(res.code))
    else
        local out = vim.fn.system(curl)
        failed = vim.v.shell_error ~= 0
        detail = out
    end
    if failed then
        vim.notify(
            ("jovian: download failed (%s), falling back to cargo"):format(vim.trim(detail or "")),
            vim.log.levels.WARN
        )
        build_from_source(plugin_dir)
        return false
    end

    -- Verify the download against the published sha256 before trusting it.
    -- A missing checksum (e.g. a release predating this) or a mismatch
    -- (corruption / tampering) both fall back to building from source.
    local sum_out = vim.fn.system({ "curl", "-fsSL", "--retry", "3", "--retry-delay", "2", url .. ".sha256" })
    local want = vim.v.shell_error == 0 and vim.trim(sum_out):match("^(%x+)") or nil
    local got = nil
    local f = io.open(dest, "rb")
    if f then
        got = vim.fn.sha256(f:read("*a"))
        f:close()
    end
    if not want or not got or want:lower() ~= got:lower() then
        os.remove(dest)
        vim.notify(
            ("jovian: checksum verification failed (want %s, got %s), falling back to cargo"):format(
                tostring(want),
                tostring(got)
            ),
            vim.log.levels.WARN
        )
        build_from_source(plugin_dir)
        return false
    end

    vim.fn.system({ "chmod", "+x", dest })
    if (vim.uv or vim.loop).os_uname().sysname == "Darwin" then
        vim.fn.system({ "xattr", "-cr", dest })
    end
    vim.notify(("jovian: installed prebuilt %s"):format(target), vim.log.levels.INFO)
    return true
end

M._detect_target = detect_target
M._detect_tag = detect_tag

return M
