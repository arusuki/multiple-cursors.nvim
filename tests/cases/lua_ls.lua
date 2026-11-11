-- Completion with a real language server, lua-language-server
-- These cases are skipped if lua-language-server isn't installed

local requires = { executable = "lua-language-server" }
local options = { completeopt = "menu,menuone,noinsert" }

return {
  {
    name = "local variable",
    lines = { "local unique_alpha = 1", "print(uniq)", "print(uniq)", "print(uniq)" },
    cursors = { { 2, 10 }, { 3, 10 }, { 4, 10 } },
    lsp = { kind = "lua_ls" },
    requires = requires,
    options = options,
    cmp_replace = true,
    delay = 300,
    timeout = 90000,
    keys = { "a", { "@complete", wait = "menu" }, { "@confirm", wait = 800 }, "<Esc>" },
    expected = { "local unique_alpha = 1", "print(unique_alpha)", "print(unique_alpha)", "print(unique_alpha)" },
  },
  {
    -- cmp's replace behavior also replaces "zz" after the cursor, the built-in
    -- completion doesn't
    name = "field with text after the cursor",
    lines = { "local tbl = { long_field_name = 1 }", "print(tbl.lonzz)", "print(tbl.lonzz)" },
    cursors = { { 2, 13 }, { 3, 13 } },
    lsp = { kind = "lua_ls" },
    requires = requires,
    options = options,
    cmp_replace = true,
    delay = 300,
    timeout = 90000,
    keys = { "a", { "@complete", wait = "menu" }, "@select:long_field_name", { "@confirm", wait = 800 }, "<Esc>" },
    expected = {
      cmp = { "local tbl = { long_field_name = 1 }", "print(tbl.long_field_name)", "print(tbl.long_field_name)" },
      native = { "local tbl = { long_field_name = 1 }", "print(tbl.long_field_namezz)", "print(tbl.long_field_namezz)" },
    },
  },
  {
    -- Multi-line keyword snippet, typing over the first placeholder
    name = "keyword snippet",
    lines = { "-- header", "func", "func" },
    cursors = { { 2, 4 }, { 3, 4 } },
    lsp = { kind = "lua_ls" },
    requires = requires,
    options = options,
    cmp_replace = true,
    delay = 300,
    timeout = 90000,
    keys = { "a", { "@complete", wait = "menu" }, { "@confirm", wait = 800 }, "myname", "<Esc>" },
    expected = { "-- header", "function myname()", "\t", "end", "function myname()", "\t", "end" },
  },
}
