<p align="center">
  <img src="runtime/spider.svg" alt="Spider logo" width="160">
</p>

<h1 align="center">Spider</h1>

<p align="center">
  <b>Neovim, with Helix keys.</b><br>
  Select first, then act — with multiple selections, LSP that just works, and a yazi-style file explorer.
</p>

```
            ╲ ╲ ╱ ╱
             ─(●●)─      w        select the next word
            ╱ ╱ ╲ ╲      d        delete it
                         %s foo   select every "foo" in the file
                         c bar    change them all at once
```

Spider is a fork of [Neovim](https://neovim.io) where Normal mode follows the
[Helix](https://helix-editor.com) keymap and selection model. Everything else
is Neovim: the Lua API, LSP client, tree-sitter, options, `:commands` and
**your Neovim plugins all keep working**.

- [Why Spider](#why-spider)
- [Install](#install)
- [Quick tour](#quick-tour)
- [Configuration](#configuration)
- [Using Neovim plugins](#using-neovim-plugins)
- [Differences from Helix](#differences-from-helix)
- [Development](#development)
- [License](#license)

## Why Spider

| | |
|---|---|
| **Helix keymap** | Every key from the [Helix keymap](https://docs.helix-editor.com/keymap.html): `w`/`b`/`e` select, `x` selects lines, `d`/`c`/`y` act on the selection, `v` extends, `gd`/`gr` go to definition/references, `Space f` finds files, … |
| **Multiple selections** | `s` (select regex), `S` (split), `C` (cursor below), `Alt-s` (split lines), `&` (align), `(`/`)` (rotate) — and typing in Insert mode happens at every selection. |
| **Minor modes with hints** | Press `g`, `m`, `z`, `Space`, `[`, `]` or `Ctrl-w` and a popup shows what comes next. `Space ?` searches every command. |
| **Surround & text objects** | `mi(` / `mib` select inside parentheses, `ms"` / `msd` surround with quotes, `mr({` / `mrbB` replace, `md[` / `mdr` delete. Tree-sitter objects: `maf` (function), `mit` (type), `mia` (argument)… |
| **LSP that just works** | Install a language server (`pyright`, `rust-analyzer`, `gopls`, `clangd`, `lua-language-server`, `typescript-language-server`, …) and open a file. Spider finds and starts it — no config. |
| **Popup command line** | `:` opens a centered, titled floating command line (`Cmdline`, `Search`, …) with completion. |
| **File explorer** | `Space e` opens a yazi-style, three-column file manager: `h`/`l` to navigate, `a` create, `r` rename, `d` trash, `y`/`x`/`p` copy/move, `Space` to select. |
| **Emacs keys in Insert mode** | `Ctrl-a`/`Ctrl-e`, `Ctrl-f`/`Ctrl-b`, `Alt-f`/`Alt-b`, `Ctrl-k` + `Ctrl-y` kill ring, `Alt-u`/`Alt-l`/`Alt-c`, … (only where they don't clash). |
| **Plugin adapter API** | `vim.helix.motion()`, `vim.helix.operator()`, `vim.helix.textobject()`, `vim.helix.map()` and `vim.helix.set_picker()` turn Vim-style plugins into Helix-style ones in a line or two. |

Everything is built in and on by default — and each part is a regular option
you can turn off (`:set nohelix`, `:set nocmdlinepopup`, `:set nolspautodetect`).

## Install

Spider installs as `spider`, with its own runtime (`share/spider`), config
(`~/.config/spider`) and data (`~/.local/share/spider`). **It never touches an
existing Neovim install or config**, so both can live side by side.

### 1. Build dependencies

```sh
# Debian / Ubuntu
sudo apt install ninja-build gettext cmake curl build-essential git
# Fedora
sudo dnf install ninja-build cmake gcc make gettext curl glibc-gconv-extra git
# Arch
sudo pacman -S base-devel cmake ninja curl git
# macOS
brew install ninja cmake gettext curl
```

### 2. Clone, build, install to `~/.local`

```sh
gh repo clone TsaH0/neovim ~/src/spider -- --branch helix-mode   # or: git clone -b helix-mode https://github.com/TsaH0/neovim ~/src/spider
cd ~/src/spider
make CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX=$HOME/.local
make install
```

This installs:

| Path | What |
|---|---|
| `~/.local/bin/spider` | the editor |
| `~/.local/share/spider/runtime/` | runtime files (docs, syntax, Lua, LSP configs) |
| `~/.local/lib/spider/` | tree-sitter parsers |
| `~/.local/share/man/man1/spider.1` | man page |
| `~/.local/share/applications/spider.desktop` | desktop entry |

Make sure `~/.local/bin` is on your `PATH`:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc   # or ~/.zshrc
```

### 3. Check

```sh
spider --version      # SPIDER v0.13.0-dev-…
nvim --version        # your Neovim, unchanged
```

### Update

```sh
cd ~/src/spider && git pull
make CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX=$HOME/.local && make install
```

### Uninstall

```sh
rm -rf ~/.local/bin/spider ~/.local/share/spider ~/.local/lib/spider \
       ~/.local/share/man/man1/spider.1 ~/.local/share/applications/spider.desktop
# and, to remove your Spider config/data too:
rm -rf ~/.config/spider ~/.local/state/spider ~/.cache/spider
```

## Quick tour

Open a file with `spider file.txt` and try:

| Keys | Does |
|---|---|
| `w` `b` `e` | select next word / previous word / to word end |
| `x` | select the line (again: extend to the next line) |
| `d` `c` `y` `p` | delete / change / yank / paste the selection |
| `v` | select mode: motions extend the selection (`Esc` to leave) |
| `;` `,` | collapse the selection / keep only the primary one |
| `%` then `s` | select all, then select every regex match in it |
| `C` | add a cursor on the next line |
| `u` `U` | undo / redo |
| `/` `n` `N` `*` | search, next/previous match, search for the selection |
| `gd` `gr` `Space k` | go to definition / references, hover docs (LSP) |
| `Space r` `Space a` | rename symbol, code actions (LSP) |
| `Space f` `Space b` `Space /` | find files, buffers, text in the project |
| `Space e` | file explorer |
| `mi(` `mib` `ma"` `mad` | select inside parentheses / around quotes |
| `ms(` `mr([` `md[` | surround, replace surround, delete surround |
| `Alt-o` `Alt-i` | expand / shrink the selection by syntax node |
| `Ctrl-o` `Ctrl-i` | jump back / forward |
| `Space ?` | search all commands |

Full reference inside Spider: `:help spider`, `:help helix-mode`,
`:help helix-pairs`, `:help file-explorer`.

### Pair letters

Wherever you type a pair (`mi`, `ma`, `ms`, `mr`, `md`), you can use the
symbol or a letter:

| Pair | Symbol | Letter |
|---|---|---|
| parentheses | `(` `)` | `b` |
| braces | `{` `}` | `B` |
| brackets | `[` `]` | `r` |
| angle brackets | `<` `>` | `A` |
| double quotes | `"` | `d` |
| single quotes | `'` | `s` |
| backticks | `` ` `` | `k` |
| closest quote | | `q` |
| closest pair of any kind | | `m` |

## Configuration

Spider reads `~/.config/spider/init.lua` (or `init.vim`) — a normal Neovim
config. To start from your Neovim config:

```sh
cp -r ~/.config/nvim ~/.config/spider
```

Options (set them in `init.lua`):

```lua
vim.o.helix = true          -- Helix keys and selections (false: Vim keys)
vim.o.cmdlinepopup = true   -- floating command line
vim.o.lspautodetect = true  -- start installed language servers automatically
vim.g.helix_infobox = true  -- key hints popup for g, m, Space, …
```

Your own mappings always win over Spider's defaults:

```lua
vim.keymap.set('n', 'Q', 'gq')  -- replaces Helix's Q (record macro)
```

Language servers use Neovim's [`vim.lsp.config()`](https://neovim.io/doc/user/lsp.html#lsp-config);
configs you write (or nvim-lspconfig provides) override Spider's defaults:

```lua
vim.lsp.config('lua_ls', { settings = { Lua = { diagnostics = { globals = { 'vim' } } } } })
```

## Using Neovim plugins

Plugins install and run as in Neovim (lazy.nvim, packer, `vim.pack`, …).
Their mappings take precedence over Helix keys. To make a Vim-style plugin
feel native, use the `vim.helix` adapters (`:help helix-api`):

```lua
-- Jump plugins (hop, leap, flash): the jump target becomes the selection,
-- and extends it in select mode.
vim.keymap.set('n', 'gj', vim.helix.motion(function() require('flash').jump() end))

-- Operator plugins (comment, surround, sort, …): apply to every selection.
vim.keymap.set('n', 'gS', vim.helix.operator('S'))

-- Text object plugins (treesitter-textobjects, mini.ai, …): add to m a / m i.
vim.helix.textobject('o', { around = 'ao', inner = 'io', desc = 'Loop' })

-- Picker plugins (Telescope, fzf-lua, …): on Space keys, or for every picker.
vim.helix.map('space', 'f', function() require('telescope.builtin').find_files() end, 'Find files')
```

## Differences from Helix

Spider aims to match Helix key for key. Where Neovim works differently:

- `:` runs Neovim commands (`:w`, `:q`, `:s/…`), not Helix's typable commands.
- Regexes use Helix (Rust) syntax and are translated to Vim regexes.
- Tree-sitter text objects (`maf`, `]f`, …) recognize nodes by type names,
  since Neovim doesn't ship Helix's textobject queries.
- `j`/`k` move by text lines, not wrapped screen lines.
- `Ctrl-o` restores the cursor position (Neovim's jumplist), not the whole
  selection.
- `Space G` (debugger) needs a DAP plugin.

## Development

Spider builds and tests like Neovim (see [BUILD.md](BUILD.md) and
[CONTRIBUTING.md](CONTRIBUTING.md)). In the build tree the binary is
`build/bin/nvim` (with a `build/bin/spider` symlink).

```sh
make                                   # build
make functionaltest TEST_FILE=test/functional/plugin/helix_spec.lua
```

Where things live:

| Path | |
|---|---|
| `runtime/lua/vim/_core/helix.lua` | Helix keymap and commands |
| `runtime/lua/vim/_core/helix_sel.lua` | selection model |
| `runtime/lua/vim/_core/helix_ts.lua` | tree-sitter selections and text objects |
| `runtime/lua/vim/_core/helix_picker.lua` | fuzzy picker |
| `runtime/lua/vim/helix.lua` | public `vim.helix` API |
| `runtime/lua/vim/_core/cmdline_popup.lua` | popup command line |
| `runtime/lua/vim/_core/lsp_detect.lua`, `runtime/lsp/` | LSP autodetection and server configs |
| `runtime/lua/vim/_core/explorer.lua` | file explorer |
| `runtime/doc/helix.txt` | user docs (`:help spider`) |

## License

Spider is a fork of [Neovim](https://github.com/neovim/neovim) and keeps its
licensing: contributions are Apache 2.0, and code inherited from Vim is under
the Vim license. See [LICENSE.txt](LICENSE.txt). Spider is not affiliated with
the Neovim or Helix projects; all credit for the editor core goes to them.
