-- Minimal BibTeX parsing, display helpers and duplicate detection (mirrors src/citer/bib.py).
local M = {}

local SKIP_TYPES = { comment = true, string = true, preamble = true }

-- Entries keep offsets into the source text; `raw` and `line` are materialized on first use,
-- since only the previewer, duplicate report and writer need them.
local function line_at(src, offset)
  local nl = src.newlines
  if not nl then
    nl = {}
    local p = 1
    while true do
      local k = src.text:find("\n", p, true)
      if not k then
        break
      end
      nl[#nl + 1] = k
      p = k + 1
    end
    src.newlines = nl
  end
  local lo, hi = 1, #nl -- count newlines before offset
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if nl[mid] < offset then
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return lo
end

local Entry = {
  __index = function(t, k)
    if k == "raw" then
      local v = t._src.text:sub(t._s, t._e)
      rawset(t, "raw", v)
      return v
    elseif k == "line" then
      local v = line_at(t._src, t._s)
      rawset(t, "line", v)
      return v
    end
  end,
}

-- Read one field value at `i` (values end before `last`); returns (raw_value, next_index).
local function read_value(text, i, last)
  local b = text:byte(i)
  if b == 123 then -- {
    local _, e = text:find("^%b{}", i)
    if e and e < last then
      return text:sub(i, e), e + 1
    end
    return text:sub(i, last - 1), last
  elseif b == 34 then -- "
    local depth, j = 0, i + 1
    while true do
      local k = text:find('[{}"]', j)
      if not k or k >= last then
        return text:sub(i, last - 1), last
      end
      local c = text:byte(k)
      if c == 123 then
        depth = depth + 1
      elseif c == 125 then
        depth = depth - 1
      elseif depth == 0 then
        return text:sub(i, k), k + 1
      end
      j = k + 1
    end
  end
  -- Bare value (number, month macro, string concatenation): up to the next comma.
  local _, e = text:find("^[^,}]*", i)
  if e >= last then
    e = last - 1
  end
  return vim.trim(text:sub(i, e)), e + 1
end

local function parse_fields(text, i, last)
  local fields, order = {}, {}
  while i < last do
    local s, e, name = text:find("^[%s,]*([%w_%-%.:]+)%s*=%s*", i)
    if not s or e >= last then
      break
    end
    local raw
    raw, i = read_value(text, e + 1, last)
    name = name:lower()
    fields[name] = raw
    order[#order + 1] = { name = name, raw = raw }
  end
  return fields, order
end

--- Parse BibTeX text into a list of entries:
--- { type, key, fields = {name = raw}, order = {{name, raw}}, raw, line }
function M.parse(text)
  local entries = {}
  local src = { text = text }
  local pos = 1
  while true do
    local s, e, typ = text:find("@%s*(%a+)%s*[{(]", pos)
    if not s then
      break
    end
    local stop -- index of the closing delimiter
    if text:byte(e) == 123 then
      stop = select(2, text:find("^%b{}", e)) or #text
    else
      -- @type( ... ) entries: the first ")" outside braces closes it.
      local depth, j = 0, e + 1
      while true do
        local k = text:find("[{})]", j)
        if not k then
          stop = #text
          break
        end
        local b = text:byte(k)
        if b == 123 then
          depth = depth + 1
        elseif b == 125 then
          depth = depth - 1
        elseif depth == 0 then
          stop = k
          break
        end
        j = k + 1
      end
    end
    typ = typ:lower()
    if not SKIP_TYPES[typ] then
      local _, ke, key = text:find("^%s*([^,%s}]+)%s*,", e + 1)
      if key and ke < stop then
        local fields, order = parse_fields(text, ke + 1, stop)
        entries[#entries + 1] = setmetatable({
          type = typ,
          key = key,
          fields = fields,
          order = order,
          _src = src,
          _s = s,
          _e = stop,
        }, Entry)
      end
    end
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
  if v:find("\\", 1, true) then
    v = v:gsub("\\%a+", ""):gsub("\\.", "")
  end
  if v:find("[{}]") then
    v = v:gsub("[{}]", "")
  end
  if v:find("%s%s") or v:find("[\n\t\r]") then
    v = v:gsub("%s+", " ")
  end
  return vim.trim(v)
end

--- Last names of the first `limit` authors (all if nil), plus whether there were more.
local function split_authors(raw, limit)
  local authors = {}
  if not raw then
    return authors, false
  end
  local s = raw
  if s:sub(1, 1) == "{" or s:sub(1, 1) == '"' then
    s = s:sub(2, -2)
  end
  local pos = 1
  while true do
    local a, b = s:find("%s+and%s+", pos)
    local name = M.clean(s:sub(pos, a and a - 1 or #s))
    if name ~= "" then
      if limit and #authors == limit then
        return authors, true
      end
      table.insert(authors, vim.trim(name:match("^([^,]+),") or name:match("(%S+)$")))
    end
    if not a then
      return authors, false
    end
    pos = b + 1
  end
end

--- Short author string for display: "Smith", "Smith & Jones", "Smith et al."
function M.short_authors(entry)
  local raw = entry.fields.author or entry.fields.editor
  if not raw then
    return M.clean(entry.fields.collaboration)
  end
  local a, more = split_authors(raw, 2)
  if more then
    return a[1] .. " et al."
  elseif #a == 0 then
    return ""
  elseif #a == 1 then
    return a[1]
  end
  return a[1] .. " & " .. a[2]
end

--- All author last names, for fuzzy searching (capped so huge collaborations stay usable).
function M.all_authors(entry)
  return table.concat((split_authors(entry.fields.author or entry.fields.editor, 30)), " ")
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

--- Display fields for the picker, computed once per entry.
function M.display(entry)
  local d = entry._display
  if not d then
    local title, year = M.title(entry), M.year(entry)
    d = {
      authors = M.short_authors(entry),
      title = title,
      year = year,
      ordinal = table.concat({ entry.key, M.all_authors(entry), title, year }, " "),
    }
    entry._display = d
  end
  return d
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
  for _, e in ipairs(entries or {}) do
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

--- `key`, or `key` plus a suffix (a..z, then _2, _3, ...) if a different entry has it.
function M.unique_key(idx, key)
  if not idx.key[key] then
    return key
  end
  for c = string.byte("a"), string.byte("z") do
    local k = key .. string.char(c)
    if not idx.key[k] then
      return k
    end
  end
  local n = 2
  while idx.key[key .. "_" .. n] do
    n = n + 1
  end
  return key .. "_" .. n
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

--- Text to write or preview: the source's own layout, unless it came as a single line.
function M.entry_text(entry, key)
  key = key or entry.key
  if entry.raw:find("\n") then
    return key == entry.key and entry.raw or M.rekey(entry, key)
  end
  return M.format(entry, key)
end

return M
