-- HTML in markdown cells, drawn as styled text and images.
--
-- Jupyter renders raw HTML inside markdown cells (course banners, layout
-- tables, <img> tags, colored <span>s). A terminal cannot lay out a web page,
-- so this is a small, forgiving subset: headings, paragraphs, line breaks,
-- lists, blockquotes, <pre>, <hr>, tables (side-by-side cells, an image cell
-- next to a text cell), images (through the caller's resolver), inline bold /
-- italic / underline / strike / code / links and CSS or <font> colors.
-- Everything else falls back to its text.
--
-- Nothing here touches the buffer: markdown.lua hides the HTML lines and hangs
-- what layout() returns under them, so the cell source (and the .ipynb) stays
-- exactly as written, and editing the cell shows the real HTML.

local M = {}

local function set(list)
  local t = {}
  for _, v in ipairs(list) do t[v] = true end
  return t
end

local VOID = set({ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
  "param", "source", "track", "wbr", "basefont", "frame", "keygen" })
local SKIP = set({ "script", "style", "head", "title", "meta", "link", "template", "base",
  "noscript", "iframe", "object", "embed", "svg", "math", "canvas", "map", "area", "audio",
  "video", "source", "track", "input", "button", "select", "textarea", "colgroup", "col" })
local BLOCK = set({ "address", "article", "aside", "blockquote", "body", "caption", "center",
  "dd", "details", "dialog", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer",
  "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "html", "li", "main", "nav",
  "ol", "p", "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
  "tr", "ul", "menu", "legend", "search" })
-- CommonMark HTML block start condition 6
local BLOCK_START = set({ "address", "article", "aside", "base", "basefont", "blockquote",
  "body", "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div",
  "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1",
  "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li",
  "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p",
  "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
  "title", "tr", "track", "ul" })
-- CommonMark HTML block start condition 1 (ends at the matching close tag)
local RAW_START = set({ "script", "pre", "style", "textarea" })
-- blocks with a blank line around them
local MARGIN = set({ "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "pre",
  "blockquote", "hr", "figure", "dl", "details", "fieldset" })
-- tags concealed when they appear inline in a markdown line
local INLINE_KNOWN = set({ "a", "abbr", "b", "bdi", "bdo", "big", "br", "cite", "code", "data",
  "del", "dfn", "em", "font", "i", "img", "ins", "kbd", "mark", "q", "s", "samp", "small",
  "span", "strike", "strong", "sub", "sup", "time", "tt", "u", "var", "wbr", "picture",
  "label", "nobr" })
for k in pairs(BLOCK_START) do INLINE_KNOWN[k] = true end

M.VOID, M.SKIP, M.BLOCK = VOID, SKIP, BLOCK

-- ---------------------------------------------------------------- text ----

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local ENT = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160",
  ndash = "–", mdash = "—", hellip = "…", copy = "©", reg = "®", trade = "™",
  laquo = "«", raquo = "»", lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”",
  bull = "•", middot = "·", rarr = "→", larr = "←", uarr = "↑", darr = "↓",
  harr = "↔", rArr = "⇒", lArr = "⇐", times = "×", divide = "÷", deg = "°",
  plusmn = "±", micro = "µ", para = "¶", sect = "§", euro = "€", pound = "£",
  yen = "¥", cent = "¢", ensp = " ", emsp = " ", thinsp = " ", zwj = "", zwnj = "",
  shy = "", check = "✓", cross = "✗", star = "☆", hearts = "♥", le = "≤", ge = "≥",
  ne = "≠", asymp = "≈", infin = "∞", larrow = "←", rarrow = "→",
}

function M.decode(s)
  if type(s) ~= "string" or not s:find("&", 1, true) then return s end
  return (s:gsub("&(#?)([xX]?)([%w]+);", function(hash, x, name)
    if hash == "#" then
      local n = tonumber(name, x ~= "" and 16 or 10)
      if n and n > 0 and n < 0x110000 then return utf8_char(n) end
      return nil
    end
    return ENT[x .. name]
  end))
end

local function strw(s) return vim.api.nvim_strwidth(s) end

-- utf8 characters of s
local function chars(s)
  return s:gmatch("[%z\1-\127\194-\244][\128-\191]*")
end

-- ------------------------------------------------------------- parsing ----

