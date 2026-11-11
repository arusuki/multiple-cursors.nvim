-- Language server completion with an in-process fake server
-- (tests/helpers/fake_lsp.lua): text edits with a replace range, additional
-- text edits, and snippets
--
-- The real cursor is between "fo" and "END"

local lines = { "header", "x foEND rest", "y foEND rest" }
local cursors = { { 2, 5 }, { 3, 5 } }

-- Replaces "fo" and "END", and adds an import at the top
local function import_item(line, character)
  return { {
    label = "foobar_lsp",
    filterText = "fo",
    textEdit = {
      range = { start = { line = line, character = character - 2 }, ["end"] = { line = line, character = character + 3 } },
      newText = "foobar_lsp",
    },
    additionalTextEdits = { {
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      newText = "import x\n",
    } },
  } }
end

-- Replaces "fo"
local function word_item(line, character)
  return { {
    label = "foobar_lsp",
    filterText = "fo",
    textEdit = {
      range = { start = { line = line, character = character - 2 }, ["end"] = { line = line, character = character } },
      newText = "foobar_lsp",
    },
  } }
end

local function snippet_item(line, character)
  return { {
    label = "foo",
    insertTextFormat = 2,
    textEdit = {
      range = { start = { line = line, character = character - 2 }, ["end"] = { line = line, character = character } },
      newText = "foo(${1:arg})",
    },
  } }
end

-- The built-in completion inserts the text edit without the replace range
-- (cmp uses its replace behavior here)
local snippet_expected = {
  cmp = { "header", "x foo(q) rest", "y foo(q) rest" },
  native = { "header", "x foo(q)END rest", "y foo(q)END rest" },
}

return {
  {
    -- The import is only added once
    name = "text edit and import",
    lines = lines,
    cursors = cursors,
    lsp = { kind = "fake", items = import_item },
    cmp_replace = true,
    options = { completeopt = "menu,menuone,popup" },
    delay = 300,
    keys = { "i", "@complete", "@confirm", "Z", "<Esc>" },
    expected = {
      cmp = { "import x", "header", "x foobar_lspZ rest", "y foobar_lspZ rest" },
      native = { "import x", "header", "x foobar_lspZEND rest", "y foobar_lspZEND rest" },
    },
  },
  {
    -- Typing over the placeholder (select mode) is replayed
    name = "snippet",
    lines = lines,
    cursors = cursors,
    lsp = { kind = "fake", items = snippet_item },
    cmp_replace = true,
    options = { completeopt = "menu,menuone,popup" },
    delay = 300,
    keys = { "i", "@complete", "@confirm", "q", "<Esc>" },
    expected = snippet_expected,
  },
  {
    -- vim.lsp.completion resolves the item asynchronously, and doesn't expand
    -- the snippet if the buffer changed in the meantime
    name = "snippet with completionItem/resolve",
    lines = lines,
    cursors = cursors,
    lsp = { kind = "fake", items = snippet_item, resolve_delay = 200 },
    cmp_replace = true,
    options = { completeopt = "menu,menuone,popup" },
    delay = 300,
    keys = { "i", "@complete", { "@confirm", wait = 600 }, "q", "<Esc>" },
    expected = snippet_expected,
  },
  {
    -- If the server doesn't respond, characters are copied to the virtual
    -- cursors after a timeout (the built-in completion never expands the
    -- snippet, cmp doesn't wait for the response)
    name = "completionItem/resolve without a response",
    lines = lines,
    cursors = cursors,
    lsp = { kind = "fake", items = snippet_item, resolve_delay = 100000 },
    cmp_replace = true,
    options = { completeopt = "menu,menuone,popup" },
    delay = 300,
    keys = { "i", "@complete", { "@confirm", wait = 1500 }, "q", "<Esc>" },
    expected = {
      cmp = { "header", "x foo(q) rest", "y foo(q) rest" },
      native = { "header", "x fooqEND rest", "y fooqEND rest" },
    },
  },
  {
    -- A key pressed while the accepted item is being resolved: the completion
    -- is replayed before the key
    name = "tab while resolving",
    lines = lines,
    cursors = cursors,
    lsp = { kind = "fake", items = word_item, resolve_delay = 500 },
    cmp_replace = true,
    options = { completeopt = "menu,menuone,popup" },
    delay = 300,
    keys = { "i", "@complete", { "@confirm", wait = 50 }, { "<Tab>", wait = 800 }, "Z", "<Esc>" },
    expected = {
      cmp = { "header", "x foobar_lsp\tZ rest", "y foobar_lsp\tZ rest" },
      native = { "header", "x foobar_lsp\tZEND rest", "y foobar_lsp\tZEND rest" },
    },
  },
  {
    name = "escape while resolving",
    lines = lines,
    cursors = cursors,
    lsp = { kind = "fake", items = word_item, resolve_delay = 500 },
    cmp_replace = true,
    options = { completeopt = "menu,menuone,popup" },
    delay = 300,
    keys = { "i", "@complete", { "@confirm", wait = 50 }, { "<Esc>", wait = 800 } },
    expected = {
      cmp = { "header", "x foobar_lsp rest", "y foobar_lsp rest" },
      native = { "header", "x foobar_lspEND rest", "y foobar_lspEND rest" },
    },
  },
  {
    -- The import is added on the line of the real cursor: only the completion
    -- is replayed
    name = "import before the line of the real cursor",
    lines = { "x foEND rest", "y foEND rest" },
    cursors = { { 1, 5 }, { 2, 5 } },
    lsp = { kind = "fake", items = import_item },
    cmp_replace = true,
    options = { completeopt = "menu,menuone,popup" },
    delay = 300,
    keys = { "i", "@complete", "@confirm", "Z", "<Esc>" },
    expected = {
      cmp = { "import x", "x foobar_lspZ rest", "y foobar_lspZ rest" },
      native = { "import x", "x foobar_lspZEND rest", "y foobar_lspZEND rest" },
    },
  },
  {
    -- Same, with the completed word at the start of the line, so the text
    -- before the cursor doesn't identify the line
    name = "import before the line of the real cursor, word at the start",
    lines = { "foEND rest", "foEND rest" },
    cursors = { { 1, 3 }, { 2, 3 } },
    lsp = { kind = "fake", items = import_item },
    cmp_replace = true,
    options = { completeopt = "menu,menuone,popup" },
    delay = 300,
    keys = { "i", "@complete", "@confirm", "Z", "<Esc>" },
    expected = {
      cmp = { "import x", "foobar_lspZ rest", "foobar_lspZ rest" },
      native = { "import x", "foobar_lspZEND rest", "foobar_lspZEND rest" },
    },
  },
}
