-- Telescope picker over the project's .bib entries.
local bib = require("citer.bib")
local config = require("citer.config")
local cursor = require("citer.cursor")
local files = require("citer.files")

local M = {}

--- Open the picker; selected keys are inserted at opts.pos (default: the cursor).
function M.pick(opts)
  opts = opts or {}
  local pos = opts.pos or cursor.current(vim.fn.mode():sub(1, 1) == "i")
  local entries = files.load_all(pos.buf)
  local add_key = config.options.keymaps.picker_add

  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local displayer = entry_display.create({
    separator = " │ ",
    items = { { width = 22 }, { width = 22 }, { width = 4 }, { remaining = true } },
  })

  local function make_entry(e)
    local d = bib.display(e)
    return {
      value = e,
      ordinal = d.ordinal,
      display = function()
        return displayer({
          { e.key, "TelescopeResultsIdentifier" },
          { d.authors, "TelescopeResultsConstant" },
          { d.year, "TelescopeResultsNumber" },
          d.title,
        })
      end,
    }
  end

  local previewer = require("telescope.previewers").new_buffer_previewer({
    title = "BibTeX",
    define_preview = function(self, entry)
      local e = entry.value
      local lines = vim.split(bib.entry_text(e), "\n")
      table.insert(lines, 1, ("%% %s:%d"):format(vim.fn.fnamemodify(e.file, ":~:."), e.line))
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      vim.bo[self.state.bufnr].filetype = "bib"
      vim.wo[self.state.winid].wrap = true
    end,
  })

  local function attach_mappings(prompt_bufnr, map)
    -- Close the picker, then run `fn` once focus is back in the original window.
    local function close_then(fn)
      return function()
        actions.close(prompt_bufnr)
        vim.schedule(fn)
      end
    end

    actions.select_default:replace(function()
      local selected = action_state.get_current_picker(prompt_bufnr):get_multi_selection()
      if #selected == 0 then
        selected = { action_state.get_selected_entry() }
      end
      local keys = {}
      for _, s in ipairs(selected) do
        table.insert(keys, s.value.key)
      end
      close_then(function()
        cursor.insert_keys(pos, keys)
      end)()
    end)

    local cancel = close_then(function()
      cursor.resume(pos)
    end)
    map({ "i", "n" }, "<Esc>", cancel)
    map({ "i", "n" }, "<C-c>", cancel)
    map({ "i", "n" }, "<C-j>", actions.move_selection_next)
    map({ "i", "n" }, "<C-k>", actions.move_selection_previous)
    if config.enabled(add_key) then
      map(
        { "i", "n" },
        add_key,
        close_then(function()
          require("citer.add").prompt(pos)
        end)
      )
    end
    return true
  end

  local hint = config.enabled(add_key) and (" · %s add new"):format(add_key) or ""
  require("telescope.pickers")
    .new({}, {
      prompt_title = ("Citations (%d)  <Tab> multi%s"):format(#entries, hint),
      finder = require("telescope.finders").new_table({ results = entries, entry_maker = make_entry }),
      sorter = require("telescope.config").values.generic_sorter({}),
      previewer = previewer,
      attach_mappings = attach_mappings,
    })
    :find()
end

return M
