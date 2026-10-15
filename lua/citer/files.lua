-- Finding, reading (with a per-file cache) and appending to the project's .bib files.
local bib = require("citer.bib")
local config = require("citer.config")

local M = {}

--- Directories searched for .bib files: the buffer's own directory and the vimtex root.
function M.project_dirs(buf)
  buf = buf or 0
  local name = vim.api.nvim_buf_get_name(buf)
  local candidates = { name ~= "" and vim.fs.dirname(name) or vim.uv.cwd() }
  local ok, vimtex = pcall(vim.api.nvim_buf_get_var, buf, "vimtex")
  if ok and type(vimtex) == "table" and vimtex.root then
    table.insert(candidates, vimtex.root)
  end
  local dirs, seen = {}, {}
  for _, d in ipairs(candidates) do
    d = vim.fs.normalize(d)
    if not seen[d] then
      seen[d] = true
      table.insert(dirs, d)
    end
  end
  return dirs
end

function M.bib_files(buf)
  local files = {}
  for _, d in ipairs(M.project_dirs(buf)) do
    vim.list_extend(files, vim.fn.glob(d .. "/*.bib", false, true))
  end
  return files
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

local cache = {} -- path -> { mtime, size, entries }

--- Entries of one .bib file (each tagged with `file`), re-parsed only when the file changes.
function M.load(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}
  end
  local mtime = stat.mtime.sec * 1e9 + stat.mtime.nsec
  local c = cache[path]
  if c and c.mtime == mtime and c.size == stat.size then
    return c.entries
  end
  local entries = bib.parse(read_file(path) or "")
  for _, e in ipairs(entries) do
    e.file = path
  end
  cache[path] = { mtime = mtime, size = stat.size, entries = entries }
  return entries
end

--- Entries of every .bib file in the project.
function M.load_all(buf)
  local all = {}
  for _, f in ipairs(M.bib_files(buf)) do
    vim.list_extend(all, M.load(f))
  end
  return all
end

--- The project .bib file named by \bibliography{} or \addbibresource{} in the buffer, if any.
local function referenced(buf, files)
  local by_name = {}
  for _, f in ipairs(files) do
    by_name[vim.fs.basename(f)] = f
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  for list in text:gmatch("\\bibliography%s*{([^}]*)}") do
    for name in list:gmatch("[^,%s]+") do
      local f = by_name[name] or by_name[name .. ".bib"]
      if f then
        return f
      end
    end
  end
  for name in text:gmatch("\\addbibresource%s*%b[]*%s*{([^}]*)}") do
    if by_name[vim.fs.basename(name)] then
      return by_name[vim.fs.basename(name)]
    end
  end
end

--- Choose the .bib file new entries go into (asking if needed), then call cb(path).
function M.choose_target(buf, cb)
  local opts = config.options
  local dirs = M.project_dirs(buf)
  local root = dirs[#dirs]
  if opts.bib_file then
    return cb(vim.fs.joinpath(root, opts.bib_file))
  end
  local files = M.bib_files(buf)
  if #files == 1 then
    return cb(files[1])
  end
  if #files > 1 then
    local f = referenced(buf, files)
    if f then
      return cb(f)
    end
    return vim.ui.select(files, {
      prompt = "Add to which .bib file?",
      format_item = function(path)
        return vim.fn.fnamemodify(path, ":~:.")
      end,
    }, function(choice)
      if choice then
        cb(choice)
      end
    end)
  end
  vim.ui.input({ prompt = "New .bib file: ", default = opts.default_bib }, function(name)
    if name and name ~= "" then
      cb(vim.fs.joinpath(root, name))
    end
  end)
end

--- Append entry texts to `path`, keeping one blank line between entries. Raises on failure.
function M.append(path, chunks)
  local existing = read_file(path) or ""
  local lead = ""
  if existing ~= "" then
    lead = existing:match("\n\n$") and "" or (existing:match("\n$") and "\n" or "\n\n")
  end
  local f, err = io.open(path, "a")
  if not f then
    error(err)
  end
  f:write(lead .. table.concat(chunks, "\n\n") .. "\n")
  f:close()
  vim.cmd("checktime") -- reload the .bib if it's open in a buffer
end

return M
