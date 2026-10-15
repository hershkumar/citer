-- Plugin tests. Run from the repo root:
--   nvim --headless --clean -c "luafile tests/nvim/run.lua"
-- (not `-l`: the picker tests need the main loop to process typed keys between steps).
-- Picker tests also run if Telescope is found: set CITER_TEST_RTP to a comma-separated list
-- of plugin directories (e.g. plenary.nvim and telescope.nvim) to add to the runtimepath.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.rtp:prepend(root)
for dir in (os.getenv("CITER_TEST_RTP") or ""):gmatch("[^,]+") do
  vim.opt.rtp:prepend(dir)
end
vim.o.swapfile = false
vim.o.showmode = false
vim.g.tex_flavor = "latex" -- empty .tex files are otherwise detected as plaintex

local bib = require("citer.bib")
local cursor = require("citer.cursor")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(("FAIL %s\n%s\n"):format(name, err))
  end
end
local function eq(actual, expected, what)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(what or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end
local function wait(cond, ms)
  if not vim.wait(ms or 3000, cond, 20) then
    error("timed out", 2)
  end
end

-- Async tests run as coroutines resumed from timers, so Nvim processes typeahead between steps.
local async_tests = {}
local function async_test(name, fn)
  table.insert(async_tests, { name = name, fn = fn })
end
local function await(cond, ms)
  local deadline = vim.uv.hrtime() + (ms or 3000) * 1e6
  while true do
    local ok, res = pcall(cond)
    if ok and res then
      return
    end
    if vim.uv.hrtime() > deadline then
      error("timed out", 2)
    end
    coroutine.yield()
  end
end
local function run_async(i, done)
  local t = async_tests[i]
  if not t then
    return done()
  end
  local co = coroutine.create(t.fn)
  local function step()
    local ok, err = coroutine.resume(co)
    if not ok then
      failed = failed + 1
      io.stderr:write(("FAIL %s\n%s\n"):format(t.name, debug.traceback(co, err)))
    elseif coroutine.status(co) == "dead" then
      passed = passed + 1
    else
      return vim.defer_fn(step, 20)
    end
    run_async(i + 1, done)
  end
  step()
end

local FIXTURE = [[
@misc{vaswani2023attentionneed,
      title={Attention Is All You Need},
      author={Ashish Vaswani and Noam Shazeer and Niki Parmar},
      year={2023},
      eprint={1706.03762},
      archivePrefix={arXiv},
}

@Article{LeCun2015,
author="LeCun, Yann
and Bengio, Yoshua",
title="Deep {learning}",
year="2015",
doi="10.1038/nature14539"
}

@comment{ignored}
@article{Jordan_2012, title={Quantum Algorithms for Quantum Field Theories}, DOI={10.1126/science.1217069}, author={Jordan, Stephen P. and K{\"u}bra, A.}, year={2012}, month=June }
]]

-- bib ------------------------------------------------------------------------

test("parse keys, lines and fields", function()
  local es = bib.parse(FIXTURE)
  eq(vim.tbl_map(function(e)
    return e.key
  end, es), { "vaswani2023attentionneed", "LeCun2015", "Jordan_2012" })
  eq(vim.tbl_map(function(e)
    return e.line
  end, es), { 1, 9, 18 })
  eq(es[2].fields.title, '"Deep {learning}"')
  eq(es[3].fields.month, "June")
  eq(es[1].raw:sub(-1), "}")
end)

test("display fields", function()
  local es = bib.parse(FIXTURE)
  eq(bib.display(es[1]).authors, "Vaswani et al.")
  eq(bib.display(es[2]).authors, "LeCun & Bengio")
  eq(bib.display(es[2]).title, "Deep learning")
  eq(bib.display(es[3]).authors, "Jordan & Kubra")
  eq(bib.display(es[3]).year, "2012")
end)

test("identity and duplicates", function()
  local es = bib.parse(FIXTURE)
  eq(bib.arxiv(es[1]), "1706.03762")
  eq(bib.doi(es[2]), "10.1038/nature14539")
  local idx = bib.index(es)
  local function dup(text)
    return select(2, bib.find_duplicate(idx, bib.parse(text)[1]))
  end
  eq(dup("@article{x, doi={10.1038/NATURE14539}}"), "same DOI")
  eq(dup("@misc{x, title={Other}, eprint={1706.03762}}"), "same arXiv ID")
  eq(dup("@misc{x, title={Attention is all you need.}}"), "same title")
  eq(dup("@misc{x, title={New}}"), nil)
  eq(bib.unique_key(idx, "LeCun2015"), "LeCun2015a")
end)

test("entry_text keeps multi-line layout and reformats single-line entries", function()
  local es = bib.parse(FIXTURE)
  eq(bib.entry_text(es[1]), es[1].raw)
  eq(bib.entry_text(es[2], "New").sub(bib.entry_text(es[2], "New"), 1, 13), "@Article{New,")
  local lines = vim.split(bib.entry_text(es[3]), "\n")
  eq(lines[1], "@article{Jordan_2012,")
  eq(lines[#lines - 1], "  month = June")
end)

-- cursor ---------------------------------------------------------------------

test("cite_context", function()
  eq(cursor.cite_context("\\cite{"), "")
  eq(cursor.cite_context("see \\citep[p.~3]{a,"), "a,")
  eq(cursor.cite_context("\\autocite[see][]{foo"), "foo")
  eq(cursor.cite_context("\\textbf{"), nil)
  eq(cursor.cite_context("\\cite{a} and {"), nil)
end)

local function buffer_with(line)
  vim.cmd("enew!")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
  return { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(), row = 1, insert = false }
end

test("insert_keys wraps, appends and skips keys already cited", function()
  local pos = buffer_with("See ")
  pos.col = 4
  cursor.insert_keys(pos, { "a" })
  eq(vim.api.nvim_get_current_line(), "See \\cite{a}")

  pos.col = 11 -- before the closing brace
  cursor.insert_keys(pos, { "b", "a" })
  eq(vim.api.nvim_get_current_line(), "See \\cite{a,b}")

  pos.col = 13
  cursor.insert_keys(pos, { "a", "b" })
  eq(vim.api.nvim_get_current_line(), "See \\cite{a,b}")
end)

-- add (with a stand-in for the citer CLI) --------------------------------------

test("add appends new entries, skips duplicates and inserts keys", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(vim.split(FIXTURE, "\n"), dir .. "/refs.bib")
  local fake = dir .. "/fake-citer"
  vim.fn.writefile({
    "#!/bin/sh",
    "cat <<'EOF'",
    "@article{PhysRevB.98.045131,",
    "  title = {Tunable topological semimetal states},",
    "  doi = {10.1103/PhysRevB.98.045131}",
    "}",
    "",
    "@misc{dupe, title={Deep Learning}}",
    "EOF",
    "echo 'error: bogus: not a URL, DOI or arXiv ID' >&2",
  }, fake)
  vim.fn.setfperm(fake, "rwx------")
  require("citer.config").set({ cmd = fake })

  vim.cmd("edit " .. dir .. "/main.tex")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "See \\cite{}" })
  local notes = {}
  local notify = vim.notify
  vim.notify = function(msg)
    table.insert(notes, msg)
  end
  local pos = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(), row = 1, col = 10 }
  require("citer.add").add({ "x", "y" }, { pos = pos })
  wait(function()
    return vim.api.nvim_get_current_line() ~= "See \\cite{}"
  end)
  vim.notify = notify

  eq(vim.api.nvim_get_current_line(), "See \\cite{PhysRevB.98.045131,LeCun2015}")
  local keys = vim.tbl_map(function(e)
    return e.key
  end, bib.parse(table.concat(vim.fn.readfile(dir .. "/refs.bib"), "\n")))
  eq(keys, { "vaswani2023attentionneed", "LeCun2015", "Jordan_2012", "PhysRevB.98.045131" })
  local msg = notes[#notes]
  assert(msg:find("added PhysRevB.98.045131") and msg:find("already have LeCun2015") and msg:find("error: bogus"), msg)
  require("citer.config").set({})
end)

-- picker (needs Telescope) ------------------------------------------------------

if pcall(require, "telescope") then
  local function keys(k)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "t", false)
  end
  local function selected()
    return require("telescope.actions.state").get_selected_entry().value.key
  end
  local function in_picker()
    return vim.bo.filetype == "TelescopePrompt"
  end

  async_test("picker opens on \\cite{ and after a comma; <C-j>/<C-k> move; <Esc> cancels", function()
    require("citer").setup({})
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.split(FIXTURE, "\n"), dir .. "/refs.bib")
    vim.cmd("edit " .. dir .. "/main.tex")
    eq(vim.bo.filetype, "tex")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "See " })

    keys("A\\cite{")
    await(in_picker)
    keys("lecun")
    await(function()
      return selected() == "LeCun2015"
    end)
    keys("<CR>")
    await(function()
      return not in_picker() and vim.api.nvim_get_current_line():find("LeCun2015")
    end)
    eq(vim.api.nvim_get_current_line(), "See \\cite{LeCun2015")
    eq(vim.fn.mode(), "i")

    keys(",")
    await(function()
      return in_picker() and selected()
    end)
    local first = selected()
    keys("<C-j>")
    await(function()
      return selected() ~= first
    end)
    keys("<C-k>")
    await(function()
      return selected() == first
    end)
    keys("<Esc>")
    await(function()
      return not in_picker()
    end)
    eq(vim.api.nvim_get_current_line(), "See \\cite{LeCun2015,")
    eq(vim.fn.mode(), "i")
    keys("<Esc>")
  end)
else
  io.stderr:write("skip: picker tests (Telescope not on runtimepath; see CITER_TEST_RTP)\n")
end

run_async(1, function()
  io.stderr:write(("%d passed, %d failed\n"):format(passed, failed))
  os.exit(failed == 0 and 0 or 1)
end)
