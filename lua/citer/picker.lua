-- Telescope pickers over the project's .bib entries, \label{}s and image files.
local bib = require("citer.bib")
local config = require("citer.config")
local cursor = require("citer.cursor")
local files = require("citer.files")

local M = {}

local function position(opts)
  return opts.pos or cursor.current(vim.fn.mode():sub(1, 1) == "i")
end

--- Open a picker whose selection inserts keys at `pos`.
--- spec: { pos, kind ("cite"/"ref"/"graphics"), title, results, columns, entry_maker, previewer,
---         default_text, mappings = function(map, close_then, prompt_bufnr) (optional) }
local function open(spec)
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local pos = spec.pos

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
        cursor.insert_keys(pos, keys, spec.kind)
      end)()
    end)

    local cancel = close_then(function()
      cursor.resume(pos)
    end)
    map({ "i", "n" }, "<Esc>", cancel)
    map({ "i", "n" }, "<C-c>", cancel)
    map({ "i", "n" }, "<C-j>", actions.move_selection_next)
    map({ "i", "n" }, "<C-k>", actions.move_selection_previous)
    if spec.mappings then
      spec.mappings(map, close_then, prompt_bufnr)
    end
    return true
  end

  require("telescope.pickers")
    .new({}, {
      prompt_title = spec.title,
      default_text = spec.default_text,
      finder = require("telescope.finders").new_table({ results = spec.results, entry_maker = spec.entry_maker }),
      sorter = require("telescope.config").values.generic_sorter({}),
      previewer = spec.previewer,
      attach_mappings = attach_mappings,
    })
    :find()
end

--- Citation picker; selected keys are inserted at opts.pos (default: the cursor).
function M.pick(opts)
  opts = opts or {}
  local pos = position(opts)
  local entries = files.load_all(pos.buf)
  local add_key = config.options.keymaps.picker_add

  local displayer = require("telescope.pickers.entry_display").create({
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

  local hint = config.enabled(add_key) and (" · %s add new"):format(add_key) or ""
  open({
    pos = pos,
    kind = "cite",
    title = ("Citations (%d)  <Tab> multi%s"):format(#entries, hint),
    results = entries,
    entry_maker = make_entry,
    previewer = previewer,
    mappings = function(map, close_then)
      if config.enabled(add_key) then
        map(
          { "i", "n" },
          add_key,
          close_then(function()
            require("citer.add").prompt(pos)
          end)
        )
      end
    end,
  })
end

local preview_ns = vim.api.nvim_create_namespace("citer_preview")

--- Label picker for \ref{} and friends; selected keys are inserted at opts.pos.
function M.pick_ref(opts)
  opts = opts or {}
  local pos = position(opts)
  local labels = require("citer.labels")
  local results = labels.load_all(pos.buf)

  local displayer = require("telescope.pickers.entry_display").create({
    separator = " │ ",
    items = { { width = 28 }, { width = 12 }, { remaining = true } },
  })

  local function make_entry(l)
    return {
      value = l,
      ordinal = table.concat({ l.key, l.kind, l.context }, " "),
      display = function()
        return displayer({
          { l.key, "TelescopeResultsIdentifier" },
          { l.kind, "TelescopeResultsConstant" },
          l.context,
        })
      end,
    }
  end

  local previewer = require("telescope.previewers").new_buffer_previewer({
    title = "Label",
    define_preview = function(self, entry)
      local l, bufnr, winid = entry.value, self.state.bufnr, self.state.winid
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, labels.lines(l))
      -- Highlight without setting 'filetype', which would attach citer to the preview.
      require("telescope.previewers.utils").highlighter(bufnr, "tex")
      vim.api.nvim_buf_clear_namespace(bufnr, preview_ns, 0, -1)
      if l.line > vim.api.nvim_buf_line_count(bufnr) then
        return
      end
      vim.api.nvim_buf_set_extmark(bufnr, preview_ns, l.line - 1, 0, { line_hl_group = "TelescopePreviewLine" })
      -- The window only shows the buffer once this returns (as in Telescope's grep previewer).
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
          vim.api.nvim_win_set_cursor(winid, { l.line, 0 })
          vim.api.nvim_win_call(winid, function()
            vim.cmd("normal! zz")
          end)
        end
      end)
    end,
  })

  open({
    pos = pos,
    kind = "ref",
    title = ("Labels (%d)  <Tab> multi"):format(#results),
    results = results,
    entry_maker = make_entry,
    previewer = previewer,
  })
end

--- Graphics picker for \includegraphics{}; the selected path is inserted at opts.pos.
function M.pick_graphics(opts)
  opts = opts or {}
  local pos = position(opts)
  local graphics = require("citer.graphics")
  local results = graphics.find(pos.buf)
  local backend = graphics.backend()
  -- Prefill the prompt with a path already being typed in the braces.
  local line = vim.api.nvim_buf_get_lines(pos.buf, pos.row - 1, pos.row, false)[1] or ""
  local kind, typed = cursor.context(line:sub(1, pos.col))

  local function entry_maker(img)
    return {
      value = img,
      ordinal = img.rel,
      display = function()
        -- Directory dimmed and file name highlighted, so the tree structure reads at a glance.
        local mark, ext = img.used and "● " or "  ", ("%-5s"):format(img.ext)
        local str = mark .. ext .. img.dir .. img.name
        local e1, e2 = #mark, #mark + #ext
        local e3 = e2 + #img.dir
        return str,
          {
            { { 0, e1 }, "TelescopeResultsConstant" },
            { { e1, e2 }, "TelescopeResultsNumber" },
            { { e2, e3 }, "Comment" },
            { { e3, #str }, "TelescopeResultsIdentifier" },
          }
      end,
    }
  end

  local current -- the entry being previewed, so late thumbnails for other entries are dropped
  local previewer = require("telescope.previewers").new_buffer_previewer({
    title = "Image",
    define_preview = function(self, entry)
      local img, bufnr, winid = entry.value, self.state.bufnr, self.state.winid
      current = img
      if backend == "kitty" then
        graphics.kitty_clear()
      end
      local function header(dims, note)
        local lines = { graphics.describe(img, dims) }
        if note then
          lines[#lines + 1] = note
        end
        return lines
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, header(nil, backend and "loading…" or nil))
      if not backend then
        return
      end
      graphics.png(img, function(png, err)
        if current ~= img or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        local dims = png and graphics.png_size(png)
        if not dims then
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, header(nil, err or "can't read image"))
          return
        end
        if backend == "chafa" then
          return graphics.chafa_show(bufnr, winid, png, header(dims))
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, header(dims))
        -- Draw once the window shows this buffer (it does after define_preview returns).
        vim.schedule(function()
          if current == img and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            graphics.kitty_show(winid, png, dims, 2)
          end
        end)
      end)
    end,
    teardown = function()
      current = nil
      if backend == "kitty" then
        graphics.kitty_clear()
      end
    end,
  })

  open({
    pos = pos,
    kind = "graphics",
    title = ("Graphics (%d)  ● used"):format(#results),
    results = results,
    entry_maker = entry_maker,
    previewer = previewer,
    default_text = kind == "graphics" and typed or nil,
    mappings = function(_, _, prompt_bufnr)
      if backend ~= "kitty" then
        return
      end
      -- With no matches Telescope doesn't call the previewer, so take the image down here.
      vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = prompt_bufnr,
        callback = function()
          vim.defer_fn(function()
            local ok, entry = pcall(require("telescope.actions.state").get_selected_entry)
            if current and not (ok and entry) then
              current = nil
              graphics.kitty_clear()
            end
          end, 100)
        end,
      })
    end,
  })
end

return M
