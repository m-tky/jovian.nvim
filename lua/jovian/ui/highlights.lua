-- Shared highlight helpers used by every UI module that picks colors from the
-- active colorscheme. Previously each of cell_frame.lua / markdown_cell.lua /
-- output_render.lua carried its own near-identical copy, drifting whenever one
-- of them got a fix.

local M = {}

-- vim.fn.strdisplaywidth shorthand. Same function call, just shorter at the
-- call sites — every renderer needs the display width of strings with CJK /
-- emoji / box-drawing chars.
function M.dw(s)
    return vim.fn.strdisplaywidth(s)
end

-- `nvim_get_hl(..., { link = false })` resolves links and returns the actual
-- attrs. A group that exists but has no visible attrs (empty table) is treated
-- as "not really defined" — Treesitter/colorscheme groups often exist as empty
-- placeholders and shouldn't satisfy the fallback chain.
function M.group_has_styling(name)
    local h = vim.api.nvim_get_hl(0, { name = name, link = false })
    if not h then
        return false
    end
    return h.fg ~= nil or h.bg ~= nil or h.bold or h.italic or h.underline
end

-- Walk a fallback chain and return the first group the colorscheme actually
-- styles. If nothing matches, returns the last candidate (so the caller still
-- gets *something* to link to rather than a nil error).
function M.pick_existing(candidates)
    for _, name in ipairs(candidates) do
        if M.group_has_styling(name) then
            return name
        end
    end
    return candidates[#candidates]
end

-- Apply a user-config value to a highlight group. The value may be:
--   string → treat as `:hi link` target
--   table  → forwarded as `nvim_set_hl` attrs
--   nil    → use the supplied fallback (string link or table of attrs)
-- nil-fallback is also tolerated — we simply skip the assignment so the
-- existing colorscheme group wins.
function M.apply(target, user_val, fallback)
    local val = user_val
    if val == nil then
        val = fallback
    end
    if val == nil then
        return
    end
    if type(val) == "string" then
        vim.api.nvim_set_hl(0, target, { link = val, force = true })
    elseif type(val) == "table" then
        local attrs = vim.deepcopy(val)
        attrs.force = true
        vim.api.nvim_set_hl(0, target, attrs)
    end
end

return M
