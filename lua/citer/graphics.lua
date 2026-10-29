-- Image files in the project, for the \includegraphics{} picker, and their previews.
--
-- Previews are drawn with the Kitty graphics protocol (kitty, Ghostty, WezTerm) on top of
-- the Telescope preview window, or as coloured text with `chafa`. Formats the terminal
-- can't show directly (PDF, JPEG, EPS, SVG) are converted to cached PNG thumbnails.
local config = require("citer.config")
local files = require("citer.files")

local M = {}

-- Directories never worth descending into.
local SKIP_DIRS = { node_modules = true, __pycache__ = true, venv = true }

--- Text of the buffer, plus the vimtex main file if that's a different file.
local function sources_text(buf)
  local parts = { table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") }
  local ok, vimtex = pcall(vim.api.nvim_buf_get_var, buf, "vimtex")
  local main = ok and type(vimtex) == "table" and vimtex.tex
  if main and vim.fs.normalize(main) ~= vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) then
    local f = io.open(main, "r")
    if f then
      parts[#parts + 1] = f:read("*a")
      f:close()
    end
  end
  return table.concat(parts, "\n")
end

--- Directories listed in \graphicspath{{a/}{b/}}, as written.
function M.graphicspath(text)
  local dirs = {}
  for list in text:gmatch("\\graphicspath%s*(%b{})") do
    for d in list:sub(2, -2):gmatch("{([^{}]*)}") do
      d = vim.trim(d)
      if d ~= "" then
        dirs[#dirs + 1] = d
      end
    end
  end
  return dirs
end

--- Paths already used in \includegraphics{} (without extensions), as a set.
function M.used(text)
  local set = {}
  for arg in text:gmatch("\\includegraphics%*?%s*[^{\n]-(%b{})") do
    local p = vim.trim(arg:sub(2, -2))
    set[(p:gsub("%.%w+$", ""))] = true
  end
  return set
end

local function under(path, dir)
  if path:sub(1, #dir + 1) == dir .. "/" then
    return path:sub(#dir + 2)
  end
end

--- Format a byte count like "52 KB".
local function human(n)
  for _, unit in ipairs({ "B", "KB", "MB" }) do
    if n < 1024 then
      return ("%d %s"):format(n, unit)
    end
    n = n / 1024
  end
  return ("%.1f GB"):format(n)
end

--- Image files under the project root and the \graphicspath directories. Each is
--- { key (the path to insert), path (absolute), rel (relative to the root), dir, name,
---   ext, size, mtime, used }.
function M.find(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local opts = config.options.graphics
  local dirs = files.project_dirs(buf)
  local root = dirs[#dirs]
  local text = sources_text(buf)

  local exts = {}
  for _, e in ipairs(opts.extensions) do
    exts[e:lower()] = true
  end
  -- Searched directories, and the prefixes LaTeX would put in front of a picked path.
  local gpaths = {}
  for _, d in ipairs(M.graphicspath(text)) do
    local abs = vim.fs.normalize(vim.fn.fnamemodify(vim.fs.joinpath(root, d), ":p")):gsub("/$", "")
    gpaths[#gpaths + 1] = abs
  end
  local used = M.used(text)

  local found, seen = {}, {}
  local function scan(dir)
    if vim.fn.isdirectory(dir) == 0 then
      return
    end
    local tex = {} -- a PDF next to a .tex of the same name is a compiled document
    local candidates = {}
    for name, type in vim.fs.dir(dir, {
      depth = opts.depth,
      skip = function(d)
        local base = vim.fs.basename(d)
        return not (base:sub(1, 1) == "." or SKIP_DIRS[base] or base:match("^_minted"))
      end,
    }) do
      if type == "file" or type == "link" then
        local ext = name:match("%.([^./]+)$")
        ext = ext and ext:lower()
        if ext == "tex" then
          tex[vim.fs.joinpath(dir, name:sub(1, -5))] = true
        elseif ext and exts[ext] then
          candidates[#candidates + 1] = { name = name, ext = ext }
        end
      end
      if #candidates >= opts.max_files then
        break
      end
    end
    for _, c in ipairs(candidates) do
      local path = vim.fs.joinpath(dir, c.name)
      if not seen[path] and not (c.ext == "pdf" and tex[path:sub(1, -5)]) then
        seen[path] = true
        local stat = vim.uv.fs_stat(path)
        if stat and stat.type == "file" then
          local key = under(path, root) or path
          for _, gp in ipairs(gpaths) do
            local rest = under(path, gp)
            if rest then
              key = rest
              break
            end
          end
          local rel = under(path, root) or vim.fn.fnamemodify(path, ":~:.")
          found[#found + 1] = {
            key = key,
            path = path,
            rel = rel,
            dir = rel:match("^(.*/)") or "",
            name = vim.fs.basename(path),
            ext = c.ext,
            size = stat.size,
            mtime = stat.mtime.sec,
            used = used[(key:gsub("%.%w+$", ""))] or false,
          }
        end
      end
    end
  end

  scan(root)
  for _, gp in ipairs(gpaths) do
    if not under(gp, root) and gp ~= root then
      scan(gp)
    end
  end
  -- Tree order: by directory, then name.
  table.sort(found, function(a, b)
    if a.dir ~= b.dir then
      return a.dir < b.dir
    end
    return a.name < b.name
  end)
  return found
end

--- One line describing a file: its path, pixel size (once known), size and date.
function M.describe(img, dims)
  local parts = { img.rel }
  if dims then
    parts[#parts + 1] = ("%d×%d"):format(dims[1], dims[2])
  end
  parts[#parts + 1] = human(img.size)
  parts[#parts + 1] = os.date("%Y-%m-%d %H:%M", img.mtime)
  return table.concat(parts, "  ·  ")
end

-- Thumbnails ----------------------------------------------------------------------

local THUMB_PX = 1024

-- Converters to PNG, tried in order; {in} and {out} are replaced with paths.
local CONVERTERS = {
  pdf = {
    { "pdftoppm", "-png", "-singlefile", "-scale-to", THUMB_PX, "{in}", "{out_noext}" },
    { "mutool", "draw", "-q", "-w", THUMB_PX, "-o", "{out}", "{in}", "1" },
    { "magick", "-density", "150", "{in}[0]", "-resize", THUMB_PX .. "x" .. THUMB_PX .. ">", "{out}" },
    { "sips", "-s", "format", "png", "-Z", THUMB_PX, "{in}", "--out", "{out}" },
  },
  svg = {
    { "rsvg-convert", "-w", THUMB_PX, "-o", "{out}", "{in}" },
    { "magick", "{in}", "-resize", THUMB_PX .. "x" .. THUMB_PX .. ">", "{out}" },
    { "sips", "-s", "format", "png", "-Z", THUMB_PX, "{in}", "--out", "{out}" },
  },
  eps = {
    { "magick", "-density", "150", "{in}[0]", "-resize", THUMB_PX .. "x" .. THUMB_PX .. ">", "{out}" },
  },
  raster = {
    { "magick", "{in}[0]", "-resize", THUMB_PX .. "x" .. THUMB_PX .. ">", "{out}" },
    { "sips", "-s", "format", "png", "-Z", THUMB_PX, "{in}", "--out", "{out}" },
  },
}
CONVERTERS.ps = CONVERTERS.eps

--- The command converting `ext` files to PNG, or nil if no converter is installed.
function M.converter(ext)
  for _, cmd in ipairs(CONVERTERS[ext] or CONVERTERS.raster) do
    if vim.fn.executable(cmd[1]) == 1 then
      return cmd
    end
  end
end

local function thumb_dir()
  local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "citer", "thumbs")
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Call cb(png_path) with a PNG of `img` (the file itself, or a cached thumbnail), or
--- cb(nil, reason) if it can't be made.
function M.png(img, cb)
  if img.ext == "png" then
    return cb(img.path)
  end
  local id = vim.fn.sha256(("%s:%d:%d"):format(img.path, img.mtime, img.size)):sub(1, 24)
  local out = vim.fs.joinpath(thumb_dir(), id .. ".png")
  if vim.uv.fs_stat(out) then
    return cb(out)
  end
  local cmd = M.converter(img.ext)
  if not cmd then
    return cb(nil, ("no converter for .%s files (install poppler, ImageMagick or librsvg)"):format(img.ext))
  end
  local tmp = out .. ".tmp"
  local args = vim.tbl_map(function(a)
    a = tostring(a)
    return (a:gsub("{in}", function()
      return img.path
    end):gsub("{out_noext}", function()
      return tmp
    end):gsub("{out}", function()
      return tmp .. ".png"
    end))
  end, cmd)
  vim.system(args, {}, function(res)
    vim.schedule(function()
      if res.code == 0 and vim.uv.fs_rename(tmp .. ".png", out) then
        cb(out)
      else
        os.remove(tmp .. ".png")
        cb(nil, ("%s failed: %s"):format(cmd[1], vim.trim(res.stderr or "")))
      end
    end)
  end)
end

--- Pixel width and height of a PNG file, from its header.
function M.png_size(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local head = f:read(24)
  f:close()
  if not head or #head < 24 or head:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil
  end
  local function u32(i)
    local a, b, c, d = head:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return { u32(17), u32(21) }
end

-- Terminal output -----------------------------------------------------------------

--- Which preview backend to use: "kitty", "chafa" or nil (file info only).
function M.backend()
  local want = config.options.graphics.preview
  if want == "kitty" or want == "chafa" then
    return want
  end
  if want ~= "auto" then
    return nil
  end
  local term, prog = vim.env.TERM or "", vim.env.TERM_PROGRAM or ""
  local kitty = term == "xterm-kitty" or term == "xterm-ghostty" or vim.env.KITTY_WINDOW_ID
    or prog == "ghostty" or prog == "WezTerm"
  -- Inside tmux, screen positions are relative to the pane, not the terminal.
  if kitty and not vim.env.TMUX and #vim.api.nvim_list_uis() > 0 then
    return "kitty"
  end
  if vim.fn.executable("chafa") == 1 then
    return "chafa"
  end
end

local function send(data)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(data)
  else
    vim.fn.chansend(vim.v.stderr, data)
  end
end

--- Height / width of a terminal cell in pixels (2 if the terminal doesn't say).
local cell_ratio = (function()
  local ratio
  return function()
    if ratio then
      return ratio
    end
    ratio = 2
    local ok, ffi = pcall(require, "ffi")
    if not ok then
      return ratio
    end
    pcall(ffi.cdef, [[
      struct citer_winsize { unsigned short row, col, xpixel, ypixel; };
      int ioctl(int fd, unsigned long request, ...);
    ]])
    local request = jit.os == "OSX" and 0x40087468 or 0x5413 -- TIOCGWINSZ
    local ws = ffi.new("struct citer_winsize")
    for fd = 0, 2 do
      local called, res = pcall(ffi.C.ioctl, fd, request, ws)
      if called and res == 0 and ws.xpixel > 0 and ws.row > 0 then
        ratio = (ws.ypixel / ws.row) / (ws.xpixel / ws.col)
        break
      end
    end
    return ratio
  end
end)()

local IMAGE_ID = 31337

local function apc(control, payload)
  return ("\27_G%s%s\27\\"):format(control, payload and (";" .. payload) or "")
end

--- Remove the image drawn by kitty_show(), if any.
function M.kitty_clear()
  send(apc(("a=d,d=I,i=%d,q=2"):format(IMAGE_ID)))
end

--- Draw the PNG at `png` over window `win`, below its first `skip` lines, scaled to fit.
function M.kitty_show(win, png, dims, skip)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local f = io.open(png, "rb")
  if not f then
    return
  end
  local data = vim.base64.encode(f:read("*a"))
  f:close()

  local row, col = unpack(vim.fn.win_screenpos(win))
  local border = vim.api.nvim_win_get_config(win).border
  if border and border ~= "none" and not (type(border) == "table" and #border == 0) then
    row, col = row + 1, col + 1
  end
  local width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) - skip
  if width < 2 or height < 2 then
    return
  end
  -- Fit the image (aspect ratio in cells: pixel ratio times cell height/width) in the window.
  local aspect = dims[1] / dims[2] * cell_ratio()
  local cols, rows = width, math.floor(width / aspect + 0.5)
  if rows > height then
    rows, cols = height, math.floor(height * aspect + 0.5)
  end
  cols, rows = math.max(cols, 1), math.max(rows, 1)

  local out = { apc(("a=d,d=I,i=%d,q=2"):format(IMAGE_ID)) }
  local CHUNK = 4096
  for i = 1, #data, CHUNK do
    local more = i + CHUNK <= #data and 1 or 0
    local control = i == 1
        and ("a=T,f=100,t=d,i=%d,q=2,C=1,c=%d,r=%d,m=%d"):format(IMAGE_ID, cols, rows, more)
      or ("q=2,m=%d"):format(more)
    out[#out + 1] = apc(control, data:sub(i, i + CHUNK - 1))
  end
  local at = ("\27[%d;%dH"):format(row + skip, col + math.floor((width - cols) / 2))
  -- Save and restore the cursor so the TUI's idea of where it is stays right.
  send("\0277" .. at .. table.concat(out) .. "\0278")
end

--- Render `png` with chafa into the (fresh, unmodified) buffer `bufnr` as a terminal,
--- below the `header` lines.
function M.chafa_show(bufnr, win, png, header)
  local width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) - #header
  local size = ("%dx%d"):format(width, math.max(height, 1))
  vim.system({ "chafa", "--format", "symbols", "--animate", "off", "--size", size, png }, {}, function(res)
    vim.schedule(function()
      if res.code ~= 0 or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
      local chan = vim.api.nvim_open_term(bufnr, {})
      local body = table.concat(header, "\r\n") .. "\r\n" .. res.stdout:gsub("\r?\n", "\r\n")
      vim.api.nvim_chan_send(chan, body)
    end)
  end)
end

return M
