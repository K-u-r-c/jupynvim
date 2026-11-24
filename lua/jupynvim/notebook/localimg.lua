-- Images a markdown cell points at by path: `<img src="../assets/x.jpg">`,
-- `![alt](plots/fig.png)`, or an `<img src="data:image/png;base64,...">`.
--
-- Relative paths resolve against the notebook's directory, like Jupyter does.
-- Nothing is fetched over the network: an http(s) source is not an image
-- this module can give, and the caller shows its alt text instead.
--
-- Files are read once and kept while their mtime and size stay the same.

local M = {}

local MAX_BYTES = 25 * 1024 * 1024
local HEAD_BYTES = 64 * 1024

local bit = require("bit")

-- path -> { mtime, size, entry } (entry = false when the file is no image)
local cache = {}
local cache_n = 0

local function be16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function be32(s, i) return ((s:byte(i) * 256 + s:byte(i + 1)) * 256 + s:byte(i + 2)) * 256 + s:byte(i + 3) end
local function le16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end
local function le24(s, i) return s:byte(i) + s:byte(i + 1) * 256 + s:byte(i + 2) * 65536 end

-- The image type from the first bytes, else nil.
function M.sniff(bytes)
  if type(bytes) ~= "string" or #bytes < 4 then return nil end
  if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then return "image/png" end
  if bytes:sub(1, 3) == "\255\216\255" then return "image/jpeg" end
  if bytes:sub(1, 4) == "GIF8" then return "image/gif" end
  if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then return "image/webp" end
  if bytes:sub(1, 2) == "BM" then return "image/bmp" end
  local head = bytes:sub(1, 1024):lower()
  if head:find("<svg", 1, true) then return "image/svg+xml" end
  return nil
end

-- Pixel size from the header, else nil. Only the first bytes are needed.
function M.dimensions(bytes, mime)
  if type(bytes) ~= "string" then return nil end
  local n = #bytes
  if mime == "image/png" and n >= 24 then
    return be32(bytes, 17), be32(bytes, 21)
  elseif mime == "image/gif" and n >= 10 then
    return le16(bytes, 7), le16(bytes, 9)
  elseif mime == "image/jpeg" then
    local i = 3
    while i + 8 <= n do
      if bytes:byte(i) ~= 0xFF then return nil end
      local marker = bytes:byte(i + 1)
      if marker == 0xFF then
        i = i + 1
      elseif marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
        return be16(bytes, i + 7), be16(bytes, i + 5)
      elseif marker == 0xD8 or (marker >= 0xD0 and marker <= 0xD7) or marker == 0x01 then
        i = i + 2
      else
        i = i + 2 + be16(bytes, i + 2)
      end
    end
  elseif mime == "image/webp" and n >= 30 then
    local kind = bytes:sub(13, 16)
    if kind == "VP8X" then
      return 1 + le24(bytes, 25), 1 + le24(bytes, 28)
    elseif kind == "VP8 " then
      return bit.band(le16(bytes, 27), 0x3FFF), bit.band(le16(bytes, 29), 0x3FFF)
    elseif kind == "VP8L" then
      local b0, b1, b2, b3 = bytes:byte(22, 25)
      local w = 1 + bit.bor(bit.lshift(bit.band(b1, 0x3F), 8), b0)
      local h = 1 + bit.bor(bit.lshift(bit.band(b3, 0x0F), 10), bit.lshift(b2, 2), bit.rshift(bit.band(b1, 0xC0), 6))
      return w, h
    end
  elseif mime == "image/bmp" and n >= 26 then
    local w = bytes:byte(19) + bytes:byte(20) * 256 + bytes:byte(21) * 65536 + bytes:byte(22) * 16777216
    local h = bytes:byte(23) + bytes:byte(24) * 256 + bytes:byte(25) * 65536 + bytes:byte(26) * 16777216
    if h >= 2147483648 then h = 4294967296 - h end
    return w, h
  elseif mime == "image/svg+xml" then
    local head = bytes:sub(1, 4096)
    local tag = head:match("<svg[^>]*>")
    if not tag then return nil end
    local w = tonumber(tag:match('%swidth%s*=%s*["\']%s*([%d.]+)%s*p?x?%s*["\']'))
    local h = tonumber(tag:match('%sheight%s*=%s*["\']%s*([%d.]+)%s*p?x?%s*["\']'))
    if w and h then return w, h end
    local vw, vh = tag:match('viewBox%s*=%s*["\']%s*[-%d.]+[%s,]+[-%d.]+[%s,]+([%d.]+)[%s,]+([%d.]+)')
    if vw then return tonumber(vw), tonumber(vh) end
  end
  return nil
