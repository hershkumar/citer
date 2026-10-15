# citer

Fetch BibTeX for a paper from the publisher's (or arXiv's) own export endpoint.

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

The picker fuzzy-searches key, authors, title and year across every `*.bib` file in the
file's directory (and the vimtex project root). New entries go into the single `.bib`
there, or the one named in `\bibliography{}`/`\addbibresource{}`, or you're asked.

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
  auto_open = true,
  keymaps = { pick = "<leader>ci", add = "<leader>ca", insert_pick = "<C-x>c", picker_add = "<C-a>" },
})
```
