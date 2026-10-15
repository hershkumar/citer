-- citer.nvim: pick citations from local .bib files, and add new ones via the `citer` CLI.
local bib = require("citer.bib")

local M = {}

M.config = {
  cmd = "citer", -- the citer executable
  args = {}, -- extra arguments, e.g. { "--published" }
  bib_file = nil, -- always add to this file (relative to the project dir) instead of asking
  default_bib = "references.bib", -- suggested name when the directory has no .bib file
  auto_open = true, -- open the picker when typing \cite{ (and \citep{, \autocite{, ...)
  keymaps = {
    pick = "<leader>ci", -- normal mode: pick and insert \cite{key}
    add = "<leader>ca", -- normal mode: add a paper by URL
    insert_pick = "<C-x>c", -- insert mode: open the picker
    picker_add = "<C-a>", -- inside the picker: fetch a paper not yet in the .bib
  },
}

local function enabled(lhs)
  return type(lhs) == "string" and lhs ~= ""
end

-- Files -------------------------------------------------------------------------

--- Directories searched for .bib files: the file's own directory and the vimtex root.
local function project_dirs(buf)
  buf = buf or 0
  local dirs, seen = {}, {}
  local name = vim.api.nvim_buf_get_name(buf)
  local candidates = { name ~= "" and vim.fs.dirname(name) or vim.uv.cwd() }
  local ok, vt = pcall(vim.api.nvim_buf_get_var, buf, "vimtex")
  if ok and type(vt) == "table" and vt.root then
    table.insert(candidates, vt.root)
  end
  for _, d in ipairs(candidates) do
    d = vim.fs.normalize(d)
    if not seen[d] then
      seen[d] = true
      table.insert(dirs, d)
    end
  end
  return dirs
end

local function bib_files(buf)
  local files = {}
  for _, d in ipairs(project_dirs(buf)) do
    for _, f in ipairs(vim.fn.glob(d .. "/*.bib", false, true)) do
      table.insert(files, f)
    end
  end
  return files
end

local cache = {}

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

local function load_bib(path)
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

local function load_all(buf)
  local all = {}
  for _, f in ipairs(bib_files(buf)) do
    vim.list_extend(all, load_bib(f))
  end
  return all
end

--- Choose the .bib file new entries go into, then call cb(path).
local function target_bib(buf, cb)
  local dirs = project_dirs(buf)
  local root = dirs[#dirs]
  if M.config.bib_file then
    return cb(vim.fs.joinpath(root, M.config.bib_file))
  end
  local files = bib_files(buf)
  if #files == 1 then
    return cb(files[1])
  end
  if #files > 1 then
    -- Prefer a file the document actually references.
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    for list in text:gmatch("\\bibliography%s*{([^}]*)}") do
      for name in list:gmatch("[^,%s]+") do
        for _, f in ipairs(files) do
          if vim.fs.basename(f) == name or vim.fs.basename(f) == name .. ".bib" then
            return cb(f)
          end
        end
      end
    end
    for name in text:gmatch("\\addbibresource%s*%b[]*%s*{([^}]*)}") do
      for _, f in ipairs(files) do
        if vim.fs.basename(f) == vim.fs.basename(name) then
          return cb(f)
        end
      end
    end
    return vim.ui.select(files, {
      prompt = "Add to which .bib file?",
      format_item = function(f)
        return vim.fn.fnamemodify(f, ":~:.")
      end,
    }, function(choice)
      if choice then
        cb(choice)
      end
    end)
  end
  vim.ui.input({ prompt = "New .bib file: ", default = M.config.default_bib }, function(name)
    if name and name ~= "" then
      cb(vim.fs.joinpath(root, name))
    end
  end)
end

-- Cursor context ----------------------------------------------------------------

--- If the text before the cursor is inside \cite...{...}, return what's typed in the braces.
local function cite_context(before)
  local open = before:match("^.*(){[^{}]*$")
  if not open then
    return nil
  end
  local prefix = before:sub(1, open - 1)
  -- Drop optional arguments: \cite[p.~3]{, \autocite[see][]{
  while prefix:match("%]%s*$") do
    local stripped = prefix:gsub("%s*%b[]%s*$", "")
    if stripped == prefix then
      break
    end
    prefix = stripped
  end
  if prefix:match("\\%a*[cC]ite%a*%*?%s*$") then
    return before:sub(open + 1)
  end
end

--- Insert keys at (row, col), wrapping them in \cite{} unless already inside one.
local function insert_keys(pos, keys)
  if #keys == 0 then
    return
  end
  local buf, win, row, col = pos.buf, pos.win, pos.row, pos.col
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local inside = cite_context(line:sub(1, col))
  local text
  if inside then
    -- Skip keys already cited in these braces.
    local present = {}
    for k in (inside .. (line:sub(col + 1):match("^[^}]*") or "")):gmatch("[^,%s]+") do
      present[k] = true
    end
    keys = vim.tbl_filter(function(k)
      return not present[k]
    end, keys)
    if #keys == 0 then
      if pos.insert then
        vim.api.nvim_win_set_cursor(win, { row, col })
        vim.cmd(col >= #line and "startinsert!" or "startinsert")
      end
      return
    end
    local sep = (inside:match("^%s*$") or inside:match(",%s*$")) and "" or ","
    text = sep .. table.concat(keys, ",")
  else
    text = "\\cite{" .. table.concat(keys, ",") .. "}"
  end
  vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { text })
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row, col + #text })
  end
  if pos.insert then
    vim.cmd(col + #text >= #line + #text and "startinsert!" or "startinsert")
  end
end

local function cursor_pos(insert)
  local win = vim.api.nvim_get_current_win()
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  if not insert then
    -- In normal mode, insert after the character under the cursor.
    local line = vim.api.nvim_get_current_line()
    col = math.min(col + 1, #line)
    if #line == 0 then
      col = 0
    end
  end
  return { buf = vim.api.nvim_get_current_buf(), win = win, row = row, col = col, insert = insert }
end

-- Adding papers -----------------------------------------------------------------

local function append(path, chunks)
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
  vim.cmd("checktime")
end

local function unique_key(key, idx)
  if not idx.key[key] then
    return key
  end
  for c = string.byte("a"), string.byte("z") do
    local k = key .. string.char(c)
    if not idx.key[k] then
      return k
    end
  end
  return key .. "_" .. os.time()
end

--- Fetch BibTeX for `targets` with citer, skip duplicates, append the rest.
--- opts.pos: where to insert the resulting keys (optional).
function M.add(targets, opts)
  opts = opts or {}
  if vim.fn.executable(M.config.cmd) == 0 then
    return vim.notify("citer: `" .. M.config.cmd .. "` not found on PATH", vim.log.levels.ERROR)
  end
  local buf = vim.api.nvim_get_current_buf()
  target_bib(buf, function(path)
    local cmd = vim.list_extend({ M.config.cmd }, vim.deepcopy(M.config.args))
    vim.list_extend(cmd, targets)
    vim.notify("citer: fetching " .. table.concat(targets, ", ") .. " ...")
    vim.system(cmd, { text = true }, function(res)
      vim.schedule(function()
        M._finish_add(res, path, buf, opts)
      end)
    end)
  end)
end

function M._finish_add(res, path, buf, opts)
  local errors = {}
  for l in (res.stderr or ""):gmatch("[^\n]+") do
    if l:match("^error:") then
      table.insert(errors, l)
    end
  end
  local new = bib.parse(res.stdout or "")
  if #new == 0 then
    local msg = #errors > 0 and table.concat(errors, "\n") or "citer returned no BibTeX"
    return vim.notify("citer: " .. msg, vim.log.levels.ERROR)
  end

  local all = load_all(buf)
  if not vim.tbl_contains(bib_files(buf), path) then
    vim.list_extend(all, load_bib(path))
  end
  local idx = bib.index(all)
  local keys, chunks, msgs = {}, {}, {}
  for _, e in ipairs(new) do
    local dup, why = bib.find_duplicate(idx, e)
    if dup then
      table.insert(keys, dup.key)
      table.insert(
        msgs,
        ("already have %s in %s (%s)"):format(dup.key, vim.fn.fnamemodify(dup.file or path, ":t"), why)
      )
    else
      local key = unique_key(e.key, idx)
      local text = e.raw:find("\n") and bib.rekey(e, key) or bib.format(e, key)
      table.insert(chunks, text)
      table.insert(keys, key)
      e.key, e.file = key, path
      bib.add_to_index(idx, e)
      table.insert(msgs, ("added %s to %s"):format(key, vim.fn.fnamemodify(path, ":t")))
    end
  end
  if #chunks > 0 then
    local ok, err = pcall(append, path, chunks)
    if not ok then
      return vim.notify("citer: could not write " .. path .. ": " .. err, vim.log.levels.ERROR)
    end
  end
  vim.list_extend(msgs, errors)
  vim.notify("citer: " .. table.concat(msgs, "\n"), #errors > 0 and vim.log.levels.WARN or nil)
  if opts.pos then
    insert_keys(opts.pos, keys)
  end
end

local function prompt_add(pos)
  vim.ui.input({ prompt = "Paper URL / DOI / arXiv ID: " }, function(input)
    if input and vim.trim(input) ~= "" then
      M.add(vim.split(vim.trim(input), "%s+"), { pos = pos })
    elseif pos and pos.insert then
      vim.api.nvim_set_current_win(pos.win)
      vim.cmd("startinsert")
    end
  end)
end

-- Picker ------------------------------------------------------------------------

function M.pick(opts)
  opts = opts or {}
  local pos = opts.pos or cursor_pos(vim.fn.mode():sub(1, 1) == "i")
  local entries = load_all(pos.buf)

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")
  local entry_display = require("telescope.pickers.entry_display")

  local displayer = entry_display.create({
    separator = " │ ",
    items = { { width = 22 }, { width = 22 }, { width = 4 }, { remaining = true } },
  })

  local function restore()
    if pos.insert and vim.api.nvim_win_is_valid(pos.win) then
      vim.api.nvim_set_current_win(pos.win)
      vim.api.nvim_win_set_cursor(pos.win, { pos.row, pos.col })
      local line = vim.api.nvim_buf_get_lines(pos.buf, pos.row - 1, pos.row, false)[1] or ""
      vim.cmd(pos.col >= #line and "startinsert!" or "startinsert")
    end
  end

  pickers
    .new({}, {
      prompt_title = ("Citations (%d)  <Tab> multi%s"):format(
        #entries,
        enabled(M.config.keymaps.picker_add) and (" · %s add new"):format(M.config.keymaps.picker_add) or ""
      ),
      finder = finders.new_table({
        results = entries,
        entry_maker = function(e)
          local authors, title, year = bib.short_authors(e), bib.title(e), bib.year(e)
          return {
            value = e,
            ordinal = table.concat({ e.key, bib.all_authors(e), title, year }, " "),
            display = function()
              return displayer({
                { e.key, "TelescopeResultsIdentifier" },
                { authors, "TelescopeResultsConstant" },
                { year, "TelescopeResultsNumber" },
                title,
              })
            end,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "BibTeX",
        define_preview = function(self, entry)
          local e = entry.value
          local lines = vim.split(e.raw:find("\n") and e.raw or bib.format(e), "\n")
          table.insert(lines, 1, "% " .. vim.fn.fnamemodify(e.file, ":~:.") .. ":" .. e.line)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = "bib"
          vim.wo[self.state.winid].wrap = true
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local picker = action_state.get_current_picker(prompt_bufnr)
          local selected = picker:get_multi_selection()
          if #selected == 0 then
            selected = { action_state.get_selected_entry() }
          end
          actions.close(prompt_bufnr)
          local keys = {}
          for _, s in ipairs(selected) do
            if s then
              table.insert(keys, s.value.key)
            end
          end
          vim.schedule(function()
            insert_keys(pos, keys)
          end)
        end)
        map({ "i", "n" }, "<Esc>", function()
          actions.close(prompt_bufnr)
          vim.schedule(restore)
        end)
        map({ "i", "n" }, "<C-c>", function()
          actions.close(prompt_bufnr)
          vim.schedule(restore)
        end)
        map({ "i", "n" }, "<C-j>", actions.move_selection_next)
        map({ "i", "n" }, "<C-k>", actions.move_selection_previous)
        if enabled(M.config.keymaps.picker_add) then
          map({ "i", "n" }, M.config.keymaps.picker_add, function()
            actions.close(prompt_bufnr)
            vim.schedule(function()
              prompt_add(pos)
            end)
          end)
        end
        return true
      end,
    })
    :find()
end

-- Duplicates report -------------------------------------------------------------

function M.duplicates()
  local entries = load_all(0)
  local idx = { doi = {}, arxiv = {}, title = {}, key = {} }
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
        text = ("%s duplicates %s (%s:%d, %s)"):format(
          e.key,
          dup.key,
          vim.fn.fnamemodify(dup.file, ":t"),
          dup.line,
          why
        ),
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

-- Setup -------------------------------------------------------------------------

local function attach(buf)
  local km = M.config.keymaps
  if enabled(km.pick) then
    vim.keymap.set("n", km.pick, function()
      M.pick()
    end, { buffer = buf, desc = "citer: insert citation" })
  end
  if enabled(km.add) then
    vim.keymap.set("n", km.add, function()
      prompt_add(nil)
    end, { buffer = buf, desc = "citer: add paper by URL" })
  end
  if enabled(km.insert_pick) then
    vim.keymap.set("i", km.insert_pick, function()
      M.pick({ pos = cursor_pos(true) })
    end, { buffer = buf, desc = "citer: insert citation" })
  end
  if M.config.auto_open and M.config.auto_open ~= 0 then
    vim.api.nvim_create_autocmd("TextChangedI", {
      buffer = buf,
      group = "citer",
      callback = function()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local before = vim.api.nvim_get_current_line():sub(1, col)
        local last = before:sub(-1)
        local inside = (last == "{" or last == ",") and cite_context(before)
        if (last == "{" and inside == "") or (last == "," and inside) then
          local pos = cursor_pos(true)
          vim.schedule(function()
            M.pick({ pos = pos })
          end)
        end
      end,
    })
  end
end

function M.setup(opts)
  M._configured = true
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  vim.api.nvim_create_augroup("citer", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = "citer",
    pattern = { "tex", "plaintex", "markdown" },
    callback = function(ev)
      attach(ev.buf)
    end,
  })
  vim.api.nvim_create_user_command("CiterPick", function()
    M.pick()
  end, { desc = "Pick a citation from local .bib files" })
  vim.api.nvim_create_user_command("CiterAdd", function(a)
    if #a.fargs == 0 then
      prompt_add(nil)
    else
      M.add(a.fargs)
    end
  end, { nargs = "*", desc = "Fetch BibTeX with citer and add it to the project .bib" })
  vim.api.nvim_create_user_command("CiterDuplicates", function()
    M.duplicates()
  end, { desc = "List duplicate entries across the project's .bib files" })
end

-- Exposed for testing.
M._cite_context = cite_context
M._insert_keys = insert_keys

return M
