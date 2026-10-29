-- Where the cursor is relative to \cite{...} or \ref{...}, and inserting keys there.
--
-- A "position" is { buf, win, row, col, insert }: row is 1-based, col is the 0-based byte
-- offset to insert at, and `insert` says whether to return to insert mode afterwards.
local M = {}

-- Commands that take label keys: true if they accept a comma-separated list.
M.REF_COMMANDS = {
  ref = false,
  eqref = false,
  pageref = false,
  autoref = false,
  Autoref = false,
  nameref = false,
  Nameref = false,
  vref = false,
  Vref = false,
  vpageref = false,
  fullref = false,
  subref = false,
  cref = true,
  Cref = true,
  cpageref = true,
  Cpageref = true,
  labelcref = true,
  namecref = true,
  nameCref = true,
  zcref = true,
}

--- If `before` (the text before the cursor) ends inside the braces of a citation,
--- reference or graphics command, return (kind, typed, multi): kind is "cite", "ref" or
--- "graphics", typed is what's in the braces so far, and multi says whether the command
--- takes several keys.
function M.context(before)
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
  local cmd = prefix:match("\\(%a+)%*?%s*$")
  if not cmd then
    return nil
  end
  if cmd:find("[cC]ite") then
    return "cite", before:sub(open + 1), true
  end
  if cmd == "includegraphics" then
    return "graphics", before:sub(open + 1), false
  end
  local multi = M.REF_COMMANDS[cmd]
  if multi ~= nil then
    return "ref", before:sub(open + 1), multi
  end
end

--- What's typed so far inside \cite...{...} at the end of `before`, or nil.
function M.cite_context(before)
  local kind, typed = M.context(before)
  if kind == "cite" then
    return typed
  end
end

--- The current cursor as a position. In normal mode, text goes after the cursor character.
function M.current(insert)
  local win = vim.api.nvim_get_current_win()
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  if not insert then
    local len = #vim.api.nvim_get_current_line()
    col = len == 0 and 0 or math.min(col + 1, len)
  end
  return { buf = vim.api.nvim_get_current_buf(), win = win, row = row, col = col, insert = insert }
end

--- Put the cursor back at `pos` (optionally at another column) and resume insert mode if
--- the position was taken in insert mode.
function M.resume(pos, col)
  if not vim.api.nvim_win_is_valid(pos.win) then
    return
  end
  col = col or pos.col
  vim.api.nvim_set_current_win(pos.win)
  vim.api.nvim_win_set_cursor(pos.win, { pos.row, col })
  if pos.insert then
    local line = vim.api.nvim_buf_get_lines(pos.buf, pos.row - 1, pos.row, false)[1] or ""
    -- At end of line, `startinsert` would land before the last character.
    vim.cmd(col >= #line and "startinsert!" or "startinsert")
  end
end

--- Insert a graphics path at `pos`: replacing what's in the braces of the
--- \includegraphics{} the cursor is in, or wrapped in a new one otherwise.
function M.insert_path(pos, path)
  local line = vim.api.nvim_buf_get_lines(pos.buf, pos.row - 1, pos.row, false)[1] or ""
  local here, inside = M.context(line:sub(1, pos.col))
  local start, stop, text = pos.col, pos.col, "\\includegraphics{" .. path .. "}"
  if here == "graphics" then
    start, text = pos.col - #inside, path
    stop = pos.col + #(line:sub(pos.col + 1):match("^[^{}]*") or "")
  end
  vim.api.nvim_buf_set_text(pos.buf, pos.row - 1, start, pos.row - 1, stop, { text })
  M.resume(pos, start + #text)
end

--- Insert keys at `pos`: appended to the command the cursor is in (skipping keys already
--- there), or wrapped in a new one otherwise. `kind` is "cite" (default), "ref" or
--- "graphics"; reference keys outside a \ref-like command are wrapped in `ref_command`.
function M.insert_keys(pos, keys, kind)
  kind = kind or "cite"
  if #keys == 0 or not vim.api.nvim_buf_is_valid(pos.buf) then
    return
  end
  if kind == "graphics" then
    return M.insert_path(pos, keys[1])
  end
  local line = vim.api.nvim_buf_get_lines(pos.buf, pos.row - 1, pos.row, false)[1] or ""
  local here, inside, multi = M.context(line:sub(1, pos.col))
  local text
  if here == kind then
    local present = {}
    for k in (inside .. (line:sub(pos.col + 1):match("^[^}]*") or "")):gmatch("[^,%s]+") do
      present[k] = true
    end
    keys = vim.tbl_filter(function(k)
      return not present[k]
    end, keys)
    if #keys == 0 or (not multi and next(present)) then
      return M.resume(pos)
    end
    if not multi then
      keys = { keys[1] }
    end
    local sep = (inside:match("^%s*$") or inside:match(",%s*$")) and "" or ","
    text = sep .. table.concat(keys, ",")
  elseif kind == "cite" then
    text = "\\cite{" .. table.concat(keys, ",") .. "}"
  else
    local cmd = require("citer.config").options.ref_command
    if M.REF_COMMANDS[cmd] == false then
      text = table.concat(
        vim.tbl_map(function(k)
          return ("\\%s{%s}"):format(cmd, k)
        end, keys),
        ", "
      )
    else
      text = ("\\%s{%s}"):format(cmd, table.concat(keys, ","))
    end
  end
  vim.api.nvim_buf_set_text(pos.buf, pos.row - 1, pos.col, pos.row - 1, pos.col, { text })
  M.resume(pos, pos.col + #text)
end

return M
