-- LaTeX \label{}s across the project's .tex files, for the \ref{} picker.
local files = require("citer.files")

local M = {}

local SECTIONS = {
  part = true,
  chapter = true,
  section = true,
  subsection = true,
  subsubsection = true,
  paragraph = true,
  subparagraph = true,
}
local INCLUDES = { input = true, include = true, subfile = true }
-- Environments a label inside belongs to the enclosing one (or heading) instead.
local TRANSPARENT = { document = true, center = true, flushleft = true, flushright = true, minipage = true }
-- Environments whose optional argument is a placement, not a title.
local FLOATS = { figure = true, table = true, wrapfigure = true, wraptable = true, subfigure = true, subtable = true }
local MATH = {
  equation = true,
  align = true,
  alignat = true,
  flalign = true,
  gather = true,
  multline = true,
  eqnarray = true,
  subequations = true,
}

--- Remove % comments (but not \%), keeping line breaks so line numbers stay put.
local function strip_comments(text)
  if not text:find("%", 1, true) then
    return text
  end
  return (text:gsub("[^\n]*", function(line)
    local i = 1
    while true do
      local k = line:find("%", i, true)
      if not k then
        return line
      end
      local slashes = #line:sub(1, k - 1):match("\\*$")
      if slashes % 2 == 0 then
        return line:sub(1, k - 1)
      end
      i = k + 1
    end
  end))
end

-- After a command name ending at `i - 1`, skip a star and [optional] arguments and read
-- the {argument}; returns (contents, index after it, first optional argument).
local function argument(text, i)
  local j = text:match("^%*?()", i)
  local opt
  while true do
    local s = text:match("^%s*()%[", j)
    local e = s and select(2, text:find("^%b[]", s))
    if not e then
      break
    end
    opt = opt or text:sub(s + 1, e - 1)
    j = e + 1
  end
  local s = text:match("^%s*(){", j)
  local e = s and select(2, text:find("^%b{}", s))
  if not e then
    return nil, j
  end
  return text:sub(s + 1, e - 1), e + 1, opt
end

--- Flatten LaTeX to readable one-line text: drop commands and braces, collapse whitespace.
local function plain(s)
  s = s:gsub("\\label%s*%b{}", ""):gsub("\\%a+%*?", ""):gsub("[{}]", ""):gsub("%s+", " ")
  return vim.trim(s)
end

--- Math rows read better with commands kept: just drop labels/tags and alignment marks.
local function math_text(s)
  s = s:gsub("\\label%s*%b{}", ""):gsub("\\nonumber", ""):gsub("\\notag", ""):gsub("&", ""):gsub("%s+", " ")
  return vim.trim(s)
end

