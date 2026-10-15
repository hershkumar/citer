-- Plugin options. `require("citer.config").options` is the live table after setup().
local M = {}

M.defaults = {
  cmd = "citer", -- the citer executable
  args = {}, -- extra arguments, e.g. { "--published" }
  bib_file = nil, -- always add to this file (relative to the project dir) instead of asking
  default_bib = "references.bib", -- suggested name when the directory has no .bib file
  auto_open = true, -- open the picker when typing \cite{ (and \citep{, \autocite{, ...) or a comma in one
  keymaps = {
    pick = "<leader>ci", -- normal mode: pick and insert \cite{key}
    add = "<leader>ca", -- normal mode: add a paper by URL
    insert_pick = "<C-x>c", -- insert mode: open the picker
    picker_add = "<C-a>", -- inside the picker: fetch a paper not yet in the .bib
  },
}

M.options = vim.deepcopy(M.defaults)

function M.set(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Accept vimscript-style 0/1 from g:citer.
  if M.options.auto_open == 0 then
    M.options.auto_open = false
  end
  return M.options
end

--- Whether a keymap option is set (keymaps can be disabled with "" or false).
function M.enabled(lhs)
  return type(lhs) == "string" and lhs ~= ""
end

return M
