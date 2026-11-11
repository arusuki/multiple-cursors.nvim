# Tests

Tests for using completion engines with multiple cursors.
Each case runs in a separate headless Neovim instance with `--clean` and isolated XDG directories, so your configuration isn't used or changed.

## Running

```sh
nvim -l tests/run.lua            # all cases
nvim -l tests/run.lua cmp        # cases with "cmp" in "<file>/<case> [<engine>]"
nvim -l tests/run.lua "fake_lsp/snippet"
```

The exit code is non-zero if a case fails.

Requirements:

- Neovim 0.12 (cases using `'autocomplete'` are skipped on older versions)
- `git`, to fetch [nvim-cmp](https://github.com/hrsh7th/nvim-cmp), [cmp-buffer](https://github.com/hrsh7th/cmp-buffer) and [cmp-nvim-lsp](https://github.com/hrsh7th/cmp-nvim-lsp) at pinned commits into `tests/.deps` on the first run (set `MC_TEST_DEPS` to use another directory)
- Optional: [lua-language-server](https://github.com/LuaLS/lua-language-server) on `PATH` for the `lua_ls` cases, which are skipped otherwise

## Layout

| Path | Description |
| --- | --- |
| `run.lua` | Fetches dependencies, runs each case for each engine, and reports the results |
| `runner.lua` | Runs one case in a child Neovim instance |
| `helpers/fake_lsp.lua` | In-process language server returning given completion items |
| `cases/buffer.lua` | Completing words in the buffer (cmp-buffer, `<C-p>`, `'autocomplete'`) |
| `cases/fake_lsp.lua` | Text edits, additional text edits, snippets, and `completionItem/resolve` |
| `cases/lua_ls.lua` | Completion with lua-language-server |

## Adding a case

A case file returns a list of cases:

```lua
{
  name = "same prefix",
  lines = { "foobarbaz_word", "x fo", "y fo" },  -- initial buffer
  cursors = { { 2, 4 }, { 3, 4 } },              -- {lnum, col}, the first is the real cursor
  keys = { "A", "@complete", "@confirm", "X", "<Esc>" },
  expected = { "foobarbaz_word", "x foobarbaz_wordX", "y foobarbaz_wordX" },
}
```

Fields:

- `engines`: `{"cmp", "native"}` by default; cases for different engines can share a name
- `expected`: the final buffer, or `{cmp = {...}, native = {...}}` if it differs by engine
- `keys`: steps, each followed by a delay (`delay`, default 250 ms):
  - a string is fed with `nvim_input()`
  - `"@complete"`: `cmp.complete()`, `vim.lsp.completion.get()` if there's a language server, or `<C-p>`
  - `"@confirm"`: `<CR>` for cmp, `<C-y>` for the built-in completion if the menu is visible
  - `"@next"`: `cmp.select_next_item()` or `<C-n>`
  - `"@select:<label>"`: select the item with the label
  - `function(ctx)`: called, `ctx.assert(cond, msg)` records a failure
  - `{step, wait = ms}` or `{step, wait = "menu"}`: wait a time, or until the menu is visible
- `lsp`: `{kind = "fake", items = function(line, character) ... end, resolve_delay = ms}` or `{kind = "lua_ls"}`
- `options`: options to set, e.g. `{completeopt = "menu,menuone"}`
- `cmp_replace`: confirm with `cmp.ConfirmBehavior.Replace`
- `requires`: `{nvim = "0.12"}` and/or `{executable = "lua-language-server"}`, otherwise the case is skipped
- `timeout`: milliseconds, 60000 by default
