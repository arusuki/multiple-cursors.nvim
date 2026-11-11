-- Runs one test case in this Neovim instance, started by tests/run.lua
--
-- Keys are fed with nvim_input and each step waits before the next one, so
-- that typeahead is processed by the main loop (vim.wait doesn't process it).
--
-- Steps (case.keys):
--   "<keys>"           fed with nvim_input
--   "@complete"        cmp.complete(), vim.lsp.completion.get(), or <C-p>
--   "@confirm"         <CR> for cmp, <C-y> for native if the menu is visible
--   "@next"            cmp.select_next_item(), or <C-n>
--   "@select:<label>"  select the item with the label
--   function(ctx)      called; ctx.assert(cond, msg) records a failure
--   { step, wait = ms | "menu" }  wait a time, or until the menu is visible

local root = vim.env.MC_TEST_ROOT
local deps = vim.env.MC_TEST_DEPS
local tmp = vim.env.MC_TEST_TMP
local engine = vim.env.MC_TEST_ENGINE

local result = { ok = false, errors = {}, log = {} }

local function log(...)
  table.insert(result.log, table.concat(vim.tbl_map(tostring, { ... }), " "))
end

local finished = false

local function finish()
  if finished then return end
  finished = true
  result.ok = #result.errors == 0
  vim.fn.writefile({ vim.json.encode(result) }, vim.env.MC_TEST_RESULT)

  -- Stop language servers so that they don't outlive the case
  for _, client in ipairs(vim.lsp.get_clients()) do
    pcall(client.stop, client)
  end
  vim.wait(3000, function() return #vim.lsp.get_clients() == 0 end)

  vim.cmd("qa!")
end

local function fail(msg)
  table.insert(result.errors, msg)
end

-- Runtime path -----------------------------------------------------------------

vim.opt.rtp:prepend(root)
for _, dep in ipairs({ "nvim-cmp", "cmp-buffer", "cmp-nvim-lsp" }) do
  vim.opt.rtp:append(deps .. "/" .. dep)
end
vim.cmd("runtime! plugin/**/*.lua plugin/**/*.vim after/plugin/**/*.lua")

-- Case -------------------------------------------------------------------------

-- Cases can share a name if they are for different engines
local case = nil
for _, c in ipairs(dofile(root .. "/tests/cases/" .. vim.env.MC_TEST_FILE .. ".lua")) do
  if c.name == vim.env.MC_TEST_CASE and vim.tbl_contains(c.engines or { "cmp", "native" }, engine) then
    case = c
  end
end
assert(case, "case not found: " .. vim.env.MC_TEST_CASE)

local expected = case.expected
if expected[1] == nil then
  expected = expected[engine]
end

for option, value in pairs(case.options or {}) do
  vim.o[option] = value
end

-- Completion engines -----------------------------------------------------------

local cmp = require("cmp")
cmp.setup({
  enabled = engine == "cmp",
  sources = { { name = case.lsp and "nvim_lsp" or "buffer", option = { keyword_length = 1 } } },
  snippet = { expand = function(args) vim.snippet.expand(args.body) end },
  mapping = cmp.mapping.preset.insert({
    ["<CR>"] = cmp.mapping.confirm({
      select = true,
      behavior = case.cmp_replace and cmp.ConfirmBehavior.Replace or cmp.ConfirmBehavior.Insert,
    }),
  }),
  completion = { autocomplete = false },
})

local mc = require("multiple-cursors")
mc.setup({ completion = engine == "native" and { backends = { "native" } } or nil })

-- Buffer -----------------------------------------------------------------------

if case.lsp and case.lsp.kind == "lua_ls" then
  -- lua_ls needs a file in a workspace
  local ws = tmp .. "/luals-ws"
  vim.fn.mkdir(ws, "p")
  local file = ws .. "/" .. case.name:gsub("%W", "_") .. "_" .. engine .. ".lua"
  vim.fn.writefile(case.lines, file)
  vim.cmd.edit(vim.fn.fnameescape(file))
else
  vim.api.nvim_buf_set_lines(0, 0, -1, false, case.lines)
end

-- Language server --------------------------------------------------------------

local client_id = nil

if case.lsp then
  local config = {
    root_dir = tmp,
    capabilities = engine == "cmp" and require("cmp_nvim_lsp").default_capabilities() or nil,
  }

  if case.lsp.kind == "fake" then
    config.name = "fake"
    config.cmd = dofile(root .. "/tests/helpers/fake_lsp.lua")(case.lsp)
  elseif case.lsp.kind == "lua_ls" then
    config.name = "lua_ls"
    config.root_dir = tmp .. "/luals-ws"
    config.cmd = { "lua-language-server", "--logpath=" .. tmp .. "/luals-log", "--metapath=" .. tmp .. "/luals-meta" }
    config.settings = { Lua = {
      runtime = { version = "LuaJIT" },
      workspace = { library = {}, checkThirdParty = false },
      diagnostics = { enable = false },
      completion = { keywordSnippet = "Replace", callSnippet = "Disable" },
    } }
  end

  client_id = vim.lsp.start(config, { bufnr = 0 })

  if engine == "native" then
    vim.lsp.completion.enable(true, client_id, 0, { autotrigger = false })
  end
end

-- Helpers ----------------------------------------------------------------------

local function menu_visible()
  if engine == "cmp" then return cmp.visible() end
  return vim.fn.pumvisible() == 1
end

local function wait_until(pred, timeout, callback)
  local start = vim.uv.now()
  local function poll()
    local ok, done = pcall(pred)
    if ok and done then
      callback(true)
    elseif vim.uv.now() - start > timeout then
      callback(false)
    else
      vim.defer_fn(poll, 50)
    end
  end
  poll()
end

-- Wait until the language server answers completion requests with items
local function wait_for_server(callback)
  wait_until(function()
    local client = vim.lsp.get_client_by_id(client_id)
    return client and client.initialized
  end, 30000, function(initialized)
    if not initialized then return callback(false) end

    local start = vim.uv.now()
    local function try()
      local params = vim.lsp.util.make_position_params(0, "utf-16")
      params.position = { line = case.cursors[1][1] - 1, character = case.cursors[1][2] }
      vim.lsp.buf_request_all(0, "textDocument/completion", params, function(responses)
        local count = 0
        for _, response in pairs(responses) do
          local items = response.result and (response.result.items or response.result) or {}
          count = count + #items
        end
        if count > 0 then
          callback(true)
        elseif vim.uv.now() - start > 30000 then
          callback(false)
        else
          vim.defer_fn(try, 300)
        end
      end)
    end
    try()
  end)
end

local ctx = {
  engine = engine,
  cmp = cmp,
  log = log,
  assert = function(cond, msg)
    if not cond then fail(msg or "assertion failed") end
  end,
}

local function select_item(label)
  if engine == "cmp" then
    for _ = 1, 20 do
      local entry = cmp.get_selected_entry()
      if entry and entry.completion_item.label == label then return end
      cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
    end
    fail("item not found: " .. label)
  else
    local info = vim.fn.complete_info({ "items", "selected" })
    for i, item in ipairs(info.items) do
      if item.word == label then
        vim.api.nvim_input(string.rep("<C-n>", (i - 1) - info.selected))
        return
      end
    end
    fail("item not found: " .. label)
  end
end

local function do_step(step)
  if type(step) == "function" then
    step(ctx)
  elseif step == "@complete" then
    if engine == "cmp" then
      cmp.complete()
    elseif case.lsp then
      vim.lsp.completion.get()
    else
      vim.api.nvim_input("<C-p>")
    end
  elseif step == "@confirm" then
    if engine == "cmp" then
      vim.api.nvim_input("<CR>")
    elseif vim.fn.pumvisible() == 1 then
      vim.api.nvim_input("<C-y>")
    end
  elseif step == "@next" then
    if engine == "cmp" then cmp.select_next_item() else vim.api.nvim_input("<C-n>") end
  elseif step:sub(1, 8) == "@select:" then
    select_item(step:sub(9))
  else
    vim.api.nvim_input(step)
  end
end

-- Steps ------------------------------------------------------------------------

local function check()
  local got = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  result.got = got
  result.expected = expected
  if not vim.deep_equal(got, expected) then
    fail("buffer doesn't match")
  end
  finish()
end

local function run_step(i)
  local step = case.keys[i]
  if step == nil then
    return check()
  end

  local wait = case.delay or 250
  if type(step) == "table" then
    wait = step.wait or wait
    step = step[1]
  end

  local ok, err = pcall(do_step, step)
  if not ok then
    fail("step " .. i .. ": " .. tostring(err))
    return finish()
  end

  if wait == "menu" then
    wait_until(menu_visible, 10000, function(visible)
      if not visible then log("step " .. i .. ": menu not visible") end
      run_step(i + 1)
    end)
  else
    vim.defer_fn(function() run_step(i + 1) end, wait)
  end
end

local function start()
  -- First cursor is the real cursor
  vim.fn.cursor(case.cursors[1][1], case.cursors[1][2])

  ctx.cmp_listeners_before = #(cmp.core.event.events.confirm_done or {})

  for i = 2, #case.cursors do
    mc.add_cursor(case.cursors[i][1], case.cursors[i][2], case.cursors[i][2])
  end

  vim.defer_fn(function() run_step(1) end, case.start_delay or 100)
end

vim.defer_fn(function()
  fail("timeout")
  finish()
end, case.timeout or 60000)

if case.lsp then
  wait_for_server(function(ready)
    if not ready then
      fail("language server not ready")
      return finish()
    end
    start()
  end)
else
  start()
end
