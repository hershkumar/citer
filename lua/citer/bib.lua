-- Minimal BibTeX parsing, display helpers and duplicate detection.
local M = {}

local SKIP_TYPES = { comment = true, string = true, preamble = true }

-- Read one field value starting at `i` in `body`; returns (raw_value, next_index).
local function read_value(body, i)
  local c = body:sub(i, i)
  if c == "{" then
    local s, e = body:find("^%b{}", i)
    if s then
      return body:sub(s, e), e + 1
    end
    return body:sub(i), #body + 1
  elseif c == '"' then
    local depth, j = 0, i + 1
    while j <= #body do
      local ch = body:sub(j, j)
      if ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
      elseif ch == '"' and depth == 0 then
        return body:sub(i, j), j + 1
      end
      j = j + 1
    end
    return body:sub(i), #body + 1
  end
  -- Bare value (number, month macro, string concatenation): up to the next comma.
  local s, e = body:find("^[^,]*", i)
  return vim.trim(body:sub(s, e)), e + 1
end

local function parse_fields(body)
  local fields, order = {}, {}
  local i = 1
  while i <= #body do
    local s, e, name = body:find("^[%s,]*([%w_%-%.:]+)%s*=%s*", i)
    if not s then
      break
    end
    local raw
    raw, i = read_value(body, e + 1)
    name = name:lower()
    fields[name] = raw
    table.insert(order, { name = name, raw = raw })
  end
  return fields, order
end

--- Parse BibTeX text into a list of entries:
--- { type, key, fields = {name = raw}, order = {{name, raw}}, raw, line }
function M.parse(text)
  local entries = {}
  local pos, line = 1, 1
  while true do
    local s, e, typ = text:find("@%s*(%a+)%s*[{(]", pos)
    if not s then
      break
    end
    local _, nl = text:sub(pos, s - 1):gsub("\n", "")
    line = line + nl
    local entry_line = line
    local close = text:sub(e, e) == "{" and "}" or ")"
    local depth, j = 1, e + 1
    while j <= #text and depth > 0 do
      local ch = text:sub(j, j)
      if ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
      end
      if close == ")" and ch == ")" and depth == 1 then
        depth = 0
      end
      j = j + 1
    end
    local stop = j - 1
    typ = typ:lower()
    if not SKIP_TYPES[typ] then
      local body = text:sub(e + 1, stop - 1)
      local key, rest = body:match("^%s*([^,%s]+)%s*,(.*)$")
      if key then
        local fields, order = parse_fields(rest)
        table.insert(entries, {
          type = typ,
          key = key,
          fields = fields,
          order = order,
          raw = text:sub(s, stop),
          line = entry_line,
        })
      end
    end
    local _, inner = text:sub(s, stop):gsub("\n", "")
    line = line + inner
    pos = stop + 1
  end
  return entries
end

--- Strip delimiters, braces and LaTeX markup from a raw field value.
function M.clean(raw)
  if not raw then
    return ""
  end
  local v = raw
  if v:sub(1, 1) == '"' and v:sub(-1) == '"' then
    v = v:sub(2, -2)
  end
  v = v:gsub("\\%a+", ""):gsub("\\.", ""):gsub("[{}]", ""):gsub("%s+", " ")
  return vim.trim(v)
end

local function split_authors(raw)
  local authors = {}
  local s = M.clean(raw)
  for _, a in ipairs(vim.split(s, "%s+and%s+")) do
    a = vim.trim(a)
    if a ~= "" then
      local last = a:match("^([^,]+),") or a:match("(%S+)$")
      table.insert(authors, vim.trim(last))
    end
  end
  return authors
end

--- Short author string for display: "Smith", "Smith & Jones", "Smith et al."
function M.short_authors(entry)
  local raw = entry.fields.author or entry.fields.editor
  if not raw then
    return M.clean(entry.fields.collaboration)
  end
  local a = split_authors(raw)
  if #a == 0 then
    return ""
  elseif #a == 1 then
    return a[1]
  elseif #a == 2 then
    return a[1] .. " & " .. a[2]
  end
  return a[1] .. " et al."
