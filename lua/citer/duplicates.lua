-- :CiterDuplicates — report entries that duplicate an earlier one across the project.
local bib = require("citer.bib")
local files = require("citer.files")

local M = {}

function M.report(buf)
  local entries = files.load_all(buf)
  local idx = bib.index()
  local items = {}
  for _, e in ipairs(entries) do
    local dup, why = bib.find_duplicate(idx, e)
    if not dup and idx.key[e.key] then
      dup, why = idx.key[e.key], "same key"
    end
    if dup then
      table.insert(items, {
        filename = e.file,
        lnum = e.line,
        text = ("%s duplicates %s (%s:%d, %s)"):format(e.key, dup.key, vim.fs.basename(dup.file), dup.line, why),
      })
    else
      bib.add_to_index(idx, e)
    end
  end
  if #items == 0 then
    return vim.notify(("citer: no duplicates among %d entries"):format(#entries))
  end
  vim.fn.setqflist({}, " ", { title = "citer duplicates", items = items })
  vim.cmd("copen")
end

return M
