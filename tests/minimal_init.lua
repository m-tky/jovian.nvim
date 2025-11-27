local function add_rtp(path)
    vim.opt.rtp:append(path)
end

add_rtp(".tests/plenary.nvim")
add_rtp(".")

vim.cmd("runtime plugin/plenary.vim")