end

-- The local file an `src` names, or nil (remote URL, data: URI, empty).
function M.resolve_path(src, dir)
  if type(src) ~= "string" then return nil end
  src = vim.trim(src)
  if src == "" or src:match("^data:") then return nil end
  if src:match("^file://") then
    src = src:sub(8)
  elseif src:match("^%a[%w+.-]*:") or src:sub(1, 2) == "//" then
    return nil
  end
  src = src:gsub("[?#].*$", "")
  src = src:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  if src:sub(1, 1) == "~" then
    src = vim.fn.expand(src)
  elseif src:sub(1, 1) ~= "/" then
    if type(dir) ~= "string" or dir == "" then return nil end
    src = dir .. "/" .. src
  end
  return vim.fs.normalize(src)
end

-- The directory relative image paths of a notebook resolve against, or nil
-- for a notebook that is not a local file (a remote jupynvim:// one).
function M.notebook_dir(path)
  if type(path) ~= "string" or path == "" or path:match("^%a[%w+.-]*://") then return nil end
  return vim.fs.dirname(vim.fn.fnamemodify(path, ":p"))
end

-- data: URIs by their text: hashing a large payload on every redraw costs
local data_cache, data_cache_n = {}, 0

local function from_data_uri(src)
  local hit = data_cache[src]
  if hit ~= nil then return hit or nil end
  local e = M._parse_data_uri(src)
  data_cache_n = data_cache_n + 1
  if data_cache_n > 64 then data_cache, data_cache_n = {}, 1 end
  data_cache[src] = e or false
  return e
end

function M._parse_data_uri(src)
  local mime, payload = src:match("^data:(image/[%w.+-]+)[^,]-;base64,(.*)$")
  if not mime then return nil end
  payload = payload:gsub("%s+", "")
  if payload == "" then return nil end
  local ok, head = pcall(vim.base64.decode, payload:sub(1, 4096 - (4096 % 4)))
  local w, h
  if ok then w, h = M.dimensions(head, M.sniff(head) or mime) end
  return {
    b64 = payload, mime = M.sniff(ok and head or "") or mime, w = w, h = h,
    hash = vim.fn.sha256(payload):sub(1, 16),
  }
end

local function read(path, n)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read(n or "*a")
  f:close()
  return data
end

-- What `src` shows: { b64, mime, w, h, hash } or nil. `want_data` = false
-- reads only the header (enough for the size) and leaves b64 out.
function M.load(src, dir, want_data)
  if type(src) ~= "string" then return nil end
  if src:match("^%s*data:") then return from_data_uri(vim.trim(src)) end
  local path = M.resolve_path(src, dir)
  if not path then return nil end
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" or st.size == 0 or st.size > MAX_BYTES then return nil end
  local mtime = st.mtime.sec * 1e9 + (st.mtime.nsec or 0)
  local c = cache[path]
  if not c or c.mtime ~= mtime or c.size ~= st.size then
    local head = read(path, HEAD_BYTES)
    local mime = M.sniff(head)
    if not mime then
      c = { mtime = mtime, size = st.size, entry = false }
    else
      local w, h = M.dimensions(head, mime)
      c = { mtime = mtime, size = st.size, entry = {
        mime = mime, w = w, h = h, path = path,
        hash = vim.fn.sha256(path .. "\0" .. mtime .. "\0" .. st.size):sub(1, 16),
      } }
    end
    if not cache[path] then cache_n = cache_n + 1 end
    if cache_n > 256 then cache, cache_n = {}, 1 end
    cache[path] = c
  end
  local e = c.entry
  if not e then return nil end
  if want_data ~= false and not e.b64 then
    local bytes = read(path)
    if not bytes or #bytes == 0 then return nil end
    e.b64 = vim.base64.encode(bytes)
  end
  return e
end

function M._clear_cache() cache, cache_n, data_cache, data_cache_n = {}, 0, {}, 0 end

return M
