-- Test runner
--
-- Usage: nvim -l tests/run.lua [filter...]
--
-- Each case is run for each of its completion engines in a separate headless
-- Neovim instance (tests/runner.lua), with an isolated configuration.
-- A filter matches a substring of "<file>/<case> [<engine>]".

local root = vim.fn.fnamemodify(arg[0], ":p:h:h")
local tests_dir = root .. "/tests"
local deps_dir = vim.env.MC_TEST_DEPS or (tests_dir .. "/.deps")
local tmp_dir = tests_dir .. "/.tmp"

local deps = {
  { name = "nvim-cmp", url = "https://github.com/hrsh7th/nvim-cmp", commit = "fe29aba4117227a6df637bc41e4b4fb4e98864a0" },
  { name = "cmp-buffer", url = "https://github.com/hrsh7th/cmp-buffer", commit = "b74fab3656eea9de20a9b8116afa3cfc4ec09657" },
  { name = "cmp-nvim-lsp", url = "https://github.com/hrsh7th/cmp-nvim-lsp", commit = "cd4ee08a988deb47ac3726f418fb27fe1a95729d" },
}

local function run(cmd, opts)
  local result = vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait()
  return result.code == 0, result
end

-- Clone the dependencies at their pinned commits
local function ensure_deps()
  vim.fn.mkdir(deps_dir, "p")

  for _, dep in ipairs(deps) do
    local dir = deps_dir .. "/" .. dep.name
    local ok, result = run({ "git", "-C", dir, "rev-parse", "HEAD" })

    if not (ok and vim.trim(result.stdout) == dep.commit) then
      io.write("Fetching " .. dep.name .. " " .. dep.commit:sub(1, 7) .. "\n")
      vim.fn.delete(dir, "rf")
      vim.fn.mkdir(dir, "p")
      for _, cmd in ipairs({
        { "git", "-C", dir, "init", "-q" },
        { "git", "-C", dir, "fetch", "-q", "--depth", "1", dep.url, dep.commit },
        { "git", "-C", dir, "checkout", "-q", "FETCH_HEAD" },
      }) do
        local cmd_ok, cmd_result = run(cmd)
        if not cmd_ok then
          io.write("Failed: " .. table.concat(cmd, " ") .. "\n" .. (cmd_result.stderr or "") .. "\n")
          os.exit(2)
        end
      end
    end
  end
end

-- Returns nil if the case can run, otherwise the reason to skip it
local function skip_reason(case)
  local requires = case.requires or {}
  if requires.nvim and vim.fn.has("nvim-" .. requires.nvim) == 0 then
    return "requires Neovim " .. requires.nvim
  end
  if requires.executable and vim.fn.executable(requires.executable) == 0 then
    return requires.executable .. " not found"
  end
  return nil
end

local function collect_cases(filters)
  local jobs = {}
  local files = vim.fn.glob(tests_dir .. "/cases/*.lua", false, true)
  table.sort(files)

  for _, path in ipairs(files) do
    local file = vim.fn.fnamemodify(path, ":t:r")
    for _, case in ipairs(dofile(path)) do
      for _, engine in ipairs(case.engines or { "cmp", "native" }) do
        local id = file .. "/" .. case.name .. " [" .. engine .. "]"
        local matched = #filters == 0
        for _, filter in ipairs(filters) do
          if id:find(filter, 1, true) then matched = true end
        end
        if matched then
          table.insert(jobs, { id = id, file = file, case = case, engine = engine })
        end
      end
    end
  end

  return jobs
end

local function run_job(job)
  -- Per runner process, so that concurrent runs don't remove each other's results
  local result_file = tmp_dir .. "/result-" .. vim.fn.getpid() .. ".json"
  vim.fn.delete(result_file)

  local env = {
    MC_TEST_ROOT = root,
    MC_TEST_DEPS = deps_dir,
    MC_TEST_TMP = tmp_dir,
    MC_TEST_FILE = job.file,
    MC_TEST_CASE = job.case.name,
    MC_TEST_ENGINE = job.engine,
    MC_TEST_RESULT = result_file,
    XDG_CONFIG_HOME = tmp_dir .. "/xdg/config",
    XDG_DATA_HOME = tmp_dir .. "/xdg/data",
    XDG_STATE_HOME = tmp_dir .. "/xdg/state",
    XDG_CACHE_HOME = tmp_dir .. "/xdg/cache",
  }

  local timeout = job.case.timeout or 60000
  local _, process = run({
    vim.v.progpath, "--clean", "--headless", "-i", "NONE",
    "-c", "luafile " .. vim.fn.fnameescape(tests_dir .. "/runner.lua"),
  }, { env = env, timeout = timeout + 10000 })

  if vim.fn.filereadable(result_file) == 0 then
    return { ok = false, errors = { "no result (exit code " .. process.code .. ")" }, stderr = process.stderr }
  end

  local result = vim.json.decode(table.concat(vim.fn.readfile(result_file), "\n"))
  vim.fn.delete(result_file)
  return result
end

local function print_failure(result)
  for _, err in ipairs(result.errors or {}) do
    io.write("    " .. err .. "\n")
  end
  if result.expected and result.got then
    io.write("    expected:\n")
    for _, line in ipairs(result.expected) do io.write("      " .. vim.inspect(line) .. "\n") end
    io.write("    got:\n")
    for _, line in ipairs(result.got) do io.write("      " .. vim.inspect(line) .. "\n") end
  end
  if result.log and #result.log > 0 then
    io.write("    log:\n")
    for _, line in ipairs(result.log) do io.write("      " .. line .. "\n") end
  end
end

local filters = {}
for i = 1, #arg do table.insert(filters, arg[i]) end

ensure_deps()
vim.fn.mkdir(tmp_dir, "p")

local passed, failed, skipped = 0, 0, 0
local failures = {}

for _, job in ipairs(collect_cases(filters)) do
  local reason = skip_reason(job.case)
  if reason then
    skipped = skipped + 1
    io.write("SKIP " .. job.id .. " (" .. reason .. ")\n")
  else
    local result = run_job(job)
    if result.ok then
      passed = passed + 1
      io.write("PASS " .. job.id .. "\n")
    else
      failed = failed + 1
      table.insert(failures, job.id)
      io.write("FAIL " .. job.id .. "\n")
      print_failure(result)
    end
  end
end

io.write(("\n%d passed, %d failed, %d skipped\n"):format(passed, failed, skipped))
for _, id in ipairs(failures) do io.write("  failed: " .. id .. "\n") end

os.exit(failed == 0 and 0 or 1)
