-- Headless checks of HTML in markdown cells (html.lua, localimg.lua and the
-- markdown.lua hookup).
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.runtimepath:prepend(root)
local H = require("jupynvim.notebook.html")
local L = require("jupynvim.notebook.localimg")
local MD = require("jupynvim.notebook.markdown")
MD.setup_hl()

local function text_of(line)
  local s = ""
  for _, seg in ipairs(line.segs) do s = s .. (seg.t or string.rep("#", seg.img.cols)) end
  return s
end
local function texts(lines)
  local out = {}
  for _, l in ipairs(lines) do out[#out + 1] = text_of(l) end
  return out
end

-- 1. entities and colors
assert(H.decode("a &amp; b &lt;c&gt; &#8594; &#x41; &nosuch;") == "a & b <c> → A &nosuch;", "decode")
assert(H.parse_color("#f71") == "#ff7711" and H.parse_color("rgb(1, 2, 3)") == "#010203"
  and H.parse_color("Red") == "#ff0000" and H.parse_color("bogus") == nil, "parse_color")
local dark = H.readable("#990000", "#000000")
assert(dark ~= "#990000", "a dark red on black is lightened")
assert(H.readable("#ff7711", "#000000") == "#ff7711", "a readable color is kept")
print("1. entities, colors ok")

-- 2. CommonMark block detection
local lines = {
  "# Heading",                         -- 1
  "",                                   -- 2
  '<table style="margin: 0;">',         -- 3  block 6 ...
  "  <tr><td>x</td></tr>",              -- 4
  "</table>",                           -- 5  ... ends before the blank
  "",                                   -- 6
  "text line",                          -- 7
  "<span>inline after text</span>",     -- 8  condition 7 cannot interrupt a paragraph
  "",                                   -- 9
  '<img src="a.png">',                  -- 10 condition 7 alone on its line
  "",                                   -- 11
  "```",                                -- 12
  "<div>in a fence</div>",              -- 13 not a block
  "```",                                -- 14
  "<!-- a",                             -- 15 condition 2 ...
  "",                                   -- 16
  "comment -->",                        -- 17 ... ends at -->
}
local b = H.blocks(lines)
assert(#b == 3, "expected 3 blocks, got " .. #b)
assert(b[1].first == 3 and b[1].last == 5 and b[1].kind == 6, "table block")
assert(b[2].first == 10 and b[2].last == 10 and b[2].kind == 7, "img block")
assert(b[3].first == 15 and b[3].last == 17 and b[3].kind == 2, "comment block")
print("2. html blocks ok")

-- 3. forgiving parse: unclosed cells, auto-closed rows, void tags
local tree = H.parse("<table><tr><td>a<td>b<tr><td>c</table><p>x<br>y")
assert(tree.children[1].name == "table", "table root")
local rows = 0
for _, ch in ipairs(tree.children[1].children) do if ch.name == "tr" then rows = rows + 1 end end
assert(rows == 2, "two rows, got " .. rows)
print("3. forgiving parse ok")

-- 4. layout: headings, br, lists, alt text without images
local out = texts(H.layout("<h2>Title</h2><p>one<br>two &amp; three</p><ul><li>a</li><li>b</li></ul>"
  .. '<img src="https://x.dev/p.png" alt="remote">', 40))
assert(out[1] == "Title", "heading: " .. tostring(out[1]))
assert(out[2] == "" and out[3] == "one" and out[4] == "two & three", "br: " .. vim.inspect(out))
assert(out[6] == "• a" and out[7] == "• b", "list: " .. vim.inspect(out))
assert(out[#out]:find("remote", 1, true), "remote image falls back to its alt text")
print("4. text layout ok")

-- 5. a layout table: image cell fixed, text cell wraps beside it, centered
local fake = { image = function() return { w = 150, h = 150 } end, max_cols = 48, max_rows = 16 }
local tl = H.layout([[<table><tr>
  <td><img src="i.jpg" width="150" height="150"></td>
  <td><h2 style="color:#900">Read me</h2><span>]] .. string.rep("word ", 40) .. [[</span></td>
</tr></table>]], 60, fake)
local first_img
for i, l in ipairs(tl) do
  if l.segs[1] and l.segs[1].img then first_img = first_img or i end
  assert(l.w <= 60, "line " .. i .. " wider than 60: " .. l.w)
end
assert(first_img, "image rows present")
local ref = tl[first_img].segs[1].img
assert(ref.cols == 17 and ref.rows == 8, "150px -> 17x8 cells, got " .. ref.cols .. "x" .. ref.rows)
local saw_text_beside = false
for _, l in ipairs(tl) do
  local t = text_of(l)
  if t:match("^#################  word") then saw_text_beside = true end
end
assert(saw_text_beside, "text sits next to the image:\n" .. table.concat(texts(tl), "\n"))
local hl
for _, l in ipairs(tl) do
  for _, seg in ipairs(l.segs) do if seg.t == "Read me" then hl = seg.hl end end
end
assert(hl and hl:find("^JupynvimHtml_H2_b"), "colored bold heading group, got " .. tostring(hl))
print("5. table with image ok")

-- 6. a data table with a header row
local dt = texts(H.layout("<table><tr><th>Model</th><th>Score</th></tr><tr><td>gpt</td><td>91</td></tr></table>", 40))
assert(dt[1] == "Model  Score" and dt[2] == string.rep("─", 12) and dt[3] == "gpt    91", vim.inspect(dt))
print("6. data table ok")

-- 7. image sizes from headers
local png = "\137PNG\r\n\26\n" .. "\0\0\0\13IHDR" .. "\0\0\1\44" .. "\0\0\0\200" .. string.rep("\0", 8)
assert(L.sniff(png) == "image/png", "png sniff")
local w, h = L.dimensions(png, "image/png")
assert(w == 300 and h == 200, "png dims " .. tostring(w) .. "x" .. tostring(h))
local gif = "GIF89a" .. "\100\0" .. "\50\0" .. string.rep("\0", 8)
w, h = L.dimensions(gif, L.sniff(gif))
assert(w == 100 and h == 50, "gif dims")
local jpg = "\255\216" .. "\255\224\0\4\0\0" .. "\255\192\0\17\8" .. "\0\120" .. "\0\160" .. string.rep("\0", 12)
w, h = L.dimensions(jpg, L.sniff(jpg))
assert(w == 160 and h == 120, "jpeg dims " .. tostring(w) .. "x" .. tostring(h))
assert(L.resolve_path("https://x/y.png", "/d") == nil and L.resolve_path("a b.png", "/d") == "/d/a b.png"
  and L.resolve_path("../x%20y.png?v=1", "/d/e") == "/d/x y.png", "resolve_path")
-- a real file next to a notebook
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local f = io.open(dir .. "/p.png", "wb"); f:write(png); f:close()
local e = L.load("p.png", dir, true)
assert(e and e.mime == "image/png" and e.w == 300 and e.b64 == vim.base64.encode(png), "load")
assert(L.load("missing.png", dir) == nil, "missing file")
assert(L.notebook_dir("jupynvim://cluster/x.ipynb") == nil, "remote notebook has no local dir")
print("7. local images ok")

-- 8. markdown hookup: the block hides its lines, hangs the layout below its
-- first line, inline tags are concealed and style what they wrap
local buf = vim.api.nvim_create_buf(true, false)
local ns = vim.api.nvim_create_namespace("html_spec")
local content = {
  "Some <b>bold</b> and <span style=\"color:#f71\">orange</span> a&amp;b",
  "",
  "<div>",
  "<h3>Inside</h3>",
  "</div>",
  "",
  "![pic](p.png)",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
local below, hidden = {}, {}
MD.render(buf, ns, 0, #content - 1, 60, {
  image = function(src) return L.load(src, dir, false) end,
  resolve = function() return nil end,
  below = function(l, vl) below[l] = vl end,
  hide = function(l) hidden[l] = true end,
  lead = "",
})
assert(hidden[3] and hidden[4] and not hidden[2], "block lines after the first are hidden")
assert(below[2] and below[2][1][1][1] == "Inside", "block layout hangs under its first line: " .. vim.inspect(below[2]))
assert(below[6] and #below[6] > 0, "a file image hangs under its markdown line")
local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { 0, 0 }, { 0, -1 }, { details = true })
local concealed, styled, amp = 0, false, false
for _, m in ipairs(marks) do
  local d = m[4]
  if d.conceal == "" then concealed = concealed + 1 end
  if d.conceal == "&" then amp = true end
  if d.hl_group and tostring(d.hl_group):find("^JupynvimHtml_") then styled = true end
end
assert(concealed >= 4, "four inline tags concealed, got " .. concealed)
assert(styled, "text between <span style=color> and </span> is styled")
assert(amp, "&amp; shows as &")
print("8. markdown hookup ok")

vim.fn.delete(dir, "rf")

-- 9. tmux: one passthrough per kitty escape. tmux drops a sequence longer
-- than input-buffer-size (1 MiB), and a photo is ~2.5 MB of base64.
local Image = require("jupynvim.notebook.image")
local big = string.rep("A", 3 * 1024 * 1024)
local esc = {}
for i = 1, #big, 4096 do
  esc[#esc + 1] = string.format("\27_Gm=%d,q=2;%s\27\\", (i + 4096 <= #big) and 1 or 0, big:sub(i, i + 4095))
end
esc = table.concat(esc)
local wrapped = Image._tmux_wrap(esc)
local unwrapped, longest, count = {}, 0, 0
for seq in wrapped:gmatch("\27Ptmux;(.-\27\27\\)\27\\") do
  count = count + 1
  longest = math.max(longest, #seq)
  unwrapped[#unwrapped + 1] = (seq:gsub("\27\27", "\27"))
end
assert(count == math.ceil(#big / 4096), "one passthrough per escape, got " .. count)
assert(longest < 16 * 1024, "every passthrough is small, longest " .. longest)
assert(table.concat(unwrapped) == esc, "unwrapping gives the escapes back")
print("9. tmux passthrough per escape ok")

-- 10. a large image is shrunk to its box before it is sent
if vim.fn.executable("magick") == 1 then
  local src = vim.fn.tempname() .. ".png"
  vim.fn.system({ "magick", "-size", "1024x1024", "plasma:", src })
  local fh = io.open(src, "rb"); local bytes = fh:read("*a"); fh:close()
  os.remove(src)
  local sent
  Image._send_hook = function(method, a)
    if method == "kitty_transmit_virtual" then sent = a.png_b64 end
    return { image_id = a.image_id }
  end
  Image.ensure_transmitted("spec_resize", vim.base64.encode(bytes), function() end,
    { renderer = "placeholder", mime = "image/png", rows = 8, cols = 17, max_px = "340x320" })
  Image._send_hook = nil
  assert(sent, "image was sent")
  local w, h = L.dimensions(vim.base64.decode(sent):sub(1, 64), "image/png")
  assert(w <= 340 and h <= 320, "sent at " .. tostring(w) .. "x" .. tostring(h))
  assert(#sent < #vim.base64.encode(bytes) / 4, "the shrunk image is much smaller")
  print("10. large image shrunk to its box ok (" .. w .. "x" .. h .. ")")
else
  print("10. skipped (no ImageMagick)")
end

print("ALL HTML CHECKS PASSED")
vim.cmd("qa!")
