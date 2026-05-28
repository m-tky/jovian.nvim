-- Convert LaTeX math to a Unicode approximation, à la render-markdown.nvim but
-- self-contained (no external converter required). Handles Greek letters, the
-- common operators/relations/arrows, super/subscripts, \frac, \sqrt, \mathbb
-- and friends, and strips spacing/formatting macros. Best-effort: anything
-- unknown is passed through (backslash dropped), never errors.
--
-- An external converter (render-markdown's `utftex` / `latex2text`) can be
-- opted into via the `math.converter` config; the built-in is the default.

local M = {}

local Config = require("jovian.config")

-- stylua: ignore
local SUP = {
    ["0"]="⁰",["1"]="¹",["2"]="²",["3"]="³",["4"]="⁴",["5"]="⁵",["6"]="⁶",["7"]="⁷",["8"]="⁸",["9"]="⁹",
    ["+"]="⁺",["-"]="⁻",["="]="⁼",["("]="⁽",[")"]="⁾",["n"]="ⁿ",["i"]="ⁱ",
    a="ᵃ",b="ᵇ",c="ᶜ",d="ᵈ",e="ᵉ",f="ᶠ",g="ᵍ",h="ʰ",j="ʲ",k="ᵏ",l="ˡ",m="ᵐ",
    o="ᵒ",p="ᵖ",r="ʳ",s="ˢ",t="ᵗ",u="ᵘ",v="ᵛ",w="ʷ",x="ˣ",y="ʸ",z="ᶻ",
}
-- stylua: ignore
local SUB = {
    ["0"]="₀",["1"]="₁",["2"]="₂",["3"]="₃",["4"]="₄",["5"]="₅",["6"]="₆",["7"]="₇",["8"]="₈",["9"]="₉",
    ["+"]="₊",["-"]="₋",["="]="₌",["("]="₍",[")"]="₎",
    a="ₐ",e="ₑ",h="ₕ",i="ᵢ",j="ⱼ",k="ₖ",l="ₗ",m="ₘ",n="ₙ",o="ₒ",p="ₚ",r="ᵣ",s="ₛ",t="ₜ",u="ᵤ",v="ᵥ",x="ₓ",
}
-- stylua: ignore
local BB = { R="ℝ",N="ℕ",Z="ℤ",Q="ℚ",C="ℂ",H="ℍ",P="ℙ",E="𝔼",F="𝔽",D="𝔻",A="𝔸",B="𝔹" }
-- stylua: ignore
local SYMBOLS = {
    -- greek (lower)
    ["\\alpha"]="α",["\\beta"]="β",["\\gamma"]="γ",["\\delta"]="δ",["\\epsilon"]="ε",["\\varepsilon"]="ε",
    ["\\zeta"]="ζ",["\\eta"]="η",["\\theta"]="θ",["\\vartheta"]="ϑ",["\\iota"]="ι",["\\kappa"]="κ",
    ["\\lambda"]="λ",["\\mu"]="μ",["\\nu"]="ν",["\\xi"]="ξ",["\\pi"]="π",["\\varpi"]="ϖ",["\\rho"]="ρ",
    ["\\varrho"]="ϱ",["\\sigma"]="σ",["\\varsigma"]="ς",["\\tau"]="τ",["\\upsilon"]="υ",["\\phi"]="φ",
    ["\\varphi"]="ϕ",["\\chi"]="χ",["\\psi"]="ψ",["\\omega"]="ω",
    -- greek (upper)
    ["\\Gamma"]="Γ",["\\Delta"]="Δ",["\\Theta"]="Θ",["\\Lambda"]="Λ",["\\Xi"]="Ξ",["\\Pi"]="Π",
    ["\\Sigma"]="Σ",["\\Upsilon"]="Υ",["\\Phi"]="Φ",["\\Psi"]="Ψ",["\\Omega"]="Ω",
    -- big operators / operators
    ["\\sum"]="∑",["\\prod"]="∏",["\\coprod"]="∐",["\\int"]="∫",["\\iint"]="∬",["\\iiint"]="∭",
    ["\\oint"]="∮",["\\partial"]="∂",["\\nabla"]="∇",["\\infty"]="∞",["\\pm"]="±",["\\mp"]="∓",
    ["\\times"]="×",["\\div"]="÷",["\\cdot"]="⋅",["\\ast"]="∗",["\\star"]="⋆",["\\circ"]="∘",
    ["\\bullet"]="•",["\\oplus"]="⊕",["\\ominus"]="⊖",["\\otimes"]="⊗",["\\odot"]="⊙",["\\wedge"]="∧",
    ["\\vee"]="∨",["\\cap"]="∩",["\\cup"]="∪",["\\setminus"]="∖",["\\sqrt"]="√",
    -- relations
    ["\\leq"]="≤",["\\le"]="≤",["\\geq"]="≥",["\\ge"]="≥",["\\neq"]="≠",["\\ne"]="≠",["\\equiv"]="≡",
    ["\\approx"]="≈",["\\cong"]="≅",["\\simeq"]="≃",["\\sim"]="∼",["\\propto"]="∝",["\\ll"]="≪",
    ["\\gg"]="≫",["\\in"]="∈",["\\notin"]="∉",["\\ni"]="∋",["\\subset"]="⊂",["\\subseteq"]="⊆",
    ["\\supset"]="⊃",["\\supseteq"]="⊇",["\\forall"]="∀",["\\exists"]="∃",["\\nexists"]="∄",
    ["\\emptyset"]="∅",["\\varnothing"]="∅",["\\neg"]="¬",["\\lnot"]="¬",["\\land"]="∧",["\\lor"]="∨",
    -- arrows
    ["\\rightarrow"]="→",["\\to"]="→",["\\leftarrow"]="←",["\\gets"]="←",["\\leftrightarrow"]="↔",
    ["\\Rightarrow"]="⇒",["\\implies"]="⇒",["\\Leftarrow"]="⇐",["\\impliedby"]="⇐",["\\Leftrightarrow"]="⇔",
    ["\\iff"]="⇔",["\\mapsto"]="↦",["\\uparrow"]="↑",["\\downarrow"]="↓",["\\longrightarrow"]="⟶",
    ["\\longleftarrow"]="⟵",
    -- dots / misc
    ["\\dots"]="…",["\\ldots"]="…",["\\cdots"]="⋯",["\\vdots"]="⋮",["\\ddots"]="⋱",["\\prime"]="′",
    ["\\hbar"]="ℏ",["\\ell"]="ℓ",["\\Re"]="ℜ",["\\Im"]="ℑ",["\\aleph"]="ℵ",["\\wp"]="℘",["\\angle"]="∠",
    ["\\perp"]="⊥",["\\parallel"]="∥",["\\mid"]="∣",["\\nmid"]="∤",["\\dagger"]="†",["\\langle"]="⟨",
    ["\\rangle"]="⟩",["\\lceil"]="⌈",["\\rceil"]="⌉",["\\lfloor"]="⌊",["\\rfloor"]="⌋",["\\backslash"]="\\",
}

-- Macros that take one `{group}` and just unwrap it (style-only).
local UNWRAP = {
    mathrm = true,
    mathbf = true,
    mathit = true,
    mathsf = true,
    mathtt = true,
    mathcal = true,
    boldsymbol = true,
    text = true,
    textbf = true,
    textit = true,
    operatorname = true,
}

local conv -- forward declaration (recursive)

-- Read a `{...}` balanced group at position i, or a single char. Returns the
-- group content and the index just past it.
local function read_group(s, i)
    if s:sub(i, i) == "{" then
        local depth, j = 0, i
        while j <= #s do
            local c = s:sub(j, j)
            if c == "{" then
                depth = depth + 1
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then
                    return s:sub(i + 1, j - 1), j + 1
                end
            end
            j = j + 1
        end
        return s:sub(i + 1), #s + 1
    end
    -- a `\macro` token (e.g. `^\infty`, `\frac\alpha\beta`)
    if s:sub(i, i) == "\\" then
        local name = s:match("^\\([a-zA-Z]+)", i)
        if name then
            return s:sub(i, i + #name), i + 1 + #name
        end
    end
    return s:sub(i, i), i + 1
end

-- Map a converted group to super/subscript chars; fall back to ^(...) / _(...)
-- when any character has no Unicode form.
local function scriptify(group, is_sup)
    local converted = conv(group)
    local map = is_sup and SUP or SUB
    local out = {}
    for _, c in ipairs(vim.fn.split(converted, "\\zs")) do
        local m = map[c]
        if not m then
            return (is_sup and "^(" or "_(") .. converted .. ")"
        end
        out[#out + 1] = m
    end
    return table.concat(out)
end

conv = function(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local ch = s:sub(i, i)
        if ch == "\\" then
            local name = s:match("^\\([a-zA-Z]+)", i)
            if name then
                i = i + 1 + #name
                if name == "frac" or name == "dfrac" or name == "tfrac" then
                    local a, j = read_group(s, i)
                    local b, k = read_group(s, (s:match("^%s*()", j)))
                    out[#out + 1] = "(" .. conv(a) .. ")/(" .. conv(b) .. ")"
                    i = k
                elseif name == "sqrt" then
                    local idx = i
                    local root = nil
                    if s:sub(idx, idx) == "[" then
                        local close = s:find("]", idx, true)
                        if close then
                            root = s:sub(idx + 1, close - 1)
                            idx = close + 1
                        end
                    end
                    local x, k = read_group(s, idx)
                    out[#out + 1] = (root and scriptify(root, true) or "") .. "√(" .. conv(x) .. ")"
                    i = k
                elseif name == "mathbb" then
                    local g, k = read_group(s, i)
                    i = k
                    if #g == 1 and BB[g] then
                        out[#out + 1] = BB[g]
                    else
                        out[#out + 1] = conv(g)
                    end
                elseif UNWRAP[name] then
                    local g, k = read_group(s, i)
                    i = k
                    out[#out + 1] = conv(g)
                elseif name == "left" or name == "right" then
                    out[#out + 1] = "" -- drop; the following delimiter renders normally
                elseif name == "quad" or name == "qquad" then
                    out[#out + 1] = " "
                elseif SYMBOLS["\\" .. name] then
                    out[#out + 1] = SYMBOLS["\\" .. name]
                else
                    out[#out + 1] = name -- unknown macro: drop the backslash
                end
            else
                local nxt = s:sub(i + 1, i + 1)
                if nxt == "," or nxt == ";" or nxt == ":" or nxt == "!" or nxt == " " then
                    i = i + 2 -- spacing macro, drop
                else
                    out[#out + 1] = nxt -- \{ \} \( \) \% ... → the literal char
                    i = i + 2
                end
            end
        elseif ch == "^" or ch == "_" then
            local grp, k = read_group(s, i + 1)
            out[#out + 1] = scriptify(grp, ch == "^")
            i = k
        elseif ch == "{" or ch == "}" then
            i = i + 1 -- drop stray braces
        else
            out[#out + 1] = ch
            i = i + 1
        end
    end
    return table.concat(out)
end

--- Built-in LaTeX → Unicode conversion. Never errors.
function M.to_unicode(latex)
    local ok, res = pcall(conv, latex or "")
    if not ok then
        return latex or ""
    end
    return vim.trim((res:gsub("%s+", " ")))
end

local _cache = {}

--- Convert a formula, using an external `math.converter` (render-markdown's
--- `utftex` / `latex2text`) when configured & available, else the built-in.
function M.convert(latex)
    if _cache[latex] then
        return _cache[latex]
    end
    local result
    local cfg = (Config.options.math or {}).converter
    if cfg then
        local cmds = type(cfg) == "table" and cfg or { cfg }
        for _, cmd in ipairs(cmds) do
            if vim.fn.executable(cmd) == 1 then
                local out = vim.fn.system({ cmd }, latex)
                if vim.v.shell_error == 0 and out and vim.trim(out) ~= "" then
                    result = vim.trim(out)
                    break
                end
            end
        end
    end
    result = result or M.to_unicode(latex)
    _cache[latex] = result
    return result
end

return M
