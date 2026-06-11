local M = {}
local Config = require("jovian.config")

-- Guards so repeated setup()/LspAttach don't stack wrappers. The global
-- handlers must be wrapped once; each LSP client's handlers must be wrapped
-- once per client (LspAttach fires per buffer×client).
local _globals_wrapped = false
local _wrapped_clients = {}

-- Function to filter diagnostics
local function filter_diagnostics(err, result, ctx, config, next_handler)
    if not result or not result.diagnostics then
        return next_handler(err, result, ctx, config)
    end

    local uri = result.uri
    local bufnr = vim.uri_to_bufnr(uri)

    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return next_handler(err, result, ctx, config)
    end

    if vim.bo[bufnr].filetype ~= "python" then
        return next_handler(err, result, ctx, config)
    end

    if not Config.options.suppress_magic_command_errors then
        return next_handler(err, result, ctx, config)
    end

    local filtered_diagnostics = {}
    for _, diagnostic in ipairs(result.diagnostics) do
        local keep = true

        -- Check all diagnostics regardless of severity
        local lnum = diagnostic.range.start.line
        local line = nil

        -- Try to get line from buffer
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
            line = lines[1]
        else
            -- Fallback: read from file if buffer not loaded
            -- This is expensive but necessary if diagnostics arrive before buffer load
            local filename = vim.api.nvim_buf_get_name(bufnr)
            if filename ~= "" then
                local lines = vim.fn.readfile(filename, "", lnum + 1)
                if #lines > lnum then
                    line = lines[lnum + 1]
                end
            end
        end

        if line then
            -- Check for magic commands
            -- 1. Start of line (e.g., !ls, %timeit)
            -- 2. Assignment (e.g., x = !ls, df = %sql)
            local is_magic = line:match("^%s*[!%%]") or line:match("=%s*[!%%]")

            if is_magic then
                keep = false
            end
        end

        if keep then
            table.insert(filtered_diagnostics, diagnostic)
        end
    end

    result.diagnostics = filtered_diagnostics
    return next_handler(err, result, ctx, config)
end

function M.setup()
    -- Re-entrant setup() must not re-wrap the global handlers (each wrap
    -- nests another filter layer).
    if _globals_wrapped then
        return
    end
    _globals_wrapped = true

    -- 1. Override global handler for Push Diagnostics
    local global_publish_handler = vim.lsp.handlers["textDocument/publishDiagnostics"]
    vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
        return filter_diagnostics(err, result, ctx, config, global_publish_handler)
    end

    -- 2. Override global handler for Pull Diagnostics (Neovim 0.10+)
    local global_pull_handler = vim.lsp.handlers["textDocument/diagnostic"]
    if global_pull_handler then
        vim.lsp.handlers["textDocument/diagnostic"] = function(err, result, ctx, config)
            -- Result structure is different for pull diagnostics
            if result and result.items then
                -- Wrap items in a structure compatible with filter_diagnostics or filter manually
                -- filter_diagnostics expects { diagnostics = ... }
                -- Let's adapt it.
                local adapter_result = { diagnostics = result.items, uri = ctx.params and ctx.params.textDocument.uri }
                -- We need to pass a custom next_handler that updates result.items
                local function next_adapter(e, r, c, cfg)
                    result.items = r.diagnostics
                    return global_pull_handler(e, result, c, cfg)
                end
                return filter_diagnostics(err, adapter_result, ctx, config, next_adapter)
            end
            return global_pull_handler(err, result, ctx, config)
        end
    end

    -- 3. Override per-client handlers (if they exist). LspAttach fires once
    -- per buffer×client, so guard per client id — otherwise each attached
    -- buffer wraps the same client's handlers again, nesting N deep.
    vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("JovianDiagnostics", { clear = true }),
        callback = function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if not client then
                return
            end
            if _wrapped_clients[client.id] then
                return
            end
            _wrapped_clients[client.id] = true

            -- Push
            local client_publish = client.handlers["textDocument/publishDiagnostics"]
            if client_publish then
                client.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
                    return filter_diagnostics(err, result, ctx, config, client_publish)
                end
            end

            -- Pull
            local client_pull = client.handlers["textDocument/diagnostic"]
            if client_pull then
                client.handlers["textDocument/diagnostic"] = function(err, result, ctx, config)
                    if result and result.items then
                        local adapter_result =
                            { diagnostics = result.items, uri = ctx.params and ctx.params.textDocument.uri }
                        local function next_adapter(e, r, c, cfg)
                            result.items = r.diagnostics
                            return client_pull(e, result, c, cfg)
                        end
                        return filter_diagnostics(err, adapter_result, ctx, config, next_adapter)
                    end
                    return client_pull(err, result, ctx, config)
                end
            end
        end,
    })
end

return M
