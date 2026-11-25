-- Markdown and HTML outputs: display(Markdown(...)) and HTML(...).
--
-- An output showed only its text/plain. Markdown(...) sends its source there,
-- so a model's answer read as raw `# heading` and `**bold**`, and HTML(...)
-- showed "<IPython.core.display.HTML object>". Now text/markdown is drawn like
-- a markdown cell, and text/html when the plain text is only an object repr.
-- A DataFrame keeps its text/plain table.

package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or "") .. "\n"); fails = fails + 1 end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.XDG_STATE_HOME = tmp .. "/state"
-- image escapes go to a file, not the terminal running the spec
vim.env.TERM = "xterm-kitty"
vim.env.JUPYNVIM_TTY = tmp .. "/tty"
io.open(vim.env.JUPYNVIM_TTY, "w"):close()

local J      = require("jupynvim")
local NB     = require("jupynvim.notebook")
local CM     = require("jupynvim.notebook.cellmode")
local Render = require("jupynvim.notebook.render")
J.setup({ log_level = "warn", image_renderer = "placeholder" })

local MD = table.concat({
  "# Virtual Tables",
  "",
  "A **virtual table** is a lookup table.",
  "",
  "```cpp",
  "class Base { virtual void f(); };",
  "```",
  "",
  "| Function | Pointer |",
  "|----------|---------|",
  "| f        | ptr_f   |",
}, "\n")
local HTML = "<h2>Title</h2>\n<p>one <b>two</b></p>"

local function code(id, outputs)
  return { cell_type = "code", id = id, metadata = vim.empty_dict(), source = "pass  # " .. id,
           execution_count = 1, outputs = outputs }
end
local function result(data)
  return { output_type = "execute_result", execution_count = 1, metadata = vim.empty_dict(), data = data }
end

local p = tmp .. "/rich.ipynb"
do
  local f = io.open(p, "w")
  f:write(vim.json.encode({
    cells = {
      code("md", { result({ ["text/plain"] = MD, ["text/markdown"] = MD }) }),
      code("html", { result({ ["text/plain"] = "<IPython.core.display.HTML object>", ["text/html"] = HTML }) }),
      code("df", { result({ ["text/plain"] = "   a\n0  1", ["text/html"] = "<table><tr><td>1</td></tr></table>" }) }),
      code("mixed", {
        { output_type = "stream", name = "stdout", text = "# printed, not markdown\n" },
        { output_type = "display_data", metadata = vim.empty_dict(),
          data = { ["text/plain"] = "## two", ["text/markdown"] = "## two" } },
      }),
    },
    metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } },
    nbformat = 4, nbformat_minor = 5,
  }))
  f:close()
end

local buf = J.open(p)
vim.wait(3000, function() return NB.get(buf) ~= nil end, 20)
vim.api.nvim_set_current_buf(buf)
local nb = NB.get(buf)

local function idx(id) for i, c in ipairs(nb.cells) do if c.id == id then return i end end end
local function cell(id) return nb.cells[idx(id)] end
local function range(id) return CM.ranges(buf)[idx(id)] end
local function marks(row)
  return vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, { row, 0 }, { row, -1 }, { details = true })
end
local function find(row, pred)
  for _, m in ipairs(marks(row)) do if pred(m[4], m[3]) then return m[4], m[3] end end
end
-- is the row under the plain-text mask (which may start on an earlier row)
local function masked(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, -1, { details = true })) do
    local d = m[4]
    if d.hl_group == "JupynvimOutputText" and m[2] <= row and (d.end_row or m[2]) >= row then return true end
  end
  return false
end