-- Parse a tag starting at s[a] == "<". Returns the tag and the index of its
-- closing ">", or nil when this "<" does not start a tag.
local function parse_tag(s, a)
  local close, name, p = s:match("^<(/?)([%a][%w:-]*)()", a)
  if not name then return nil end
  local nxt = s:sub(p, p)
  if nxt ~= "" and not nxt:match("[%s/>]") then return nil end
  local n = #s
  local attrs, selfclose = {}, false
  local j = p
  while j <= n do
    local c = s:sub(j, j)
    if c == ">" then
      return { name = name:lower(), close = close == "/", attrs = attrs, selfclose = selfclose }, j
    elseif c == "/" then
      selfclose = true
      j = j + 1
    elseif c:match("%s") then
      j = j + 1
    else
      local an, q = s:match("^([^%s=/>]+)()", j)
      if not an then return nil end
      j = q
      local k = s:match("^%s*=%s*()", j)
      local val = ""
      if k then
        local qc = s:sub(k, k)
        if qc == '"' or qc == "'" then
          local e = s:find(qc, k + 1, true)
          if not e then return nil end
          val = s:sub(k + 1, e - 1)
          j = e + 1
        else
          local v, e = s:match("^([^%s>]+)()", k)
          val = v or ""
          j = e or k
        end
      end
      attrs[an:lower()] = M.decode(val)
      selfclose = false
    end
  end
  return nil
end
M._parse_tag = parse_tag

