if vim.g.loaded_citer then
  return
end
vim.g.loaded_citer = true

-- Use defaults (or `g:citer` from vimscript) unless setup() was already called in init.
local citer = require("citer")
if not citer._configured then
  citer.setup(vim.g.citer or {})
end