-- A short description of what a label points at.
local function describe(text, label)
  local env = label.env
  if env and env.caption then
    return plain(env.caption)
  end
  if env and env.title then
    return plain(env.title)
  end
  if not env and label.heading then
    return plain(label.heading.title)
  end
  -- Otherwise the text around the label: for math, the row it's on (rows end with \\).
  local lo = env and env.start or (text:sub(1, label.at):match(".*()\n") or 1)
  local hi = env and env.stop or (text:find("\n", label.at, true) or #text + 1)
  local before = text:sub(lo, label.at - 1):match("([^\n]*)$")
  local after = text:sub(label.at, hi - 1)
  if env and MATH[env.name] then
    before = text:sub(lo, label.at - 1)
    before = before:match(".*\\\\(.*)$") or before
    after = after:match("^(.-)\\\\") or after
  end
  local f = env and MATH[env.name] and math_text or plain
  local s = f(before)
  if s == "" then
    s = f(after)
  end
  return s
end

--- Parse .tex source into (labels, included file names). Each label is
--- { key, line, kind (environment or sectioning command), context }.
function M.parse(text)
  text = strip_comments(text)
  local found, includes = {}, {}
  local envs = {} -- open environments, innermost last
  local heading -- the last sectioning command
  local lnum, counted = 1, 1
  local function line_of(i)
    local _, n = text:sub(counted, i - 1):gsub("\n", "")
    lnum, counted = lnum + n, i
    return lnum
  end

  local pos = 1
  while true do
    local s, e, cmd = text:find("\\(%a+)", pos)
    if not s then
      break
    end
    pos = e + 1
    local wanted = cmd == "begin" or cmd == "end" or cmd == "label" or cmd == "caption"
    if wanted or SECTIONS[cmd] or INCLUDES[cmd] then
      local arg, nxt, opt = argument(text, e + 1)
      if arg then
        if cmd == "begin" then
          local env = { name = arg:gsub("%*$", ""), start = nxt }
          local title = text:match("^%s*(%b[])", nxt)
          if title and not FLOATS[env.name] then
            env.title = title:sub(2, -2)
            env.start = nxt + #text:match("^%s*%b[]", nxt)
          end
          envs[#envs + 1] = env
          pos = nxt
        elseif cmd == "end" then
          local name = arg:gsub("%*$", "")
          for i = #envs, 1, -1 do
            if envs[i].name == name then
              envs[i].stop = s
              for j = #envs, i, -1 do
                envs[j] = nil
              end
              break
            end
          end
          pos = nxt
        elseif cmd == "caption" then
          local env = envs[#envs]
          if env and not env.caption then
            env.caption = opt or arg
          end
          -- Keep scanning inside the caption: \caption{...\label{fig:x}} is common.
        elseif SECTIONS[cmd] then
          heading = { kind = cmd, title = opt or arg }
        elseif INCLUDES[cmd] then
          includes[#includes + 1] = vim.trim(arg)
          pos = nxt
        else -- label
          local env
          for i = #envs, 1, -1 do
            if not TRANSPARENT[envs[i].name] then
              env = envs[i]
              break
            end
          end
          found[#found + 1] = { key = vim.trim(arg), at = s, line = line_of(s), env = env, heading = heading }
          pos = nxt
        end
      end
    end
  end

  local labels = {}
  for _, l in ipairs(found) do
    if l.key ~= "" then
      local kind = l.env and l.env.name or (l.heading and l.heading.kind) or ""
      labels[#labels + 1] = { key = l.key, line = l.line, kind = kind, context = describe(text, l) }
    end
  end
  return labels, includes
end

-- Files ------------------------------------------------------------------------

local cache = {} -- path -> { stamp, labels, includes }

local function loaded_buf(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == path then
      return b
    end
  end
end

--- Labels and includes of one file, preferring a loaded buffer's (possibly unsaved) text.
local function load(path, buf)
  buf = buf or loaded_buf(path)
  local stamp, read
  if buf then
    stamp = "buf" .. buf .. ":" .. vim.api.nvim_buf_get_changedtick(buf)
    read = function()
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
  else
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
      return {}, {}
    end
    stamp = ("%d.%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
    read = function()
      local f = io.open(path, "r")
      local text = f and f:read("*a") or ""
      if f then
        f:close()
      end
      return text
    end
  end
  local key = path ~= "" and path or ("buf" .. buf)
  local c = cache[key]
  if not (c and c.stamp == stamp) then
    local labels, includes = M.parse(read())
    for _, l in ipairs(labels) do
      l.file, l.buf = path, path == "" and buf or nil
    end
    c = { stamp = stamp, labels = labels, includes = includes }
    cache[key] = c
  end
  return c.labels, c.includes
end

--- vimtex's own list of the project's source files, if vimtex is active in `buf`.
local function vimtex_sources(buf)
  local ok, sources = pcall(vim.api.nvim_buf_call, buf, function()
    return vim.fn.eval("exists('b:vimtex.root') ? map(b:vimtex.get_sources(), 'b:vimtex.root . \"/\" . v:val') : []")
  end)
  return ok and type(sources) == "table" and sources or {}
end

--- Labels from the buffer, the .tex files in the project directories, vimtex's source
--- list, and anything reached through \input{}, \include{} and \subfile{}.
function M.load_all(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local dirs = files.project_dirs(buf)
  local root = dirs[#dirs]
  local queue, seen = {}, {}
  local function add(path)
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    if not seen[path] then
      seen[path] = true
      queue[#queue + 1] = path
    end
  end

  local all = {}
  local function visit(labels, includes, dir)
    vim.list_extend(all, labels)
    for _, inc in ipairs(includes) do
      -- LaTeX resolves these against the main file's directory; subfiles against their own.
      for _, base in ipairs({ root, dir }) do
        local p = vim.fs.joinpath(base, inc)
        for _, candidate in ipairs({ p, p .. ".tex" }) do
          if vim.fn.filereadable(candidate) == 1 then
            add(candidate)
          end
        end
      end
    end
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    local labels, includes = load("", buf)
    visit(labels, includes, root)
  else
    add(name)
  end
  for _, d in ipairs(dirs) do
    for _, f in ipairs(vim.fn.glob(d .. "/*.tex", false, true)) do
      add(f)
    end
  end
  for _, f in ipairs(vimtex_sources(buf)) do
    add(f)
  end
  local i = 1
  while queue[i] do
    local labels, includes = load(queue[i])
    visit(labels, includes, vim.fs.dirname(queue[i]))
    i = i + 1
  end
  return all
end

--- Current lines of the file a label is in (its buffer's, if loaded).
function M.lines(label)
  local buf = label.buf or loaded_buf(label.file)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  return vim.fn.filereadable(label.file) == 1 and vim.fn.readfile(label.file) or {}
end

return M
