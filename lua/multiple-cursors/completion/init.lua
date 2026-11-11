-- Completion engine abstraction
--
-- Completion engines (native ins-completion, nvim-cmp, ...) write to the buffer
-- at the real cursor in their own way. Rather than reimplementing each engine's
-- insertion logic at every virtual cursor, a backend only reports:
--
--   is_writing()     The engine is writing to the buffer right now, so per
--                    character mirroring must be suppressed
--   bridge.begin()   The engine has started writing (marks the state dirty)
--   bridge.commit()  The engine has finished writing
--
-- The text at the real cursor is snapshotted at every sync point. When the
-- state is dirty, the change between the snapshot and the current text is
-- computed and replayed at each virtual cursor.
--
-- A backend that is writing has always changed the buffer, so is_writing()
-- also marks the state dirty. Then a change isn't missed if the events that a
-- backend uses to call bridge.begin() aren't triggered (e.g. keys typed
-- together).
--
-- Key maps of this plug-in call before_key() before they edit the virtual
-- cursors: the key ends the completion, so the change is replayed first, and a
-- backend can change the keys that are fed to the real cursor
-- (backend.transform_key).

local M = {}

local common = require("multiple-cursors.common")
local replay = require("multiple-cursors.completion.replay")

local builtin_backends = {
  native = "multiple-cursors.completion.backends.native",
  cmp = "multiple-cursors.completion.backends.cmp",
}

-- Configured backends (names of built-in backends or backend tables)
local configured_backends = { "native", "cmp" }

-- Attached backends
local active_backends = {}

-- A backend has written to the buffer since the snapshot was taken
local dirty = false

-- Functions called when a change is replayed
local replay_callbacks = {}

-- Incremented by each commit, so that only the latest one waits for the
-- backends to finish writing, and by detach to cancel it
local commit_generation = 0

-- Maximum time a commit waits for the backends to finish writing. After this the
-- change is replayed by the next key map or text change.
local commit_timeout = 2000

-- Names of backends that a warning has been shown for
local warned_backends = {}

-- Public functions -----------------------------------------------------------

-- Indicate that a backend has written to the buffer
function M.begin()
  dirty = true
end

-- Is any backend writing to the buffer
-- If so the state is marked dirty
function M.is_writing()
  for _, backend in ipairs(active_backends) do
    local ok, writing = pcall(backend.is_writing)
    if ok and writing then
      M.begin()
      return true
    end
  end
  return false
end

function M.is_dirty()
  return dirty
end

-- Call callback when a change is replayed
-- Characters that were typed since the snapshot was taken are part of the
-- change, so they must not be copied to the virtual cursors again
function M.on_replay(callback)
  table.insert(replay_callbacks, callback)
end

-- Take a snapshot if the state is synchronised
function M.sync()
  if not dirty and common.is_mode_insert_replace() then
    replay.capture()
  end
end

-- Replay any change made by a backend at the virtual cursors
-- opts.force: flush even if a backend is writing (see before_key)
-- Returns true if the virtual cursors were edited
function M.flush(opts)

  local writing = M.is_writing()

  if not dirty then
    return false
  end

  if writing and not (opts and opts.force) then
    return false
  end

  -- Wait until back in insert or replace mode (e.g. selecting a snippet placeholder)
  if not common.is_mode_insert_replace() then
    return false
  end

  dirty = false

  for _, callback in ipairs(replay_callbacks) do
    callback()
  end

  local edited = replay.apply()
  replay.capture()

  return edited

end

-- Prepare for a key map of this plug-in that edits the virtual cursors, then
-- feeds key to the real cursor
-- The key ends any completion, so a change made by a backend is replayed
-- first, even if the backend is still writing. Changing the buffer also stops
-- vim.lsp.completion applying a resolved item later.
-- Returns the keys to feed instead of key: a backend may end its completion in
-- its own way first (backend.transform_key is optional)
function M.before_key(key)

  local keys = key

  for _, backend in ipairs(active_backends) do
    if backend.transform_key then
      local ok, result = pcall(backend.transform_key, keys)
      if ok and type(result) == "string" then
        keys = result
      end
    end
  end

  M.flush({force = true})

  return keys

