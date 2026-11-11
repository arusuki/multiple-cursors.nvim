-- A key map of this plug-in typed together with the key that starts a
-- completion: with typeahead the popup menu isn't shown, so CompleteChanged and
-- TextChangedP aren't triggered before the key map runs

local W = "foobarbaz_word"

-- First line provides the completion word (CTRL-P searches backwards)
local H = W .. " Foo_upper"

local lines = { H, "x fo", "y fo" }
local cursors = { { 2, 4 }, { 3, 4 } }

return {
  {
    name = "escape",
    lines = lines,
    cursors = cursors,
    keys = { "A", "<C-p><Esc>" },
    engines = { "native" },
    expected = { H, "x " .. W, "y " .. W },
  },
  {
    -- Backspace ends the completion, then deletes a character
    name = "backspace",
    lines = lines,
    cursors = cursors,
    keys = { "A", "<C-p><BS>", "<Esc>" },
    engines = { "native" },
    expected = { H, "x " .. W:sub(1, -2), "y " .. W:sub(1, -2) },
  },
  {
    name = "enter",
    lines = lines,
    cursors = cursors,
    keys = { "A", "<C-p><CR>", "q", "<Esc>" },
    engines = { "native" },
    expected = { H, "x " .. W, "q", "y " .. W, "q" },
  },
  {
    name = "tab",
    lines = lines,
    cursors = cursors,
    keys = { "A", "<C-p><Tab>", "Z", "<Esc>" },
    engines = { "native" },
    expected = { H, "x " .. W .. "\tZ", "y " .. W .. "\tZ" },
  },
  {
    name = "left",
    lines = lines,
    cursors = cursors,
    keys = { "A", "<C-p><Left>", "q", "<Esc>" },
    engines = { "native" },
    expected = { H, "x " .. W:sub(1, -2) .. "q" .. W:sub(-1), "y " .. W:sub(1, -2) .. "q" .. W:sub(-1) },
  },
}