-- ── which outputs are rich ──────────────────────────────────────────────
do
  local n = #vim.split(MD, "\n")
  local r = NB.output_rich(cell("md"))
  chk("Markdown(...) is drawn as markdown", #r == 1 and r[1][1] == 1 and r[1][2] == n and r[1][3] == "markdown",
      vim.inspect(r))
  chk("its rows are its source under the usual indent", NB.output_lines(cell("md"))[1] == "  # Virtual Tables")
  local h = NB.output_rich(cell("html"))
  chk("HTML(...) is drawn as HTML", #h == 1 and h[1][3] == "html", vim.inspect(h))
  chk("instead of its object repr", NB.output_lines(cell("html"))[1] == "  <h2>Title</h2>")
  chk("a DataFrame keeps its text/plain table", #NB.output_rich(cell("df")) == 0
      and NB.output_lines(cell("df"))[1] == "     a")
  local m = NB.output_rich(cell("mixed"))
  chk("only the markdown output of a cell is rich, not a print before it",
      #m == 1 and m[1][1] == 2 and m[1][2] == 2, vim.inspect(m))
end

Render.refresh_sync(nb, vim.fn.bufwinid(buf))

-- ── markdown output drawn ───────────────────────────────────────────────
do
  local r = range("md")
  local head = r.out_sep + 1
  chk("the heading row is not under the plain-text mask", not masked(head))
  chk("the heading row gets the H1 color", find(head, function(d) return d.line_hl_group == "JupynvimMdH1" end) ~= nil)
  local c, col = find(head, function(d) return d.conceal == "" and d.end_col end)
  chk("its '# ' is hidden after the two-space indent", c and col == 2 and c.end_col == 4,
      c and (col .. ".." .. c.end_col))
  chk("above the mask", c and c.priority > 5000, c and c.priority)
  local bold = find(head + 2, function(d) return d.hl_group == "JupynvimMdBold" end)
  chk("**bold** is drawn bold", bold ~= nil)
  chk("the code block is styled", find(head + 5, function(d) return d.line_hl_group == "JupynvimMdCode" end) ~= nil)
  local top = find(head + 8, function(d) return d.virt_lines and d.virt_lines_above end)
  chk("the table gets a top border, indented with the output",
      top and top.virt_lines[1][1][1] == "  " and top.virt_lines[1][2][1]:find("^┌"),
      top and vim.inspect(top.virt_lines[1]))
end

-- ── HTML output drawn ───────────────────────────────────────────────────
do
  local r = range("html")
  local first = r.out_sep + 1
  chk("the HTML rows are not under the plain-text mask", not masked(first) and not masked(first + 1))
  local below = find(first, function(d) return d.virt_lines and d.virt_lines_leftcol end)
  local txt = ""
  for _, l in ipairs(below and below.virt_lines or {}) do
    for _, ch in ipairs(l) do txt = txt .. ch[1] end
    txt = txt .. "\n"
  end
  chk("its HTML is laid out under its first row", txt:find("Title", 1, true) and txt:find("one two", 1, true), txt)
  chk("and the spacer comes after it, in the same extmark", txt:match("\n %s*\n$") ~= nil, vim.inspect(txt))
  chk("the source is hidden", find(first + 1, function(d) return d.conceal_lines end) ~= nil)
end

-- ── plain outputs keep the mask ─────────────────────────────────────────
do
  chk("a DataFrame row is under the mask", masked(range("df").out_sep + 1))
  local r = range("mixed")
  chk("a print before a markdown output is under the mask", masked(r.out_sep + 1))
  chk("the markdown output after it is not", not masked(r.out_sep + 2))
end

-- ── cut and hidden outputs ──────────────────────────────────────────────
do
  local c = cell("md")
  local long = {}
  for i = 1, 1000 do long[i] = "- item " .. i end
  long = table.concat(long, "\n")
  c.outputs = { { output_type = "execute_result", data = { ["text/plain"] = long, ["text/markdown"] = long } } }
  local r = NB.output_rich(c)
  chk("a cut markdown output draws its head and its tail",
      #r == 2 and r[1][1] == 1 and r[1][2] == 500 and r[2][1] == 502 and r[2][2] == 506, vim.inspect(r))
  chk("but not the marker between them", NB.output_lines(c)[501]:find("lines hidden", 1, true) ~= nil)

  local h = {}
  for i = 1, 1000 do h[i] = "<p>" .. i .. "</p>" end
  h = table.concat(h, "\n")
  c.outputs = { { output_type = "execute_result",
                  data = { ["text/plain"] = "<IPython.core.display.HTML object>", ["text/html"] = h } } }
  chk("a cut HTML output stays plain text", #NB.output_rich(c) == 0)

  c.outputs = { { output_type = "execute_result", data = { ["text/plain"] = MD, ["text/markdown"] = MD } } }
  c._output_hidden = true
  chk("a hidden output draws nothing rich", #NB.output_rich(c) == 0)
  c._output_hidden = nil

  c.outputs[1].data = { ["text/plain"] = MD, ["text/markdown"] = MD:gsub("Virtual", "Abstract") }
  chk("a new markdown of the same plain length is not served from the cache",
      NB.output_lines(c)[1] == "  # Abstract Tables", NB.output_lines(c)[1])
end

pcall(vim.api.nvim_buf_delete, buf, { force = true })
vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL RICH-OUTPUT CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nRICH-OUTPUT: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end
