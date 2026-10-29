# citer

> [!WARNING]
> This project (both the CLI and the Neovim plugin) is fully vibecoded: it was written by an
> AI assistant with minimal human review. Use it at your own risk, and keep your `.bib` files
> under version control or backed up, since the tool writes to them.

Fetch BibTeX for a paper from the publisher's (or arXiv's) own export endpoint, and pick
citations from your `.bib` files (and `\ref{}` targets from your `\label{}`s, and
`\includegraphics{}` paths from your image files, with previews) in Neovim.

Install the CLI with `uv tool install .` (or see [Neovim plugin](#neovim-plugin), which
installs both).

```sh
uv run citer https://journals.aps.org/prxquantum/abstract/10.1103/PRXQuantum.4.027001
uv run citer https://arxiv.org/pdf/1602.03837v1           # arXiv's BibTeX export
uv run citer -p https://arxiv.org/abs/1602.03837          # journal version if published
uv run citer -s inspire 1602.03837                        # INSPIRE-HEP BibTeX
uv run citer -o refs.bib URL1 URL2 ...                    # append to a .bib file
uv run citer                                              # interactive: prompt for papers
uv run citer -i -o refs.bib                               # interactive, explicit file
cat urls.txt | uv run citer -o refs.bib                   # targets from stdin
```

With `-o` or in interactive mode, each fetched entry is checked against the `.bib` file
(by DOI, arXiv ID and normalized title) and skipped if the paper is already there.
Interactive mode writes to `-o`, or the only `*.bib` in the current directory, or
`references.bib`. Quit with Ctrl-D or `quit`.

Accepts URLs (abstract or PDF pages), bare DOIs, `doi:`/`arXiv:` prefixes, and arXiv IDs.
AIP (`pubs.aip.org`) article URLs contain no DOI and their pages are behind Cloudflare, so
the DOI is looked up in Crossref from the volume, page and title in the URL.
ScienceDirect (`sciencedirect.com/.../pii/<PII>`) URLs are likewise blocked; their PII is
looked up in Crossref, where Elsevier registers it alongside the DOI.
The source used for each entry is printed to stderr.

## Sources (`--source`)

| Source | Endpoint |
|---|---|
| `arxiv` | `arxiv.org/bibtex/{id}` |
| `publisher` | APS `journals.aps.org/{journal}/export/{doi}`; Springer/Nature `citation-needed.springer.com`; Atypon `{host}/action/downloadCitation` (ACS, Wiley, Science, SIAM, T&F, PNAS, ...) |
| `doi` | `doi.org` content negotiation (Crossref/DataCite metadata deposited by the publisher) |
| `inspire` | `inspirehep.net/api/{arxiv,doi}/...?format=bibtex` |

`auto` (default) tries the publisher exporter first, then falls back to `doi`.
Atypon sites are usually behind Cloudflare, so they typically fall back to `doi`.

## Neovim plugin

This repo is also a Neovim plugin (needs Neovim 0.10+ and telescope.nvim). With vim-plug,
this installs both the plugin and the `citer` CLI (via uv):

```vim
Plug 'nvim-telescope/telescope.nvim'
Plug 'hershkumar/citer', { 'do': 'uv tool install --reinstall .' }
```

It sets itself up with defaults; call `require('citer').setup({...})` after `plug#end()` to
configure it. For local development use `Plug '~/Documents/citer'` instead (no `do` hook
needed if you've run `uv tool install --editable .`). See `:help citer` and
`:checkhealth citer`.

In `tex` buffers:

| Key / command | Action |
|---|---|
| type `\cite{` (also `\citep{`, `\autocite[..]{`, ...), or `,` inside one | picker opens automatically |
| `<C-x>c` (insert), `<leader>ci` (normal), `:CiterPick` | open the picker |
| in picker: `<C-j>`/`<C-k>`, `<Tab>`, `<CR>`, `<Esc>` | move, multi-select, insert keys, cancel |
| in picker: `<C-a>` | fetch a paper with `citer`, add it to the `.bib`, insert its key |
| `<leader>ca`, `:CiterAdd [url ...]` | fetch and add to the `.bib` (key is reported, not inserted) |
| `:CiterDuplicates` | quickfix list of duplicate entries across the project's `.bib` files |
| type `\ref{` (also `\eqref{`, `\cref{`, `\autoref{`, ...), or `,` inside `\cref{` | label picker opens automatically |
| `<C-x>r` (insert), `<leader>cr` (normal), `:CiterRef` | open the label picker |
| type `\includegraphics{` (also `\includegraphics[..]{`) | graphics picker opens automatically |
| `<C-x>g` (insert), `<leader>cg` (normal), `:CiterGraphics` | open the graphics picker |

The picker fuzzy-searches key, authors, title and year across every `*.bib` file in the
file's directory (and the vimtex project root). New entries go into the single `.bib`
there, or the one named in `\bibliography{}`/`\addbibresource{}`, or you're asked.

The label picker lists every `\label{}` in the buffer (including unsaved changes), the other
`*.tex` files in those directories, vimtex's source list, and files reached through
`\input{}`, `\include{}` and `\subfile{}`. Each label is shown with what it's attached to
(`equation`, `figure`, `section`, ...) and a description: the caption, section title,
theorem name, or the equation row. Outside a reference command, picked labels are wrapped
in `\ref{}` (see `ref_command`); `\cref{}`-style commands take several at once.

The graphics picker fuzzy-searches the paths of image files (`pdf`, `png`, `jpg`, `jpeg`,
`eps`, `svg`) under the project root and the `\graphicspath{}` directories, listed in tree
order with the directory dimmed and the file name highlighted; `●` marks ones already used
in the buffer. Paths are inserted relative to the `\graphicspath{}` entry they're in, or the
project root. A PDF next to a `.tex` of the same name (the compiled document) is left out.
The preview shows the image itself in kitty, Ghostty or WezTerm (Kitty graphics protocol;
not inside tmux), or as text art with `chafa` elsewhere. PDFs, JPEGs, SVGs and EPS files
are converted to cached PNG thumbnails with `pdftoppm`/`mutool`, `rsvg-convert`,
ImageMagick, or `sips` (macOS), whichever is installed.

Before adding, each fetched entry is checked against the existing entries by DOI, arXiv ID
and normalized title. If it's already there, nothing is written and the existing key is
inserted instead. Key collisions with *different* papers get a suffix (`Smith2020a`).

Options (defaults shown):

```lua
require('citer').setup({
  cmd = "citer",
  args = {},               -- e.g. { "--published" } to prefer journal versions of arXiv links
  bib_file = nil,          -- always write to this file instead of choosing
  default_bib = "references.bib",
  auto_open = true,        -- for \cite{, \ref{ and \includegraphics{
  ref_command = "ref",     -- wraps labels picked outside a reference command, e.g. "cref"
  graphics = {
    preview = "auto",      -- "kitty", "chafa", or false for file info only
    extensions = { "pdf", "png", "jpg", "jpeg", "eps", "svg" },
    depth = 5,             -- how deep to search below the project root
    max_files = 5000,
  },
  keymaps = {
    pick = "<leader>ci", add = "<leader>ca", insert_pick = "<C-x>c", picker_add = "<C-a>",
    ref_pick = "<leader>cr", insert_ref_pick = "<C-x>r",
    graphics_pick = "<leader>cg", insert_graphics_pick = "<C-x>g",
  },
})
```

## Development

```
src/citer/            the CLI (Python)
  resolve.py            URL / DOI / arXiv ID -> identifiers
  exporters.py          one function per BibTeX source, and publisher routing
  fetch.py              which exporters to try, run concurrently
  bib.py                BibTeX parsing, duplicate detection, appending
  cli.py                argument parsing, batch and interactive modes
lua/citer/            the Neovim plugin
  init.lua              setup, commands, keymaps, auto-open
  config.lua            options
  bib.lua               BibTeX parsing and duplicate detection (mirrors bib.py)
  files.lua             finding, caching and appending to .bib files
  labels.lua            finding and describing \label{}s in the project's .tex files
  graphics.lua          finding image files, PNG thumbnails, Kitty/chafa previews
  cursor.lua            \cite{}/\ref{}/\includegraphics{} context and insertion
  picker.lua            Telescope pickers (citations, labels, graphics)
  add.lua               fetching papers via the CLI
  duplicates.lua        :CiterDuplicates
plugin/citer.lua      auto-setup;  doc/citer.txt  :help citer
tests/                pytest suite;  tests/nvim/run.lua  plugin tests
```

```sh
uv run pytest                          # offline tests
CITER_NETWORK=1 uv run pytest          # also hit the live endpoints
nvim --headless --clean -c "luafile tests/nvim/run.lua"
# include the picker tests by putting Telescope on the runtimepath:
CITER_TEST_RTP=~/.vim/plugged/plenary.nvim,~/.vim/plugged/telescope.nvim \
  nvim --headless --clean -c "luafile tests/nvim/run.lua"
```

`bib.py` and `bib.lua` implement the same parsing and duplicate rules; change them together.
