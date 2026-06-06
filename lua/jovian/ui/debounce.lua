-- Per-buffer trailing-edge debounce for UI renderers.
--
-- The shape `M.schedule(bufnr, ...) → eventually call render(bufnr, ...)` was
-- duplicated almost verbatim across cell_frame.lua and markdown_cell.lua: each
-- one carried its own `_timers = {}` table, its own uv.new_timer dance, and
-- its own buf-valid + close+nil cleanup. This module centralises the pattern.
--
-- TRAILING vs LEADING: trailing-edge fires once at the END of a burst, at the
-- final geometry/state. A leading-edge guard (`_pending = true`; ignore later
-- calls) renders at the FIRST event's state, which during a window-resize
-- drag is the intermediate width — visibly wrong. Don't switch this without
-- replaying the resize/CursorMoved scenarios the old behaviour broke on.

local M = {}

local uv = vim.uv or vim.loop

-- Module-wide registry of every pending-timer table created by M.make,
-- consulted by a single BufWipeout autocmd that nukes any pending timers
-- for a bufnr that goes away. Without this, a timer scheduled against
-- buf 42 outlives the buffer; when the timer fires we close it (the
-- buf-valid check handles that), but a fresh schedule() in the same
-- bufnr slot during the window can stop the wrong timer or fire
-- against a recycled buffer.
local all_timer_tables = {}

vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    pattern = "*",
    callback = function(ev)
        for _, timers in ipairs(all_timer_tables) do
            local t = timers[ev.buf]
            if t then
                pcall(t.stop, t)
                pcall(t.close, t)
                timers[ev.buf] = nil
            end
        end
    end,
})

-- Build a scheduler for `render_fn`. The returned `schedule(bufnr, ...)` can
-- be called as often as the caller likes; only the final call in any 60 ms
-- window actually invokes render. The extra args are captured AT FIRE TIME
-- (so e.g. winid can be re-resolved against current geometry — important
-- when textoff shifts after a resize).
--
-- @param render_fn function(bufnr, ...) the render to debounce
-- @param opts.delay number ms, defaults to 60
-- @param opts.resolve function(bufnr, ...) → (...new args) optional hook to
--        rewrite the captured args at fire time. Receives the args the caller
--        passed to `schedule`; returns the args to forward to `render_fn`.
function M.make(render_fn, opts)
    opts = opts or {}
    local delay = opts.delay or 60
    local resolve = opts.resolve
    local timers = {}
    table.insert(all_timer_tables, timers)

    return function(bufnr, ...)
        bufnr = bufnr or vim.api.nvim_get_current_buf()
        local captured = { ... }
        local t = timers[bufnr]
        if t then
            t:stop()
        else
            t = uv.new_timer()
            timers[bufnr] = t
        end
        t:start(
            delay,
            0,
            vim.schedule_wrap(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    if timers[bufnr] then
                        timers[bufnr]:close()
                        timers[bufnr] = nil
                    end
                    return
                end
                if resolve then
                    render_fn(bufnr, resolve(bufnr, unpack(captured)))
                else
                    render_fn(bufnr, unpack(captured))
                end
                if timers[bufnr] then
                    timers[bufnr]:close()
                    timers[bufnr] = nil
                end
            end)
        )
    end
end

return M
