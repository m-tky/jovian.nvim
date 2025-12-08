local M = {}

M.python_injections = [[
; extends

((comment) @injection.content
 (#match? @injection.content "^# ")
 (#set! injection.language "markdown")
 (#offset! @injection.content 0 2 0 0))
]]

M.python_highlights = [[
;; extends

;; Highlight the ERROR node itself if it looks like a magic command
(ERROR
  (type_conversion) @magic_start
  (#match? @magic_start "^[!]|^[%]")
  (#set! "priority" 105)
) @function.macro

;; Fallback for magic commands not parsed as type_conversion (e.g. %magic)
(ERROR
  (#match? @function.macro "^[%]")
  (#set! "priority" 105)
) @function.macro

;; Highlight the first following sibling on the same line
(_
  (ERROR
    (type_conversion) @magic_start
    (#match? @magic_start "^[!]|^[%]")
  )
  (expression_statement) @function.macro
  (#same-line? @magic_start @function.macro)
  (#set! "priority" 105)
)

;; Highlight the second following sibling on the same line (best effort for longer commands)
(_
  (ERROR
    (type_conversion) @magic_start
    (#match? @magic_start "^[!]|^[%]")
  )
  (expression_statement) @mid
  (#same-line? @magic_start @mid)
  (expression_statement) @function.macro
  (#same-line? @magic_start @function.macro)
  (#set! "priority" 105)
)
]]

return M
