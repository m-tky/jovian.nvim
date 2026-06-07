-- plugin/jovian.lua — auto-setup safety net.
--
-- Lazy.nvim users typically call `require("jovian").setup{...}` from their
-- `config` hook and never see this file. For traditional plugin managers
-- (vim-plug / packer / pathogen / no-manager) that don't have a per-plugin
-- setup hook, we run setup() once on VimEnter with defaults so the user
-- gets working `:Jovian*` commands without extra boilerplate.
--
-- Idempotent: if the user already called setup() during startup, the flag
-- in init.lua short-circuits this call.

if vim.g.loaded_jovian == 1 then
    return
end
vim.g.loaded_jovian = 1

-- Native .ipynb editing: register BufReadCmd / BufWriteCmd so opening
-- a Jupyter notebook gives you the rendered `# %%`-style cell view in
-- the buffer, saving re-serializes back to nbformat. Registered at
-- plugin-load time (not VimEnter) so `nvim foo.ipynb` from the shell
-- triggers our handler immediately. The handler itself defers to
-- jovian-core; if the binary isn't installed it shows the raw JSON
-- with a notify and gets out of the way.
--
-- Set `vim.g.jovian_disable_ipynb_open = 1` before the plugin loads to
-- skip this — useful when you want to inspect the raw JSON, or when
-- another notebook plugin is handling .ipynb buffers.
if vim.g.jovian_disable_ipynb_open ~= 1 then
    pcall(function()
        require("jovian.ipynb_open").setup()
    end)
end

vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
        if vim.g.jovian_setup_done then
            return
        end
        local ok, err = pcall(function()
            require("jovian").setup()
        end)
        if not ok then
            vim.notify("jovian.nvim: auto-setup failed — " .. err, vim.log.levels.WARN)
        end
    end,
})
