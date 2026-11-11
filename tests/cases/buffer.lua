-- Completion of words in the buffer: cmp-buffer for nvim-cmp, and CTRL-P /
-- 'autocomplete' for the built-in completion
--
-- cursors: {lnum, col} positions, the first is the real cursor
-- expected: the buffer after the keys, or a table of buffers per engine

local W = "foobarbaz_word"

-- First line provides the completion word (CTRL-P searches backwards)
local H = W .. " Foo_upper"

local accent = vim.fn.nr2char(0x301)
local accented_word = "fooba" .. accent .. "r"

return {
  {
    name = "same prefix",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = { "A", "@complete", "@confirm", "X", "<Esc>" },
    expected = { H, "x " .. W .. "X", "y " .. W .. "X" },
  },
  {
    -- Virtual cursors with different text replace the longest text matching
    -- the start of the word (ignoring case), or insert the whole word
    name = "different prefixes",
    lines = { H, "x fo", "y Fo", "  z f", "w bar" },
    cursors = { { 2, 4 }, { 3, 4 }, { 4, 5 }, { 5, 5 } },
    keys = { "A", "@complete", "@confirm", "X", "<Esc>" },
    expected = { H, "x " .. W .. "X", "y " .. W .. "X", "  z " .. W .. "X", "w bar" .. W .. "X" },
  },
  {
    name = "backspace after completion",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = { "A", "@complete", "@confirm", "<BS>", "<Esc>" },
    expected = { H, "x " .. W:sub(1, -2), "y " .. W:sub(1, -2) },
  },
  {
    name = "complete after moving left",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = { "A", "z", "<Left>", "@complete", "@confirm", "<Esc>" },
    expected = { H, "x " .. W .. "z", "y " .. W .. "z" },
  },
  {
    name = "complete in the middle of a line",
    lines = { H, "x fo end", "y fo end" },
    cursors = { { 2, 5 }, { 3, 5 } },
    keys = { "i", "@complete", "@confirm", "<Esc>" },
    expected = { H, "x " .. W .. " end", "y " .. W .. " end" },
  },
  {
    -- More than one InsertCharPre before TextChangedI
    name = "typing several characters at once",
    lines = { H, "x a", "y a" },
    cursors = { { 2, 3 }, { 3, 3 } },
    keys = { "A", "bc", "d", "<Esc>" },
    expected = { H, "x abcd", "y abcd" },
  },
  {
    -- cmp wraps this plug-in's <CR> key map as its fallback
    name = "enter without the menu",
    lines = { H, "x zz", "y zz" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = { "A", "<CR>", "q", "<Esc>" },
    expected = { H, "x zz", "q", "y zz", "q" },
  },
  {
    -- cmp inserts the selected item, CTRL-P inserts the first match
    name = "escape with an inserted item",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = { "A", "@complete", "@next", "<Esc>" },
    engines = { "cmp" },
    expected = { H, "x " .. W, "y " .. W },
  },
  {
    name = "escape with an inserted item",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = { "A", "@complete", "<Esc>" },
    engines = { "native" },
    expected = { H, "x " .. W, "y " .. W },
  },
  {
    -- With typeahead the popup menu isn't shown, so CompleteChanged and
    -- TextChangedP aren't triggered before CompleteDone (reason "accept")
    -- There's a single match and no popup menu, so CTRL-Y also inserts the
    -- character above the cursor ("o") at the real cursor
    name = "complete and accept in one input",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = { "A", "<C-p><C-y>", "X", "<Esc>" },
    engines = { "native" },
    expected = { H, "x " .. W .. "oX", "y " .. W .. "oX" },
  },
  {
    -- A key map ending the completion replays the completion before the key,
    -- the key isn't replayed again (CompleteDone reason "discard")
    name = "tab ends the completion",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = { "A", "@complete", "<Tab>", "Z", "<Esc>" },
    engines = { "native" },
    expected = { H, "x " .. W .. "\tZ", "y " .. W .. "\tZ" },
  },
  {
    name = "typing ends the completion",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = { "A", "@complete", "(", "<Esc>" },
    engines = { "native" },
    expected = { H, "x " .. W .. "(", "y " .. W .. "(" },
  },
  {
    -- With 'noexpandtab' <Tab> is inserted as a character (InsertCharPre), the
    -- key map has already inserted it at the virtual cursors
    name = "tab",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = { "A", "<Tab>", "Z", "<Esc>" },
    expected = { H, "x fo\tZ", "y fo\tZ" },
  },
  {
    name = "tab with expandtab",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    options = { expandtab = true, shiftwidth = 4, tabstop = 4 },
    keys = { "A", "<Tab>", "Z", "<Esc>" },
    expected = { H, "x fo    Z", "y fo    Z" },
  },
  {
    name = "fuzzy match",
    lines = { H, "x fbw", "y fbw" },
    cursors = { { 2, 5 }, { 3, 5 } },
    keys = { "A", "@complete", "@confirm", "<Esc>" },
    engines = { "cmp" },
    expected = { H, "x " .. W, "y " .. W },
  },
  {
    name = "replace mode",
    lines = { H, "x fo__", "y fo__" },
    cursors = { { 2, 5 }, { 3, 5 } },
    keys = { "R", "@complete", "@confirm", "<Esc>" },
    engines = { "native" },
    expected = { H, "x " .. W, "y " .. W },
  },
  {
    name = "replace mode with different prefix and suffix lengths",
    lines = { "foobar", "x fo__", "y fo123456789", "z f__三四五六", "w foo12345" },
    cursors = { { 2, 5 }, { 3, 5 }, { 4, 4 }, { 5, 6 } },
    keys = { "R", "@complete", "@confirm", "<Esc>" },
    engines = { "native" },
    expected = { "foobar", "x foobar", "y foobar56789", "z foobar六", "w foobar45" },
  },
  {
    name = "replace mode at end of real line",
    lines = { accented_word, "x fo", "y fo123456", "z fo123a" .. accent .. "56" },
    cursors = { { 2, 4 }, { 3, 4 }, { 4, 4 } },
    keys = { "R", "<Right>", "@complete", "@confirm", "<Esc>" },
    engines = { "native" },
    expected = { accented_word, "x " .. accented_word, "y " .. accented_word .. "56", "z " .. accented_word .. "56" },
  },
  {
    -- Characters typed while the popup menu is visible trigger TextChangedP
    name = "autocomplete typing",
    lines = { H, "x ", "y " },
    cursors = { { 2, 2 }, { 3, 2 } },
    keys = { "A", "f", "o", "o", "<Esc>" },
    engines = { "native" },
    options = { autocomplete = true },
    requires = { nvim = "0.12" },
    expected = { H, "x foo", "y foo" },
  },
  {
    name = "autocomplete select then type",
    lines = { H, "x ", "y " },
    cursors = { { 2, 2 }, { 3, 2 } },
    keys = { "A", "f", "o", "<C-n>", "b", "<Esc>" },
    engines = { "native" },
    options = { autocomplete = true },
    requires = { nvim = "0.12" },
    expected = { H, "x " .. W .. "b", "y " .. W .. "b" },
  },
  {
    name = "autocomplete cycle then accept",
    lines = { H, "x ", "y ", "z " },
    cursors = { { 2, 2 }, { 3, 2 }, { 4, 2 } },
    keys = { "A", "f", "o", "<C-n>", "<C-n>", "<C-p>", "<C-y>", ".", "<Esc>" },
    engines = { "native" },
    options = { autocomplete = true },
    requires = { nvim = "0.12" },
    expected = { H, "x " .. W .. ".", "y " .. W .. ".", "z " .. W .. "." },
  },
  {
    -- Exiting multiple cursors removes this plug-in's key maps and restores
    -- cmp.core.suspend; re-entering insert mode lets cmp set its global maps
    name = "exit restores cmp",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = {
      "A",
      function(ctx)
        ctx.assert(rawget(ctx.cmp.core, "suspend") ~= nil, "cmp.core.suspend isn't wrapped while active")
      end,
      "<Esc>", "<Esc>", "A",
      function(ctx)
        local map = vim.fn.maparg("<CR>", "i", false, true)
        ctx.assert(map.desc == "cmp.utils.keymap.set_map" and map.buffer == 0,
          "insert mode <CR> isn't cmp's global map: " .. vim.inspect(map))
        ctx.assert(rawget(ctx.cmp.core, "suspend") == nil, "cmp.core.suspend is still wrapped")
        ctx.assert(#(ctx.cmp.core.event.events.confirm_done or {}) == ctx.cmp_listeners_before,
          "confirm_done listener wasn't removed")
      end,
      "<Esc>",
    },
    engines = { "cmp" },
    expected = { H, "x fo", "y fo" },
  },
  {
    -- Leaving the buffer detaches, entering it again attaches
    name = "switching buffers",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = {
      function() vim.cmd("enew") end,
      function() vim.cmd("buffer 1") end,
      function() vim.cmd("enew") end,
      function() vim.cmd("buffer 1") end,
      "A", "@complete", "@confirm",
      function(ctx)
        ctx.assert(#(ctx.cmp.core.event.events.confirm_done or {}) == ctx.cmp_listeners_before + 1,
          "expected one confirm_done listener from this plug-in")
      end,
      "<Esc>",
    },
    engines = { "cmp" },
    expected = { H, "x " .. W, "y " .. W },
  },
  {
    -- A backend that fails to attach is skipped, the other backends are used
    name = "backend that fails to attach",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    extra_backends = {
      {
        name = "broken",
        attach = function() error("broken backend") end,
        is_writing = function() return false end,
      },
    },
    keys = { "A", "@complete", "@confirm", "X", "<Esc>" },
    expected = { H, "x " .. W .. "X", "y " .. W .. "X" },
  },
  {
    -- The cmp backend isn't used if the nvim-cmp internals it uses are missing
    name = "unsupported nvim-cmp version",
    lines = { H, "x fo", "y fo" },
    cursors = { { 2, 4 }, { 3, 4 } },
    keys = {
      function(ctx)
        local backend = require("multiple-cursors.completion.backends.cmp")
        ctx.assert(backend.available(), "expected the cmp backend to be available")
        local event = ctx.cmp.event
        ctx.cmp.event = nil
        local ok, available = pcall(backend.available)
        ctx.cmp.event = event
        ctx.assert(ok and available == false, "expected the cmp backend to be unavailable")
      end,
    },
    engines = { "cmp" },
    expected = { H, "x fo", "y fo" },
  },
}