-- Tokens: { text = "..." } or a tag table.
function M.tokenize(s)
  local toks = {}
  local i, n = 1, #s
  while i <= n do
    local lt = s:find("<", i, true)
    if not lt then
      toks[#toks + 1] = { text = s:sub(i) }
      break
    end
    if lt > i then toks[#toks + 1] = { text = s:sub(i, lt - 1) } end
    if s:sub(lt, lt + 3) == "<!--" then
      local e = s:find("-->", lt + 4, true)
      i = e and e + 3 or n + 1
    elseif s:match("^<[!?]", lt) then
      local e = s:find(">", lt, true)
      i = e and e + 1 or n + 1
    else
      local tag, e = parse_tag(s, lt)
      if tag then
        toks[#toks + 1] = tag
        i = e + 1
        -- raw text elements: everything up to the close tag is text
        if not tag.close and (tag.name == "script" or tag.name == "style" or tag.name == "textarea") then
          local cs = s:lower():find("</" .. tag.name, i, true)
          local stop = cs or (n + 1)
          if stop > i then toks[#toks + 1] = { text = s:sub(i, stop - 1) } end
          i = stop
        end
      else
        toks[#toks + 1] = { text = "<" }
        i = lt + 1
      end
    end
  end
  return toks
end

-- elements that close an open sibling of these names when they start
local AUTOCLOSE = {
  li = set({ "li" }), dt = set({ "dt", "dd" }), dd = set({ "dt", "dd" }),
  td = set({ "td", "th" }), th = set({ "td", "th" }), tr = set({ "tr", "td", "th" }),
  tbody = set({ "tbody", "thead", "tfoot", "tr", "td", "th" }),
  thead = set({ "tbody", "thead", "tfoot", "tr", "td", "th" }),
  tfoot = set({ "tbody", "thead", "tfoot", "tr", "td", "th" }),
  option = set({ "option" }),
}
local P_CLOSERS = set({ "address", "article", "aside", "blockquote", "details", "div", "dl",
  "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
  "header", "hr", "main", "menu", "nav", "ol", "p", "pre", "section", "table", "ul" })

-- A forgiving tree: { name, attrs, children } with { text } leaves.
function M.parse(s)
  local root = { name = "#root", attrs = {}, children = {} }
  local stack = { root }
  for _, t in ipairs(M.tokenize(s)) do
    local top = stack[#stack]
    if t.text then
      top.children[#top.children + 1] = { text = t.text }
    elseif t.close then
      for k = #stack, 2, -1 do
        if stack[k].name == t.name then
          for _ = #stack, k, -1 do table.remove(stack) end
          break
        end
        -- a close tag never reaches past the table a cell belongs to
        if stack[k].name == "table" then break end
      end
    else
      local ac = AUTOCLOSE[t.name]
      if ac then
        while #stack > 1 and ac[stack[#stack].name] do table.remove(stack) end
      end
      if P_CLOSERS[t.name] and stack[#stack].name == "p" then table.remove(stack) end
      top = stack[#stack]
      local node = { name = t.name, attrs = t.attrs, children = {} }
      top.children[#top.children + 1] = node
      if not VOID[t.name] and not t.selfclose then stack[#stack + 1] = node end
    end
  end
  return root
end

-- -------------------------------------------------------------- style ----

local function parse_css(s)
  local t = {}
  if type(s) ~= "string" then return t end
  for k, v in s:gmatch("([%w-]+)%s*:%s*([^;]+)") do
    t[k:lower()] = vim.trim(v:gsub("%s*!important", "")):lower()
  end
  return t
end
M._parse_css = parse_css

local NAMED = {
  black = "#000000", white = "#ffffff", red = "#ff0000", green = "#008000", blue = "#0000ff",
  yellow = "#ffff00", orange = "#ffa500", purple = "#800080", gray = "#808080",
  grey = "#808080", silver = "#c0c0c0", maroon = "#800000", navy = "#000080",
  teal = "#008080", olive = "#808000", lime = "#00ff00", aqua = "#00ffff", cyan = "#00ffff",
  fuchsia = "#ff00ff", magenta = "#ff00ff", darkred = "#8b0000", darkgreen = "#006400",
  darkblue = "#00008b", darkorange = "#ff8c00", crimson = "#dc143c", gold = "#ffd700",
  pink = "#ffc0cb", brown = "#a52a2a", steelblue = "#4682b4", royalblue = "#4169e1",
  dodgerblue = "#1e90ff", tomato = "#ff6347", coral = "#ff7f50", indigo = "#4b0082",
  violet = "#ee82ee", salmon = "#fa8072", lightgray = "#d3d3d3", lightgrey = "#d3d3d3",
  darkgray = "#a9a9a9", darkgrey = "#a9a9a9", orangered = "#ff4500", seagreen = "#2e8b57",
  forestgreen = "#228b22", limegreen = "#32cd32", skyblue = "#87ceeb", slategray = "#708090",
  firebrick = "#b22222", chocolate = "#d2691e", goldenrod = "#daa520", hotpink = "#ff69b4",
  deeppink = "#ff1493", turquoise = "#40e0d0", darkviolet = "#9400d3", tan = "#d2b48c",
}

function M.parse_color(v)
  if type(v) ~= "string" then return nil end
  v = vim.trim(v):lower()
  local hex = v:match("^#(%x+)$")
  if hex then
    if #hex == 3 or #hex == 4 then
      hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
    elseif #hex == 6 or #hex == 8 then
      hex = hex:sub(1, 6)
    else
      return nil
    end
    return "#" .. hex
  end
  local r, g, b = v:match("^rgba?%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
  if r then
    local c = function(x) return math.max(0, math.min(255, tonumber(x))) end
    return string.format("#%02x%02x%02x", c(r), c(g), c(b))
  end
  return NAMED[v]
end

local function rgb(hex)
  return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end
local function lum(hex)
  local function ch(x)
    x = x / 255
    return x <= 0.03928 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4
  end
  local r, g, b = rgb(hex)
  return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
end
local function contrast(a, b)
  local la, lb = lum(a), lum(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end

local function background()
  local ok, n = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  if ok and n and n.bg then return string.format("#%06x", n.bg) end
  return vim.o.background == "light" and "#ffffff" or "#000000"
end

-- A color an author picked for a white page, nudged until it reads on this
-- background (a dark red on black, black text on a dark theme).
function M.readable(hex, bg)
  bg = bg or background()
  local target = lum(bg) < 0.5 and "#ffffff" or "#000000"
  local tr, tg, tb = rgb(target)
  for _ = 1, 20 do
    if contrast(hex, bg) >= 3.5 then return hex end
    local r, g, b = rgb(hex)
    hex = string.format("#%02x%02x%02x", math.floor(r + (tr - r) * 0.12 + 0.5),
      math.floor(g + (tg - g) * 0.12 + 0.5), math.floor(b + (tb - b) * 0.12 + 0.5))
  end
  return hex
end

local hl_cache = {}
local layout_cache, layout_cache_n = {}, 0
local augroup = vim.api.nvim_create_augroup("JupynvimHtml", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = augroup,
  -- :hi clear wiped the composed groups; cached layouts still name them
  callback = function() hl_cache, layout_cache, layout_cache_n = {}, {}, 0 end,
})

-- The highlight group for a text style.
function M.hl_for(st)
  local base
  if st.code then base = "JupynvimMdCode"
  elseif st.link then base = "JupynvimMdLink"
  elseif st.heading then base = "JupynvimMdH" .. st.heading
  end
  if not (st.bold or st.italic or st.underline or st.strike or st.color) then
    return base or "Normal"
  end
  local name = "JupynvimHtml_" .. (base or "N"):gsub("^JupynvimMd", "") .. "_"
    .. (st.bold and "b" or "") .. (st.italic and "i" or "") .. (st.underline and "u" or "")
    .. (st.strike and "s" or "") .. (st.color and st.color:sub(2) or "")
  if not hl_cache[name] then
    local ok, attrs = pcall(vim.api.nvim_get_hl, 0, { name = base or "Normal", link = false })
    if not ok or type(attrs) ~= "table" then attrs = {} end
    local def = {
      fg = attrs.fg, sp = attrs.sp,
      bold = attrs.bold or st.bold or nil,
      italic = attrs.italic or st.italic or nil,
      underline = attrs.underline or st.underline or nil,
      strikethrough = attrs.strikethrough or st.strike or nil,
    }
    if st.color then def.fg = M.readable(st.color) end
    vim.api.nvim_set_hl(0, name, def)
    hl_cache[name] = true
  end
  return name
end

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- The style inside `node`, given the style around it.
function M.derive(st, node)
  local n, a = node.name, node.attrs or {}
  local s = copy(st)  -- color, align and the rest are inherited
  s.valign = nil      -- vertical-align is not
  if n == "b" or n == "strong" or n == "th" or n == "dt" or n == "mark" or n == "summary" then
    s.bold = true
  elseif n == "i" or n == "em" or n == "cite" or n == "var" or n == "dfn" or n == "q" then
    s.italic = true
  elseif n == "u" or n == "ins" then
    s.underline = true
  elseif n == "s" or n == "del" or n == "strike" then
    s.strike = true
  elseif n == "code" or n == "kbd" or n == "tt" or n == "samp" then
    s.code = true
  elseif n == "a" and a.href then
    s.link = true
  elseif n == "pre" then
    s.pre, s.code = true, true
  elseif n:match("^h[1-6]$") then
    s.heading, s.bold = tonumber(n:sub(2)), true
  elseif n == "font" and a.color then
    s.color = M.parse_color(a.color) or s.color
  elseif n == "center" then
    s.align = "center"
  end
  local css = parse_css(a.style)
  if css.color then s.color = M.parse_color(css.color) or s.color end
  local fw = css["font-weight"]
  if fw then
    if fw == "bold" or fw == "bolder" or (tonumber(fw) or 0) >= 600 then s.bold = true
    elseif fw == "normal" or fw == "lighter" or (tonumber(fw) or 1000) < 600 then s.bold = nil end
  end
  if css["font-style"] == "italic" or css["font-style"] == "oblique" then s.italic = true end
  local td = css["text-decoration"] or css["text-decoration-line"]
  if td then
    if td:find("underline", 1, true) then s.underline = true end
    if td:find("line-through", 1, true) then s.strike = true end
  end
  if css.display == "none" or css.visibility == "hidden" or a.hidden then s.hidden = true end
  local al = css["text-align"] or (a.align and a.align:lower())
  if al == "center" or al == "left" or al == "right" then s.align = al end
  local va = css["vertical-align"] or (a.valign and a.valign:lower())
  if va == "top" or va == "middle" or va == "bottom" then s.valign = va end
  return s
end

-- ------------------------------------------------------------- layout ----

-- A line: { segs = { {t=, hl=} | {img=ref, row=} }, w = display width }
local function new_line() return { segs = {}, w = 0 } end

local function push_text(line, text, hl)
  if text == "" then return end
  local last = line.segs[#line.segs]
  if last and last.t and last.hl == hl then
    last.t = last.t .. text
  else
    line.segs[#line.segs + 1] = { t = text, hl = hl }
  end
  line.w = line.w + strw(text)
end

local function is_blank(line) return line.w == 0 end

local function prefixed(line, text, hl)
  local l = { segs = { { t = text, hl = hl } }, w = strw(text) + line.w }
  for _, s in ipairs(line.segs) do l.segs[#l.segs + 1] = s end
  return l
end

local function pad_to(line, width)
  if line.w < width then push_text(line, string.rep(" ", width - line.w), "Normal") end
  return line
end

local function aligned(lines, align, width)
  if align ~= "center" and align ~= "right" then return lines end
  for i, l in ipairs(lines) do
    local room = width - l.w
    if room > 0 and l.w > 0 then
      local n = align == "center" and math.floor(room / 2) or room
      if n > 0 then lines[i] = prefixed(l, string.rep(" ", n), "Normal") end
    end
  end
  return lines
end

-- Terminal cells per CSS pixel. Kitty fits the image inside the cell box
-- keeping its aspect ratio, so these only set how big a sized image comes out.
M.CELL_W, M.CELL_H = 9, 18

local function px(v)
  if v == nil then return nil end
  v = tostring(v):lower()
  if v:find("%", 1, true) or v == "auto" then return nil end
  local n = tonumber(v:match("^%s*([%d.]+)"))
  if v:find("em", 1, true) then n = n and n * 16 end
  return n
end

-- How big an <img> is drawn, in cells. { ok, src, alt, cols, rows }.
function M.image_ref(node, width, ctx)
  local a = node.attrs or {}
  local src = a.src or a["data-src"]
  local alt = a.alt or a.title or ""
  local info = (ctx and ctx.image and src) and ctx.image(src) or nil
  if not info then return { ok = false, src = src, alt = alt } end
  local css = parse_css(a.style)
  local w, h = px(css.width) or px(a.width), px(css.height) or px(a.height)
  local iw, ih = info.w, info.h
  if w and not h and iw and ih and iw > 0 then h = w * ih / iw end
  if h and not w and iw and ih and ih > 0 then w = h * iw / ih end
  w, h = w or iw, h or ih
  local maxc = math.max(1, math.min(width, (ctx and ctx.max_cols) or 48))
  local maxr = math.max(1, (ctx and ctx.max_rows) or 16)
  local cols, rows
  if w and h and w > 0 and h > 0 then
    cols, rows = w / M.CELL_W, h / M.CELL_H
  else
    cols, rows = maxc, maxr
  end
  local s = math.min(1, maxc / cols, maxr / rows)
  cols = math.max(1, math.floor(cols * s + 0.5))
  rows = math.max(1, math.floor(rows * s + 0.5))
  return { ok = true, src = src, alt = alt, cols = cols, rows = rows }
end

local function alt_label(ref)
  local label = ref.alt ~= "" and ref.alt or (ref.src and vim.fs.basename(ref.src:gsub("[?#].*$", "")) or "image")
  if ref.src and ref.src:match("^data:") then label = ref.alt ~= "" and ref.alt or "image" end
  return "🖼 " .. label
end

-- Wrap inline runs ({text, st} | {br} | {soft} | {img, st}) into lines.
local function wrap_runs(runs, width, ctx, out)
  width = math.max(width, 1)
  local line = new_line()
  local pending_space = false
  local function flush(force)
    if line.w > 0 or force then out[#out + 1] = line end
    line = new_line()
    pending_space = false
  end
  local function add_word(word, hl)
    local ww = strw(word)
    local need = (pending_space and line.w > 0) and 1 or 0
    if line.w > 0 and line.w + need + ww > width then
      flush()
      need = 0
    end
    if need == 1 then push_text(line, " ", hl) end
    if ww > width then
      for ch in chars(word) do
        local cw = strw(ch)
        if line.w > 0 and line.w + cw > width then flush() end
        push_text(line, ch, hl)
      end
    else
      push_text(line, word, hl)
    end
    pending_space = false
  end
  for _, r in ipairs(runs) do
    if r.br then
      flush(true)
    elseif r.soft then
      flush(false)
    elseif r.img then
      local ref = M.image_ref(r.img, width, ctx)
      if ref.ok then
        flush(false)
        for row = 0, ref.rows - 1 do
          out[#out + 1] = { segs = { { img = ref, row = row } }, w = ref.cols }
        end
      else
        if pending_space or line.w > 0 then pending_space = true end
        add_word(alt_label(ref), M.hl_for({ link = true }))
        pending_space = true
      end
    elseif r.text then
      local hl = M.hl_for(r.st)
      local text = M.decode(r.text):gsub("\t", "    ")
      if r.st.pre then
        local first = true
        for piece in (text .. "\n"):gmatch("([^\n]*)\n") do
          if not first then flush(true) end
          first = false
          if piece ~= "" then push_text(line, piece, hl) end
        end
      else
        text = text:gsub("[ \r\n\t\f]+", " ")
        if text:sub(1, 1) == " " then pending_space = true end
        for word in text:gmatch("[^ ]+") do
          add_word(word, hl)
          pending_space = true
        end
        if text:sub(-1) ~= " " then
          -- no space after the last word unless the text ended with one
          pending_space = false
        end
      end
    end
  end
  flush(false)
end

local render_block, render_children

local function collect_inline(node, st, runs)
  for _, ch in ipairs(node.children) do
    if ch.text then
      runs[#runs + 1] = { text = ch.text, st = st }
    elseif not SKIP[ch.name] then
      local s2 = M.derive(st, ch)
      if s2.hidden then -- nothing
      elseif ch.name == "br" then runs[#runs + 1] = { br = true }
      elseif ch.name == "img" then runs[#runs + 1] = { img = ch, st = s2 }
      elseif BLOCK[ch.name] then
        runs[#runs + 1] = { soft = true }
        collect_inline(ch, s2, runs)
        runs[#runs + 1] = { soft = true }
      else
        collect_inline(ch, s2, runs)
      end
    end
  end
end

render_children = function(node, st, width, ctx)
  local out = {}
  local runs = {}
  local gap = false
  local function emit(lines, margin)
    -- drop leading and trailing blank lines of a block
    while #lines > 0 and is_blank(lines[1]) do table.remove(lines, 1) end
    while #lines > 0 and is_blank(lines[#lines]) do table.remove(lines) end
    if #lines == 0 then return end
    if (margin or gap) and #out > 0 and not is_blank(out[#out]) then out[#out + 1] = new_line() end
    for _, l in ipairs(lines) do out[#out + 1] = l end
    gap = margin
  end
  local function flush_runs()
    if #runs == 0 then return end
    local lines = {}
    wrap_runs(runs, width, ctx, lines)
    runs = {}
    -- an explicit <br> may leave blank lines inside, keep those
    emit(aligned(lines, st.align, width), false)
  end
  for _, ch in ipairs(node.children) do
    if ch.text then
      runs[#runs + 1] = { text = ch.text, st = st }
    elseif not SKIP[ch.name] then
      local s2 = M.derive(st, ch)
      if s2.hidden then -- nothing
      elseif BLOCK[ch.name] then
        flush_runs()
        emit(render_block(ch, s2, width, ctx), MARGIN[ch.name])
      elseif ch.name == "br" then
        runs[#runs + 1] = { br = true }
      elseif ch.name == "img" then
        runs[#runs + 1] = { img = ch, st = s2 }
      else
        collect_inline(ch, s2, runs)
      end
    end
  end
  flush_runs()
  return out
end

local function raw_text(node, acc)
  for _, ch in ipairs(node.children) do
    if ch.text then acc[#acc + 1] = ch.text
    elseif ch.name == "br" then acc[#acc + 1] = "\n"
    elseif not SKIP[ch.name] then raw_text(ch, acc) end
  end
  return acc
end

local function render_list(node, st, width, ctx)
  local out = {}
  local idx = tonumber(node.attrs and node.attrs.start) or 1
  local bullet_hl = "JupynvimMdBullet"
  for _, ch in ipairs(node.children) do
    if ch.name then
      local s2 = M.derive(st, ch)
      if not s2.hidden and not SKIP[ch.name] then
        local marker = node.name == "ol" and (idx .. ". ") or "• "
        local mw = strw(marker)
        local inner
        if ch.name == "li" then
          inner = render_children(ch, s2, width - mw, ctx)
          idx = idx + 1
        else
          inner = render_block(ch, s2, width - mw, ctx)
          marker = string.rep(" ", mw)
        end
        for i, l in ipairs(inner) do
          out[#out + 1] = prefixed(l, i == 1 and marker or string.rep(" ", mw),
            i == 1 and bullet_hl or "Normal")
        end
      end
    end
  end
  return out
end

local function only_images(node, imgs)
  for _, ch in ipairs(node.children) do
    if ch.text then
      if M.decode(ch.text):match("[^%s\194\160]") then return false end
    elseif ch.name == "img" then
      imgs[#imgs + 1] = ch
    elseif ch.name ~= "br" and not SKIP[ch.name] then
      if not only_images(ch, imgs) then return false end
    end
  end
  return true
end

local function render_table(node, st, width, ctx)
  local rows, caption = {}, nil
  local function scan(n)
    for _, ch in ipairs(n.children) do
      if ch.name == "tr" then rows[#rows + 1] = ch
      elseif ch.name == "thead" or ch.name == "tbody" or ch.name == "tfoot" then scan(ch)
      elseif ch.name == "caption" then caption = ch
      end
    end
  end
  scan(node)
  local grid, ncols = {}, 0
  for r, tr in ipairs(rows) do
    local cells = {}
    for _, ch in ipairs(tr.children) do
      if ch.name == "td" or ch.name == "th" then cells[#cells + 1] = ch end
    end
    grid[r] = { tr = tr, cells = cells, st = M.derive(st, tr) }
    ncols = math.max(ncols, #cells)
  end
  local out = {}
  if caption then
    for _, l in ipairs(aligned(render_children(caption, M.derive(st, caption), width, ctx), "center", width)) do
      out[#out + 1] = l
    end
  end
  if ncols == 0 then return out end
  local GAP = 2
  -- columns holding only images get the width of their widest image
  local fixed, natural = {}, {}
  for c = 1, ncols do
    local all_img, maxc, any = true, 0, false
    for _, row in ipairs(grid) do
      local cell = row.cells[c]
      if cell then
        local imgs = {}
        if only_images(cell, imgs) then
          for _, im in ipairs(imgs) do
            any = true
            local ref = M.image_ref(im, width, ctx)
            maxc = math.max(maxc, ref.ok and ref.cols or strw(alt_label(ref)))
          end
        else
          all_img = false
        end
      end
    end
    if all_img and any then
      fixed[c] = maxc
    else
      local nat = 1
      for _, row in ipairs(grid) do
        local cell = row.cells[c]
        if cell then
          for _, l in ipairs(render_children(cell, M.derive(row.st, cell), 10000, ctx)) do
            nat = math.max(nat, l.w)
          end
        end
      end
      natural[c] = nat
    end
  end
  local avail = width - GAP * (ncols - 1)
  local flex = {}
  for c = 1, ncols do
    if fixed[c] then avail = avail - fixed[c] else flex[#flex + 1] = c end
  end
  local colw = {}
  for c, w in pairs(fixed) do colw[c] = w end
  if avail < 6 * #flex then
    -- too narrow for side by side: one cell under the other
    for _, row in ipairs(grid) do
      for _, cell in ipairs(row.cells) do
        local lines = render_children(cell, M.derive(row.st, cell), width, ctx)
        if #lines > 0 then
          if #out > 0 and not is_blank(out[#out]) then out[#out + 1] = new_line() end
          for _, l in ipairs(lines) do out[#out + 1] = l end
        end
      end
    end
    return out
  end
  -- share what is left: narrow columns get what they need, the rest split it
  local open = vim.deepcopy(flex)
  local remaining = avail
  while #open > 0 do
    local share = math.floor(remaining / #open)
    local changed = false
    for i = #open, 1, -1 do
      local c = open[i]
      if natural[c] <= share then
        colw[c] = natural[c]
        remaining = remaining - natural[c]
        table.remove(open, i)
        changed = true
      end
    end
    if not changed then
      for i, c in ipairs(open) do
        colw[c] = share + ((i == #open) and (remaining - share * #open) or 0)
      end
      break
    end
  end
  local total = 0
  for c = 1, ncols do total = total + colw[c] end
  total = total + GAP * (ncols - 1)

  local rendered, tall = {}, false
  for r, row in ipairs(grid) do
    local cl, h = {}, 0
    for c = 1, ncols do
      local cell = row.cells[c]
      local lines, va = {}, row.st.valign or "middle"
      if cell then
        local cs = M.derive(row.st, cell)
        lines = render_children(cell, cs, colw[c], ctx)
        va = cs.valign or va
      end
      cl[c] = { lines = lines, valign = va }
      h = math.max(h, #lines)
    end
    if h > 1 then tall = true end
    local header = #row.cells > 0
    for _, cell in ipairs(row.cells) do
      if cell.name ~= "th" then header = false end
    end
    rendered[r] = { cl = cl, h = h, header = header }
  end
  for r, row in ipairs(rendered) do
    if r > 1 and tall and not rendered[r - 1].header then out[#out + 1] = new_line() end
    for i = 1, row.h do
      local line = new_line()
      for c = 1, ncols do
        local cell = row.cl[c]
        local off = 0
        if cell.valign == "middle" then off = math.floor((row.h - #cell.lines) / 2)
        elseif cell.valign == "bottom" then off = row.h - #cell.lines end
        local l = cell.lines[i - off]
        if l then
          for _, s in ipairs(l.segs) do line.segs[#line.segs + 1] = s end
          line.w = line.w + l.w
        end
        if c < ncols then
          -- the next column starts where this one ends, plus the gap
          local want = GAP * c
          for k = 1, c do want = want + colw[k] end
          pad_to(line, want)
        end
      end
      out[#out + 1] = line
    end
    if row.header then
      out[#out + 1] = { segs = { { t = string.rep("─", total), hl = "JupynvimMdTableBorder" } }, w = total }
    end
  end
  return out
end

render_block = function(node, st, width, ctx)
  local n = node.name
  if n == "hr" then
    return { { segs = { { t = string.rep("─", width), hl = "JupynvimMdHR" } }, w = width } }
  elseif n == "ul" or n == "ol" or n == "menu" then
    return render_list(node, st, width, ctx)
  elseif n == "table" then
    return render_table(node, st, width, ctx)
  elseif n == "blockquote" then
    local out = {}
    for _, l in ipairs(render_children(node, st, math.max(width - 2, 1), ctx)) do
      out[#out + 1] = prefixed(l, "▎ ", "JupynvimMdQuote")
    end
    return out
  elseif n == "pre" then
    local text = M.decode(table.concat(raw_text(node, {}))):gsub("\t", "    "):gsub("^\n", "")
    local out = {}
    local hl = M.hl_for(st)
    for piece in (text .. "\n"):gmatch("([^\n]*)\n") do
      local l = new_line()
      push_text(l, piece, hl)
      out[#out + 1] = l
    end
    while #out > 0 and is_blank(out[#out]) do table.remove(out) end
    return out
  elseif n == "li" then
    local out = {}
    for i, l in ipairs(render_children(node, st, math.max(width - 2, 1), ctx)) do
      out[#out + 1] = prefixed(l, i == 1 and "• " or "  ", i == 1 and "JupynvimMdBullet" or "Normal")
    end
    return out
  elseif n == "dd" then
    local out = {}
    for _, l in ipairs(render_children(node, st, math.max(width - 4, 1), ctx)) do
      out[#out + 1] = prefixed(l, "    ", "Normal")
    end
    return out
  end
  return render_children(node, st, width, ctx)
end

-- Lay out an HTML fragment in `width` cells. ctx (optional):
--   image(src) -> { w, h } | nil   whether an image can be shown, and its size
--   max_cols, max_rows             the largest box an image gets
function M.layout(html, width, ctx)
  width = math.max(math.floor(width or 80), 8)
  local key = width .. "\0" .. ((ctx and ctx.cache_key) or "") .. "\0" .. html
  local hit = layout_cache[key]
  if hit then return hit end
  local root = M.parse(html)
  local lines = render_children(root, {}, width, ctx)
  while #lines > 0 and is_blank(lines[#lines]) do table.remove(lines) end
  -- trailing padding only costs columns
  for _, l in ipairs(lines) do
    local last = l.segs[#l.segs]
    if last and last.t and last.hl == "Normal" and last.t:match("^ +$") then
      table.remove(l.segs)
      l.w = l.w - #last.t
    end
  end
  layout_cache_n = layout_cache_n + 1
  if layout_cache_n > 128 then layout_cache, layout_cache_n = {}, 1 end
  layout_cache[key] = lines
  return lines
end

function M._clear_cache() layout_cache, layout_cache_n = {}, 0 end

-- Turn laid-out lines into virt_lines. resolve(ref) gives the image's rows
-- (each a list of {text, hl} chunks) once it is in the terminal, else nil:
-- the box stays blank until then.
function M.to_virt_lines(lines, resolve, lead)
  local out = {}
  local rows_of = {}
  for _, l in ipairs(lines) do
    local chunks = {}
    if lead and lead ~= "" then chunks[1] = { lead, "Normal" } end
    for _, s in ipairs(l.segs) do
      if s.t then
        chunks[#chunks + 1] = { s.t, s.hl or "Normal" }
      else
        local ref = s.img
        local rows = rows_of[ref]
        if rows == nil then
          rows = (resolve and resolve(ref)) or false
          rows_of[ref] = rows
        end
        local r = rows and rows[s.row + 1]
        if r then
          for _, c in ipairs(r) do chunks[#chunks + 1] = c end
        else
          chunks[#chunks + 1] = { string.rep(" ", ref.cols), "Normal" }
        end
      end
    end
    if #chunks == 0 then chunks[1] = { " ", "Normal" } end
    out[#out + 1] = chunks
  end
  return out
end

-- ------------------------------------------------------ block detection ----

local function tag_alone(s)
  local tag, e = parse_tag(s, 1)
  if not tag then return false end
  return s:sub(e + 1):match("^%s*$") ~= nil
end

-- The CommonMark HTML block kind a line starts (1-7), or nil.
function M.block_start(raw)
  local s = raw:match("^ ? ? ?(<.*)$")
  if not s then return nil end
  local lname = s:match("^<([%a][%w-]*)")
  if lname and RAW_START[lname:lower()] then
    local rest = s:sub(#lname + 2, #lname + 2)
    if rest == "" or rest:match("[%s>]") then return 1 end
  end
  if s:sub(1, 4) == "<!--" then return 2 end
  if s:sub(1, 2) == "<?" then return 3 end
  if s:match("^<!%a") then return 4 end
  if s:sub(1, 9) == "<![CDATA[" then return 5 end
  local close, name = s:match("^<(/?)([%a][%w-]*)")
  if name then
    local lower = name:lower()
    if BLOCK_START[lower] then
      local rest = s:sub(#close + #name + 2)
      if rest == "" or rest:match("^[%s>]") or rest:match("^/>") then return 6 end
    end
    if not RAW_START[lower] and tag_alone(s) then return 7 end
  end
  return nil
end

local ENDS = {
  [1] = function(l)
    l = l:lower()
    return l:find("</script>", 1, true) or l:find("</pre>", 1, true)
      or l:find("</style>", 1, true) or l:find("</textarea>", 1, true)
  end,
  [2] = function(l) return l:find("-->", 1, true) end,
  [3] = function(l) return l:find("?>", 1, true) end,
  [4] = function(l) return l:find(">", 1, true) end,
  [5] = function(l) return l:find("]]>", 1, true) end,
}

-- HTML blocks in a list of markdown lines: { {first, last}, ... } (1-based,
-- inclusive). Fenced code and $$ math are left alone.
function M.blocks(lines)
  local out = {}
  local i, n = 1, #lines
  local fence = nil
  local prev_text = false
  while i <= n do
    local raw = lines[i]
    local f = raw:match("^%s*(```+)") or raw:match("^%s*(~~~+)")
    if fence then
      if f and f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence then fence = nil end
      i = i + 1
      prev_text = false
    elseif f then
      fence = f
      i = i + 1
      prev_text = false
    else
      local kind = M.block_start(raw)
      -- condition 7 cannot interrupt a paragraph
      if kind == 7 and prev_text then kind = nil end
      if kind then
        local last = i
        if ENDS[kind] then
          while last < n and not ENDS[kind](lines[last]) do last = last + 1 end
        else
          while last < n and not lines[last + 1]:match("^%s*$") do last = last + 1 end
        end
        out[#out + 1] = { first = i, last = last, kind = kind }
        i = last + 1
        prev_text = false
      else
        prev_text = not raw:match("^%s*$")
        i = i + 1
      end
    end
  end
  return out
end

-- -------------------------------------------------------- inline tags ----

-- HTML tags inside a markdown line: { s, e (1-based, inclusive), name,
-- close, selfclose, attrs }. Only real HTML tag names count, so "List<T>"
-- or "a <b" in prose are left alone. Comments come back as name "!--".
function M.inline_tags(line)
  local out = {}
  local i = 1
  while true do
    local a = line:find("<", i, true)
    if not a then break end
    local nexti = a + 1
    if line:sub(a, a + 3) == "<!--" then
      local e = line:find("-->", a + 4, true)
      if e then
        out[#out + 1] = { s = a, e = e + 2, name = "!--", attrs = {} }
        nexti = e + 3
      end
    else
      local tag, e = parse_tag(line, a)
      if tag and INLINE_KNOWN[tag.name] then
        tag.s, tag.e = a, e
        out[#out + 1] = tag
        nexti = e + 1
      end
    end
    i = nexti
  end
  return out
end

-- The style a run of inline tags gives the text inside them.
function M.inline_style(open_tags)
  local st = {}
  for _, t in ipairs(open_tags) do st = M.derive(st, t) end
  return st
end

return M
