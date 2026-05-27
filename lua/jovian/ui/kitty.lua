-- Kitty graphics protocol: Unicode placeholder mode (a=t, U=1).
--
-- Strategy:
--   1. Transmit PNG bytes once via jovian-core's `kitty_transmit` RPC. The
--      Rust side writes the escape sequence directly to /dev/tty, bypassing
--      Neovim's TUI redraw and tmux multiplexing. The RPC replies with an
--      image_id.
--   2. Build placeholder text with U+10EEEE + row/column diacritics. The
--      placeholder lines go into a virt_lines extmark.
--   3. The placeholder's foreground colour ENCODES the image_id as a 24-bit
--      RGB value, so kitty/ghostty knows which transmitted image to draw
--      where. We create one highlight group per image_id at first use.
--
-- Reference: https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders

local M = {}

local Core = require("jovian.backend.core")

-- The 297 placeholder row/column diacritics. Source: kitty's
-- placeholder_diacritics array (data-types.h).
local DIACRITICS = {
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A,
    0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365,
    0x0366, 0x0367, 0x0368, 0x0369, 0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F,
    0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
    0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1, 0x05A8, 0x05A9,
    0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
    0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6,
    0x06D7, 0x06D8, 0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
    0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736,
    0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743, 0x0745, 0x0747, 0x0749, 0x074A,
    0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817,
    0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x0823, 0x0825, 0x0826, 0x0827,
    0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951, 0x0953, 0x0954, 0x0F82, 0x0F83,
    0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
    0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F,
    0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1, 0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0,
    0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4, 0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB,
    0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9,
    0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1, 0x1DE2, 0x1DE3,
    0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1, 0x20D4, 0x20D5, 0x20D6, 0x20D7,
    0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0,
    0x2DE1, 0x2DE2, 0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA,
    0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4,
    0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA, 0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE,
    0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3,
    0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
    0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7, 0xAAB8, 0xAABE,
    0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23, 0xFE24, 0xFE25, 0xFE26, 0x10A0F,
    0x10A38, 0x1D185, 0x1D186, 0x1D187, 0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC,
    0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
}

local PLACEHOLDER = 0x10EEEE

local function utf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + (cp % 0x40)
        )
    else
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + (cp % 0x40)
        )
    end
end

-- Encode the image_id as a 24-bit RGB foreground color in a dedicated
-- highlight group. Avoid pure black so Kitty doesn't treat the cell as
-- "no image id assigned".
local _hl_cache = {}
local function ensure_image_hl(image_id)
    local cached = _hl_cache[image_id]
    if cached then return cached end
    local r = bit.band(bit.rshift(image_id, 16), 0xff)
    local g = bit.band(bit.rshift(image_id, 8), 0xff)
    local b = bit.band(image_id, 0xff)
    if r == 0 and g == 0 and b == 0 then b = 1 end
    local hl = "JovianKittyImg_" .. image_id
    vim.api.nvim_set_hl(0, hl, { fg = string.format("#%02x%02x%02x", r, g, b) })
    _hl_cache[image_id] = hl
    return hl
end

local function row_chunk(image_id, row, cols, hl)
    local row_d = utf8(DIACRITICS[row + 1] or DIACRITICS[1])
    local placeholder = utf8(PLACEHOLDER) .. row_d
    local chunks = {}
    for c = 0, cols - 1 do
        local col_d = utf8(DIACRITICS[c + 1] or DIACRITICS[1])
        table.insert(chunks, { placeholder .. col_d, hl })
    end
    return chunks
end

--- Build the virt_lines structure for a `rows × cols` placement of an image.
--- Each row is a list of chunks. Caller embeds this in `virt_lines` of an
--- extmark; Kitty/Ghostty replaces the placeholders with the actual image
--- at render time.
function M.build_virt_lines(image_id, rows, cols)
    local hl = ensure_image_hl(image_id)
    local out = {}
    for r = 0, rows - 1 do
        table.insert(out, row_chunk(image_id, r, cols, hl))
    end
    return out
end

-- ---------- Async transmission ----------
--
-- We hash the base64 payload (cheap djb2 over a stride) to detect duplicate
-- images across cell reruns; transmitting the same PNG twice would waste
-- bandwidth and burn through image_ids in the terminal.

local function quick_hash(s)
    if not s or s == "" then return "0:0" end
    local n = #s
    local h = 5381
    local step = math.max(1, math.floor(n / 64))
    for i = 1, n, step do
        h = (h * 33 + s:byte(i)) % 0x7FFFFFFF
    end
    return h .. ":" .. n
end

-- Cache: hash → image_id (transmitted), or "pending" for in-flight requests.
local _transmits = {}
-- Per-hash: list of callbacks to fire when the image_id arrives.
local _pending_cbs = {}

--- Ensure a base64 PNG is transmitted to the terminal. Returns the image_id
--- synchronously if cached, otherwise nil; in the not-cached case `cb` is
--- invoked (vim.schedule'd) once the transmission completes.
function M.ensure_transmitted(b64, cb)
    if not b64 or b64 == "" then return nil end
    local key = quick_hash(b64)
    local entry = _transmits[key]
    if type(entry) == "number" then
        return entry
    end
    if entry == "pending" then
        if cb then
            table.insert(_pending_cbs[key], cb)
        end
        return nil
    end

    _transmits[key] = "pending"
    _pending_cbs[key] = cb and { cb } or {}

    -- Ensure the core is spawned (which kicks off kitty_attach if it
    -- hasn't already) and wait for the attach to settle before we send
    -- kitty_transmit. The Rust side dispatches RPC requests via
    -- tokio::spawn so they run in parallel; without this gate transmit
    -- can land first and return "kitty_attach not called".
    local client = Core.client() or Core.ensure()
    Core.on_kitty_ready(function(ok, attach_err)
        if not ok then
            _transmits[key] = nil
            local cbs = _pending_cbs[key] or {}
            _pending_cbs[key] = nil
            for _, c in ipairs(cbs) do pcall(c, nil) end
            -- The user already saw the kitty_attach failure notification
            -- from core.lua; don't double-notify here.
            return
        end
        client:request("kitty_transmit", { png_b64 = b64 }, function(err, result)
            if err or not result or not result.image_id then
                _transmits[key] = nil
                if err and not M._warned then
                    M._warned = true
                    vim.schedule(function()
                        vim.notify(
                            "jovian: kitty_transmit failed (" .. err .. "). "
                            .. "Inline images will not render until this is fixed. "
                            .. "Run `:checkhealth jovian` to diagnose.",
                            vim.log.levels.WARN
                        )
                    end)
                end
                local cbs = _pending_cbs[key] or {}
                _pending_cbs[key] = nil
                for _, c in ipairs(cbs) do pcall(c, nil) end
                return
            end
            local id = result.image_id
            _transmits[key] = id
            local cbs = _pending_cbs[key] or {}
            _pending_cbs[key] = nil
            for _, c in ipairs(cbs) do pcall(c, id) end
        end)
    end)
    return nil
end

--- Drop all caches. Used by tests; production callers shouldn't need this
--- since image_ids stay valid for the kernel's lifetime.
function M._reset()
    _transmits = {}
    _pending_cbs = {}
    _hl_cache = {}
end

M._DIACRITICS_LEN = #DIACRITICS

return M
