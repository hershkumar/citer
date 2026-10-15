-- Where the cursor is relative to \cite{...}, and inserting keys there.
--
-- A "position" is { buf, win, row, col, insert }: row is 1-based, col is the 0-based byte
-- offset to insert at, and `insert` says whether to return to insert mode afterwards.
local M = {}

--- If `before` (the text before the cursor) ends inside \cite...{...}, return what's typed
--- in the braces so far; otherwise nil.
function M.cite_context(before)
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

--- Insert citation keys at `pos`: appended to the \cite{} the cursor is in (skipping keys
--- already there), or wrapped in a new \cite{} otherwise.
function M.insert_keys(pos, keys)
  if #keys == 0 or not vim.api.nvim_buf_is_valid(pos.buf) then
    return
  end
  local line = vim.api.nvim_buf_get_lines(pos.buf, pos.row - 1, pos.row, false)[1] or ""
  local inside = M.cite_context(line:sub(1, pos.col))
  local text
  if inside then
    local present = {}
    for k in (inside .. (line:sub(pos.col + 1):match("^[^}]*") or "")):gmatch("[^,%s]+") do
      present[k] = true
    end
    keys = vim.tbl_filter(function(k)
      return not present[k]
    end, keys)
    if #keys == 0 then
      return M.resume(pos)
    end
    local sep = (inside:match("^%s*$") or inside:match(",%s*$")) and "" or ","
    text = sep .. table.concat(keys, ",")
  else
    text = "\\cite{" .. table.concat(keys, ",") .. "}"
  end
  vim.api.nvim_buf_set_text(pos.buf, pos.row - 1, pos.col, pos.row - 1, pos.col, { text })
  M.resume(pos, pos.col + #text)
end

return M
