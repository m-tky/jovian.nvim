local M = {}

function M.setup()
    local Config = require("jovian.config")
    local float_bg = Config.options.ui.transparent_float and "Normal" or "NormalFloat"

    local groups = {
        -- Floating Window Background & Border
        JovianFloat = { link = float_bg, default = true },
        JovianFloatBorder = { link = "FloatBorder", default = true },

        -- UI Elements
        JovianHeader = { link = "Title", default = true },
        JovianCellMarker = { link = "Visual", default = true },
        JovianSeparator = { link = "Comment", default = true },
        JovianComment = { link = "Comment", default = true },
        
        -- Variables Pane
        JovianVariable = { link = "Function", default = true },
        JovianType = { link = "Type", default = true },
        JovianValue = { link = "Normal", default = true }, -- Default text

        -- DataFrame View
        JovianIndex = { link = "Statement", default = true },
    }

    for name, opts in pairs(groups) do
        vim.api.nvim_set_hl(0, name, opts)
    end
end

return M
