-- citer.nvim: pick citations from local .bib files, and add new ones via the `citer` CLI;
-- pick \ref{} targets from the project's \label{}s, and \includegraphics{} paths from its
-- image files.
--
-- Modules: config (options), bib (parsing, duplicates), files (.bib discovery and cache),
-- labels (\label{} discovery), graphics (image discovery and previews),
-- cursor (\cite/\ref/\includegraphics context and insertion),
-- picker (Telescope UI), add (citer CLI), duplicates (:CiterDuplicates).
local config = require("citer.config")
local cursor = require("citer.cursor")

local M = {}

-- Public API -------------------------------------------------------------------

function M.pick(opts)
  require("citer.picker").pick(opts)
end

function M.pick_ref(opts)
  require("citer.picker").pick_ref(opts)
end

function M.pick_graphics(opts)
  require("citer.picker").pick_graphics(opts)
end

function M.add(targets, opts)
  require("citer.add").add(targets, opts)
end

function M.duplicates()
  require("citer.duplicates").report(0)
end

-- Setup ------------------------------------------------------------------------

local GROUP = "citer"

--- Parse the project's .bib files (and build display data) before the first picker open.
local function prewarm(buf)
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      local bib = require("citer.bib")
      for _, e in ipairs(require("citer.files").load_all(buf)) do
        bib.display(e)
      end
    end
  end, 300)
end

--- Open a picker after typing `\cite{`, `\ref{` or `\includegraphics{` (or a `,` inside a
--- command that takes a list).
local function auto_open()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = vim.api.nvim_get_current_line():sub(1, col)
  local last = before:sub(-1)
  if last ~= "{" and last ~= "," then
    return
  end
  local kind, inside, multi = cursor.context(before)
  if kind and ((last == "{" and inside == "") or (last == "," and multi)) then
    local pos = cursor.current(true)
    vim.schedule(function()
      if kind == "cite" then
        M.pick({ pos = pos })
      elseif kind == "ref" then
        M.pick_ref({ pos = pos })
      else
        M.pick_graphics({ pos = pos })
      end
    end)
  end
end

local function attach(buf)
  local opts = config.options
  local km = opts.keymaps
  local function map(mode, lhs, fn, desc)
    if config.enabled(lhs) then
      vim.keymap.set(mode, lhs, fn, { buffer = buf, desc = desc })
    end
  end

  -- FileType can fire again for the same buffer (e.g. when a plugin manager lazy-loads a
  -- plugin with ftdetect files); replace this buffer's handler rather than stacking another.
  vim.api.nvim_clear_autocmds({ group = GROUP, buffer = buf })

  prewarm(buf)
  map("n", km.pick, M.pick, "citer: insert citation")
  map("i", km.insert_pick, function()
    M.pick({ pos = cursor.current(true) })
  end, "citer: insert citation")
  map("n", km.ref_pick, M.pick_ref, "citer: insert reference")
  map("i", km.insert_ref_pick, function()
    M.pick_ref({ pos = cursor.current(true) })
  end, "citer: insert reference")
  map("n", km.graphics_pick, M.pick_graphics, "citer: insert graphic")
  map("i", km.insert_graphics_pick, function()
    M.pick_graphics({ pos = cursor.current(true) })
  end, "citer: insert graphic")
  map("n", km.add, function()
    require("citer.add").prompt(nil)
  end, "citer: add paper by URL")
  if opts.auto_open then
    vim.api.nvim_create_autocmd("TextChangedI", { buffer = buf, group = GROUP, callback = auto_open })
  end
end

function M.setup(opts)
  M._configured = true
  config.set(opts)
  vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = GROUP,
    pattern = { "tex", "plaintex" },
    callback = function(ev)
      attach(ev.buf)
    end,
  })

  vim.api.nvim_create_user_command("CiterPick", function()
    M.pick()
  end, { desc = "Pick a citation from local .bib files" })
  vim.api.nvim_create_user_command("CiterRef", function()
    M.pick_ref()
  end, { desc = "Pick a \\label{} from the project's .tex files" })
  vim.api.nvim_create_user_command("CiterGraphics", function()
    M.pick_graphics()
  end, { desc = "Pick an image file for \\includegraphics{}" })
  vim.api.nvim_create_user_command("CiterAdd", function(a)
    if #a.fargs == 0 then
      require("citer.add").prompt(nil)
    else
      M.add(a.fargs)
    end
  end, { nargs = "*", desc = "Fetch BibTeX with citer and add it to the project .bib" })
  vim.api.nvim_create_user_command("CiterDuplicates", M.duplicates, {
    desc = "List duplicate entries across the project's .bib files",
  })
end

return M
