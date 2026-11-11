local function jump_case(name, lines, cursor, command, destination, expected)
  return {
    name = name,
    engines = { "native" },
    lines = lines,
    cursors = { cursor },
    keys = {
      function(ctx)
        vim.cmd(command)
        local pos = { vim.fn.line("."), vim.fn.col(".") }
        ctx.assert(vim.deep_equal(pos, destination), "real cursor at " .. vim.inspect(pos))
      end,
      "rX",
    },
    expected = expected,
  }
end

return {
  jump_case("next from inside word", { "word", "word", "word" }, { 2, 3 },
    "MultipleCursorsAddJumpNextMatch", { 3, 1 }, { "word", "Xord", "Xord" }),
  jump_case("previous on same line", { "word word word" }, { 1, 8 },
    "MultipleCursorsAddJumpPrevMatch", { 1, 1 }, { "Xord Xord word" }),
  jump_case("next wraps", { "word word word" }, { 1, 14 },
    "MultipleCursorsAddJumpNextMatch", { 1, 1 }, { "Xord word Xord" }),
  jump_case("only occurrence", { "word" }, { 1, 3 },
    "MultipleCursorsAddJumpNextMatch", { 1, 3 }, { "woXd" }),
}
