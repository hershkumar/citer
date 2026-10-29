local M = {}

function M.check()
  local health = vim.health
  health.start("citer")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10+ is required (uses vim.system, vim.uv, vim.fs.joinpath)")
  end

  if pcall(require, "telescope") then
    health.ok("telescope.nvim found")
  else
    health.error("telescope.nvim not found", { "Install nvim-telescope/telescope.nvim" })
  end

  local graphics = require("citer.graphics")
  local backend = graphics.backend()
  if backend then
    health.ok("graphics previews: " .. backend)
  else
    health.info("graphics previews: file info only", {
      "Use kitty, Ghostty or WezTerm (outside tmux), or install chafa",
    })
  end
  for _, ext in ipairs({ "pdf", "jpg", "svg", "eps" }) do
    local conv = graphics.converter(ext)
    if conv then
      health.ok((".%s previews via %s"):format(ext, conv[1]))
    else
      health.info(("no converter for .%s previews"):format(ext), { "Install poppler (pdftoppm) or ImageMagick" })
    end
  end

  local cmd = require("citer.config").options.cmd
  if vim.fn.executable(cmd) == 1 then
    health.ok(("`%s` found at %s"):format(cmd, vim.fn.exepath(cmd)))
  else
    health.error(("`%s` not found on $PATH"):format(cmd), {
      "Install it with: uv tool install <path to this plugin>",
      "or with vim-plug: Plug 'hershkumar/citer', { 'do': 'uv tool install --reinstall .' }",
    })
  end
end

return M