end

--- All author last names, for fuzzy searching (capped so huge collaborations stay usable).
function M.all_authors(entry)
  local a = split_authors(entry.fields.author or entry.fields.editor or "")
  return table.concat(vim.list_slice(a, 1, 30), " ")
end

function M.title(entry)
  return M.clean(entry.fields.title)
end

function M.year(entry)
  local y = M.clean(entry.fields.year)
  if y == "" and entry.fields.date then
    y = M.clean(entry.fields.date):match("%d%d%d%d") or ""
  end
  return y
end

-- Identity --------------------------------------------------------------------

function M.doi(entry)
  local d = entry.fields.doi and M.clean(entry.fields.doi)
  if not d or d == "" then
    d = (entry.fields.url and M.clean(entry.fields.url):match("doi%.org/(10%..+)$"))
  end
  if not d or d == "" then
    return nil
  end
  d = d:gsub("^https?://[^/]*doi%.org/", ""):gsub("^doi:", "")
  return d:lower()
end

local function match_arxiv(s)
  return s:match("(%d%d%d%d%.%d%d%d%d%d?)") or s:match("([%a%-]+%.?%a*/%d%d%d%d%d%d%d)")
end

function M.arxiv(entry)
  local f = entry.fields
  local prefix = M.clean(f.archiveprefix or f.eprinttype or ""):lower()
  if f.eprint and (prefix == "arxiv" or prefix == "") then
    local id = match_arxiv(M.clean(f.eprint))
    if id then
      return id
    end
  end
  for _, name in ipairs({ "url", "journal", "note", "howpublished" }) do
    local v = f[name] and M.clean(f[name])
    if v and v:lower():find("arxiv") then
      local id = match_arxiv(v)
      if id then
        return id
      end
    end
  end
end

function M.norm_title(entry)
  local t = M.title(entry):lower():gsub("[^%w]", "")
  return t ~= "" and t or nil
end

--- Build lookup tables over existing entries for duplicate checks.
function M.index(entries)
  local idx = { doi = {}, arxiv = {}, title = {}, key = {} }
  for _, e in ipairs(entries) do
    M.add_to_index(idx, e)
  end
  return idx
end

function M.add_to_index(idx, e)
  local d, a, t = M.doi(e), M.arxiv(e), M.norm_title(e)
  if d then
    idx.doi[d] = idx.doi[d] or e
  end
  if a then
    idx.arxiv[a] = idx.arxiv[a] or e
  end
  if t then
    idx.title[t] = idx.title[t] or e
  end
  idx.key[e.key] = idx.key[e.key] or e
end

--- Return (existing_entry, reason) if `e` is already present in the index.
function M.find_duplicate(idx, e)
  local d, a, t = M.doi(e), M.arxiv(e), M.norm_title(e)
  if d and idx.doi[d] then
    return idx.doi[d], "same DOI"
  end
  if a and idx.arxiv[a] then
    return idx.arxiv[a], "same arXiv ID"
  end
  if t and idx.title[t] then
    return idx.title[t], "same title"
  end
end

-- Writing ---------------------------------------------------------------------

--- Re-emit an entry in a uniform multi-line layout (values are kept verbatim).
function M.format(entry, key)
  local lines = { ("@%s{%s,"):format(entry.type, key or entry.key) }
  for i, f in ipairs(entry.order) do
    local sep = i < #entry.order and "," or ""
    table.insert(lines, ("  %s = %s%s"):format(f.name, f.raw, sep))
  end
  table.insert(lines, "}")
  return table.concat(lines, "\n")
end

--- Rename the key of an entry's raw text.
function M.rekey(entry, key)
  local escaped = vim.pesc(entry.key)
  return (entry.raw:gsub("^(@%s*%a+%s*[{(]%s*)" .. escaped, "%1" .. key:gsub("%%", "%%%%"), 1))
end

return M
