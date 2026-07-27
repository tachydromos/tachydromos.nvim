# tachydromos.nvim

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Run `.http` request files from Neovim, backed by the [`tachydromos`](../tachydromos)
CLI (`tachy`) instead of an embedded HTTP client. Functionally in the spirit
of [kulala.nvim](https://github.com/mistweaverco/kulala.nvim) — run request
under cursor, run by name, response split, environment selection, syntax
highlighting — but every interaction with the outside world goes through
`tachy` exactly as documented in [`docs/cli-contract.md`](docs/cli-contract.md).

Built following [mini.nvim](https://github.com/nvim-mini/mini.nvim)'s module
conventions: single `return module` table, `setup(config)` merging over
defaults, `H`-prefixed private helpers, LuaCATS annotations, lazy submodule
loading, minimal dependencies (pure Lua + Neovim stdlib — no plenary.nvim or
other plugin dependency).

## Requirements

- Neovim >= 0.10 (uses `vim.system()`).
- The `tachy` binary on `$PATH` (build it from the `tachydromos` repo with
  `make build`, or point `tachy_cmd` at it directly).

Run `:checkhealth tachydromos` after installing to verify both.

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'tachydromos/tachydromos.nvim',
  ft = 'http',
  opts = {},
}
```

`opts = {}` makes lazy.nvim call `require('tachydromos').setup({})` for you.
To customize, pass a config table instead of `{}` — see below.

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use({
  'tachydromos/tachydromos.nvim',
  config = function()
    require('tachydromos').setup({})
  end,
})
```

Nothing in the plugin activates until `setup()` is called — no commands, no
keymaps — matching mini.nvim's "inert until setup()" convention.

## Quick config

```lua
require('tachydromos').setup({
  -- Name or path of the `tachy` executable.
  tachy_cmd = 'tachy',

  -- Environment used when a buffer has none selected via `:Tachydromos env`.
  -- `nil` means no `--env` flag is passed at all.
  default_env = nil,

  result = {
    style = 'split', -- 'split' | 'vsplit' | 'float'
    size = 0.4,       -- fraction of the screen
  },

  mappings = {
    run        = '<leader>rr', -- run request under cursor
    run_buffer = '<leader>ra', -- run every request in the buffer
    picker     = '<leader>rp', -- pick a request by name, then run it
    select_env = '<leader>re', -- select environment for this buffer
  },
})
```

## Usage

In a `.http` buffer:

- `:Tachydromos run` — run the request under the cursor.
- `:Tachydromos buffer` — run every request in the file (the only way
  chaining between requests resolves, since `tachy` scopes chaining/cookies
  to a single `run` invocation).
- `:Tachydromos picker` — pick a request by name (`vim.ui.select`) and run it.
- `:Tachydromos env [name]` — set the active environment, or open a picker
  over environment names found by walking up from the file
  (`http-client.env.json` / `http-client.private.env.json`).
- `:Tachydromos last` — reopen the result window without starting a new run.

Full details, including the `--request` chaining caveat and known CLI gaps
this plugin inherits, are in [`doc/tachydromos.txt`](doc/tachydromos.txt)
(`:help tachydromos.nvim`).

## Syntax highlighting

Ships a minimal regex-based `syntax/http.vim` as a safe fallback — there is
no widely-available, well-maintained Tree-sitter grammar for `.http` files
in nvim-treesitter today. If one appears, swapping in a
`queries/http/highlights.scm` is a natural follow-up.

## Scope notes

This plugin only does what `docs/cli-contract.md` documents `tachy` as
supporting. In particular it does **not**: inject ad-hoc variables from
Neovim (no `--var` flag exists), offer a "preview resolved request" dry-run
(not supported by the CLI), or persist chaining/cookies across separate runs
(each `tachy run` invocation starts cold). See the contract's "Known gaps"
section and `:help tachydromos-contract-gaps` for the full list.
