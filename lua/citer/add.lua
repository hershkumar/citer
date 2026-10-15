-- Adding papers: run the citer CLI, skip duplicates, append the rest to the project .bib.
local bib = require("citer.bib")
local config = require("citer.config")
local cursor = require("citer.cursor")
local files = require("citer.files")

local M = {}

--- Merge citer's output into `path`; returns the keys to cite (new or already present).
local function merge(res, path, buf)
  local errors = {}
  for l in (res.stderr or ""):gmatch("[^\n]+") do
    if l:match("^error:") then
      table.insert(errors, l)
    end
  end
  local new = bib.parse(res.stdout or "")
  if #new == 0 then
    local msg = #errors > 0 and table.concat(errors, "\n") or "citer returned no BibTeX"
    vim.notify("citer: " .. msg, vim.log.levels.ERROR)
    return {}
  end

  -- Check against every .bib in the project, plus the target if it lives elsewhere.
  local existing = files.load_all(buf)
  if not vim.tbl_contains(files.bib_files(buf), path) then
    vim.list_extend(existing, files.load(path))
  end
  local idx = bib.index(existing)
  local name = vim.fs.basename(path)

  local keys, chunks, msgs = {}, {}, {}
  for _, e in ipairs(new) do
    local dup, why = bib.find_duplicate(idx, e)
    if dup then
      table.insert(keys, dup.key)
      table.insert(msgs, ("already have %s in %s (%s)"):format(dup.key, vim.fs.basename(dup.file or path), why))
    else
      local key = bib.unique_key(idx, e.key)
      table.insert(chunks, bib.entry_text(e, key))
      table.insert(keys, key)
      e.key, e.file = key, path
      bib.add_to_index(idx, e)
      table.insert(msgs, ("added %s to %s"):format(key, name))
    end
  end
  if #chunks > 0 then
    local ok, err = pcall(files.append, path, chunks)
    if not ok then
      vim.notify(("citer: could not write %s: %s"):format(path, err), vim.log.levels.ERROR)
      return {}
    end
  end
  vim.list_extend(msgs, errors)
  vim.notify("citer: " .. table.concat(msgs, "\n"), #errors > 0 and vim.log.levels.WARN or nil)
  return keys
end

--- Fetch BibTeX for `targets` (URLs, DOIs, arXiv IDs) and add it to the project .bib.
--- opts.pos: a cursor position to insert the resulting keys at (optional).
function M.add(targets, opts)
  opts = opts or {}
  local o = config.options
  if vim.fn.executable(o.cmd) == 0 then
    return vim.notify(("citer: `%s` not found on PATH"):format(o.cmd), vim.log.levels.ERROR)
  end
  local buf = vim.api.nvim_get_current_buf()
  files.choose_target(buf, function(path)
    local cmd = vim.list_extend({ o.cmd }, vim.deepcopy(o.args))
    vim.list_extend(cmd, targets)
    vim.notify("citer: fetching " .. table.concat(targets, ", ") .. " ...")
    vim.system(cmd, { text = true }, function(res)
      vim.schedule(function()
        local keys = merge(res, path, buf)
        if opts.pos then
          cursor.insert_keys(opts.pos, keys)
        end
      end)
    end)
  end)
end

--- Ask for papers to add; inserts their keys at `pos` if given.
function M.prompt(pos)
  vim.ui.input({ prompt = "Paper URL / DOI / arXiv ID: " }, function(input)
    input = input and vim.trim(input) or ""
    if input ~= "" then
      M.add(vim.split(input, "%s+"), { pos = pos })
    elseif pos then
      cursor.resume(pos)
    end
  end)
end

return M
