-- Default keymap set. Off by default; the user opts in with
-- `default_keymaps = true` in setup(). All bindings are buffer-local
-- to filetype=python and use the <leader> prefix, except for cell
-- navigation which uses Vim's standard "next thing" bracket pairs.
--
-- We deliberately keep the binding set small. Every entry here is a
-- claim on the user's <leader> namespace; users who want a broader set
-- copy/paste from README's "Recommended Keybindings" section and tune
-- to taste.

local M = {}

function M.apply(bufnr)
    local opts = { buffer = bufnr, silent = true }
    local map = function(mode, lhs, rhs, desc)
        local o = vim.tbl_extend("force", opts, { desc = desc })
        vim.keymap.set(mode, lhs, rhs, o)
    end

    -- Execution
    map("n", "<leader>r", "<cmd>JovianRun<CR>", "Jovian: run cell")
    map("n", "<leader>x", "<cmd>JovianRunAndNext<CR>", "Jovian: run and next")
    map("n", "<leader>R", "<cmd>JovianRunAll<CR>", "Jovian: run all cells")
    map("v", "<leader>r", "<cmd>JovianSendSelection<CR>", "Jovian: run selection")

    -- UI
    map("n", "<leader>jo", "<cmd>JovianOpen<CR>", "Jovian: open panels")
    map("n", "<leader>jt", "<cmd>JovianToggle<CR>", "Jovian: toggle panels")
    map("n", "<leader>jv", "<cmd>JovianVars<CR>", "Jovian: variables")
    map("n", "<leader>je", ":JovianEval ", "Jovian: quick eval (cmdline)")

    -- Navigation
    map("n", "]c", "<cmd>JovianNextCell<CR>", "Jovian: next cell")
    map("n", "[c", "<cmd>JovianPrevCell<CR>", "Jovian: prev cell")
end

return M