end

-- Flush after a backend has finished writing
local function commit()
  commit_generation = commit_generation + 1

  local generation = commit_generation
  local deadline = vim.uv.now() + commit_timeout

  local function try()
    -- Superseded by a later commit, cancelled, or already flushed
    if generation ~= commit_generation or not dirty then
      return
    end

    if M.is_writing() then
      if vim.uv.now() < deadline then
        vim.defer_fn(try, 10)
      end
      return
    end

    M.flush()
  end

  vim.schedule(try)
end

local bridge = {
  begin = M.begin,
  commit = commit,
}


-- Autocmd callbacks ----------------------------------------------------------

local function is_insert_mode(mode)
  local c = mode:sub(1, 1)
  return c == "i" or c == "R"
end

-- Select mode, e.g. a snippet placeholder
local function is_select_mode(mode)
  local c = mode:sub(1, 1)
  return c == "s" or c == "S" or c == "\19"
end

-- Reset the state when entering insert mode
-- The state isn't reset when leaving insert mode, because a completion engine
-- may select a snippet placeholder (insert -> normal -> visual -> select mode),
-- and the change is replayed when typing over the placeholder enters insert mode
-- again. Changes are only replayed in insert or replace mode, so the state left
-- when exiting to normal mode is discarded when insert mode is entered again.
local function mode_changed()
  local old_mode = vim.v.event.old_mode
  local new_mode = vim.v.event.new_mode

  if is_insert_mode(new_mode) and not is_insert_mode(old_mode) then
    if dirty and is_select_mode(old_mode) then
      return
    end

    -- Snapshot now, in case keys typed with the mode change start a completion
    -- before scheduled callbacks run, and again after the mode change is done
    dirty = false
    M.sync()
    vim.schedule(M.sync)
  end
end

local function cursor_moved_i()
  if M.is_writing() then
    return
  elseif dirty then
    M.flush()
  else
    M.sync()
  end
end


-- Setup, attach and detach ---------------------------------------------------

function M.setup(opts)
  opts = opts or {}

  if opts.backends then
    configured_backends = opts.backends
  end
end

-- Show a warning once for a backend
local function warn_once(name, message)
  if not warned_backends[name] then
    warned_backends[name] = true
    vim.notify("multiple-cursors: " .. message, vim.log.levels.WARN)
  end
end

-- Attach a backend, returns true if it's used
-- A backend that fails doesn't stop multiple cursors mode, it's just not used
local function attach_backend(backend, group)
  local name = tostring(backend.name or "?")

  if backend.available ~= nil then
    local ok, available = pcall(backend.available)
    if not ok then
      warn_once(name, "completion backend \"" .. name .. "\" failed: " .. tostring(available))
      return false
    end
    if not available then
      return false
    end
  end

  local ok, err = pcall(backend.attach, bridge, group)

  if not ok then
    warn_once(name, "completion backend \"" .. name .. "\" failed to attach: " .. tostring(err))
    if backend.detach then
      pcall(backend.detach)
    end
    return false
  end

  return true
end

-- Attach backends and create autocmds in group
function M.attach(group)

  active_backends = {}

  for _, backend in ipairs(configured_backends) do
    if type(backend) == "string" then
      local module = builtin_backends[backend]
      if module then
        backend = require(module)
      else
        warn_once(backend, "unknown completion backend \"" .. backend .. "\"")
        backend = nil
      end
    end

    if backend and attach_backend(backend, group) then
      table.insert(active_backends, backend)
    end
  end

  vim.api.nvim_create_autocmd({"ModeChanged"}, { group = group, callback = mode_changed })
  vim.api.nvim_create_autocmd({"CursorMovedI"}, { group = group, callback = cursor_moved_i })

  -- Initialising in insert mode
  dirty = false
  M.sync()

end

-- Detach backends
-- Autocmds are cleared with the group
function M.detach()

  for _, backend in ipairs(active_backends) do
    if backend.detach then
      pcall(backend.detach)
    end
  end

  active_backends = {}
  dirty = false

  -- Cancel a waiting commit
  commit_generation = commit_generation + 1

  replay.clear()

end

return M
