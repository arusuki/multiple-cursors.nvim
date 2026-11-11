-- Completion engine abstraction
--
-- Completion engines (native ins-completion, nvim-cmp, ...) write to the buffer
-- at the real cursor in their own way. Rather than reimplementing each engine's
-- insertion logic at every virtual cursor, a backend only reports two things:
--
--   is_writing()     The engine is writing to the buffer right now, so per
--                    character mirroring must be suppressed
--   bridge.begin()   The engine has started writing (marks the state dirty)
--   bridge.commit()  The engine has finished writing
--
-- The text at the real cursor is snapshotted at every sync point. When the
-- state is dirty, the change between the snapshot and the current text is
-- computed and replayed at each virtual cursor.

local M = {}

local common = require("multiple-cursors.common")
local virtual_cursors = require("multiple-cursors.virtual_cursors")

local builtin_backends = {
  native = "multiple-cursors.completion.backends.native",
  cmp = "multiple-cursors.completion.backends.cmp",
}

-- Configured backends (names of built-in backends or backend tables)
local configured_backends = { "native", "cmp" }

-- Attached backends
local active_backends = {}

local namespace_id = nil

-- Synchronised state of the real cursor:
-- { bufnr, line, col0, start_mark_id, start_right_mark_id, end_mark_id }
local snapshot = nil

-- A backend has written to the buffer since the snapshot was taken
local dirty = false

-- Snapshot -------------------------------------------------------------------

local function clear_snapshot()
  if snapshot and namespace_id then
    pcall(vim.api.nvim_buf_clear_namespace, snapshot.bufnr, namespace_id, 0, -1)
  end
  snapshot = nil
end

-- Save the line and cursor column of the real cursor
-- Extmarks track the line through changes to other lines and new lines inserted
-- by the completion:
-- - The start of the line has a left gravity and a right gravity extmark. Lines
--   inserted at the start of the line (e.g. an import added by a language
--   server) move the right gravity extmark, and the completion replacing text
--   from the start of the line with multiple lines moves it too. The start of
--   the line is between the two extmarks.
-- - The end of the line has a right gravity extmark
local function take_snapshot()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row = pos[1] - 1
  local line = vim.api.nvim_get_current_line()

  if snapshot and snapshot.bufnr ~= bufnr then
    clear_snapshot()
  end

  local old = snapshot or {}

  snapshot = {
    bufnr = bufnr,
    line = line,
    col0 = math.min(pos[2], #line),
    start_mark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace_id, row, 0,
        { id = old.start_mark_id, right_gravity = false }),
    start_right_mark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace_id, row, 0,
        { id = old.start_right_mark_id, right_gravity = true }),
    end_mark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace_id, row, #line,
        { id = old.end_mark_id, right_gravity = true }),
  }
end


-- Delta ----------------------------------------------------------------------

-- Is the byte a UTF-8 continuation byte
local function is_continuation_byte(b)
  return b ~= nil and b >= 0x80 and b < 0xC0
end

-- Number of bytes in the common prefix of a and b, on a character boundary
local function common_prefix_length(a, b)
  local n = 0
  for i = 1, math.min(#a, #b) do
    if a:byte(i) ~= b:byte(i) then break end
    n = i
  end
  while n > 0 and is_continuation_byte(a:byte(n + 1)) do
    n = n - 1
  end
  return n
end

-- Number of bytes in the common suffix of a and b, on a character boundary
local function common_suffix_length(a, b)
  local n = 0
  for i = 1, math.min(#a, #b) do
    if a:byte(#a - i + 1) ~= b:byte(#b - i + 1) then break end
    n = i
  end
  while n > 0 and is_continuation_byte(a:byte(#a - n + 1)) do
    n = n - 1
  end
  return n
end

-- Compute the change made at the real cursor since the snapshot
-- Returns nil if it can't be determined, otherwise a table with:
--   old_before, new_before: text before the cursor that was replaced
--   old_after, new_after:   text after the cursor that was replaced
local function compute_delta()

  local bufnr = vim.api.nvim_get_current_buf()

  if not snapshot or snapshot.bufnr ~= bufnr then
    return nil
  end

  local start_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace_id, snapshot.start_mark_id, {})
  local start_right_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace_id, snapshot.start_right_mark_id, {})
  local end_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace_id, snapshot.end_mark_id, {})

  if next(start_pos) == nil or next(start_right_pos) == nil or next(end_pos) == nil then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local min_row = start_pos[1]
  local max_row = math.min(start_right_pos[1], row)
  local last_row = math.max(end_pos[1], row)

  -- The cursor must be within the changed region
  if row < min_row then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, min_row, last_row + 1, true)

  local before0 = snapshot.line:sub(1, snapshot.col0)
  local after0 = snapshot.line:sub(snapshot.col0 + 1)

  -- Find the row where the line starts: the one with the longest common prefix
  -- with the text before the cursor in the snapshot (the earliest if equal)
  local before1, after1, p = nil, nil, -1

  for first_row = min_row, max_row do
    local first = first_row - min_row + 1
    local text = table.concat(lines, "\n", first)

    -- Byte offset of the cursor in text
    local offset = 0
    for i = first, row - min_row do
      offset = offset + #lines[i] + 1
    end
    offset = offset + math.min(cursor[2], #lines[row - min_row + 1])

    local candidate = text:sub(1, offset)
    local n = common_prefix_length(before0, candidate)

    if n > p then
      before1, after1, p = candidate, text:sub(offset + 1), n
    end
  end

  -- Text before the cursor: extend the replaced region back to the start of the
  -- keyword, so that the replaced word can be matched at each virtual cursor
  p = vim.fn.match(before0:sub(1, p), [[\k*$]])

  -- Text after the cursor
  local s = common_suffix_length(after0, after1)

  return {
    old_before = before0:sub(p + 1),
    new_before = before1:sub(p + 1),
    old_after = after0:sub(1, #after0 - s),
    new_after = after1:sub(1, #after1 - s),
  }

end

-- Number of bytes to delete before a virtual cursor
local function get_num_bytes_before(text_before, delta)

  -- The virtual cursor has the same text as the real cursor
  if delta.old_before == "" or text_before:sub(-#delta.old_before) == delta.old_before then
    return #delta.old_before
  end

  -- Otherwise find the longest text before the cursor that matches the start of
  -- the new text (case insensitive)
  local num_chars = vim.fn.strchars(text_before)
  local max = math.min(num_chars, vim.fn.strchars(delta.new_before))

  for n = max, 1, -1 do
    local tail = vim.fn.strcharpart(text_before, num_chars - n)
    if tail:lower() == vim.fn.strcharpart(delta.new_before, 0, n):lower() then
      return #tail
    end
  end

  return 0

end

-- Number of bytes to delete after a virtual cursor
local function get_num_bytes_after(text_after, delta)

  if delta.old_after == "" then
    return 0
  end

  if text_after:sub(1, #delta.old_after) == delta.old_after then
    return #delta.old_after
  end

  -- Replace mode overwrites characters
  if common.is_mode("R") or common.is_mode("Rc") then
    local n = vim.fn.strchars(delta.old_after)
    return #vim.fn.strcharpart(text_after, 0, n)
  end

  return 0

end

-- Replay the delta at a virtual cursor
local function replay(vc, delta)

  local row = vc.lnum - 1
  local line = vim.api.nvim_buf_get_lines(0, row, row + 1, true)[1]
  local col0 = math.min(vc.col - 1, #line)

  local text_before = line:sub(1, col0)
  local text_after = line:sub(col0 + 1)

  local start_col = col0 - get_num_bytes_before(text_before, delta)
  local end_col = col0 + get_num_bytes_after(text_after, delta)

  local new_lines = vim.split(delta.new_before .. delta.new_after, "\n", { plain = true })
  vim.api.nvim_buf_set_text(0, row, start_col, row, end_col, new_lines)

  -- Move the virtual cursor to the end of new_before
  local before_lines = vim.split(delta.new_before, "\n", { plain = true })

  if #before_lines == 1 then
    vc.col = start_col + #before_lines[1] + 1
  else
    vc.lnum = vc.lnum + #before_lines - 1
    vc.col = #before_lines[#before_lines] + 1
  end

  vc.curswant = -1

end


-- Public functions -----------------------------------------------------------

-- Is any backend writing to the buffer
function M.is_writing()
  for _, backend in ipairs(active_backends) do
    local ok, writing = pcall(backend.is_writing)
    if ok and writing then
      return true
    end
  end
  return false
end

-- Indicate that a backend has written to the buffer
function M.begin()
  dirty = true
end

function M.is_dirty()
  return dirty
end

-- Take a snapshot if the state is synchronised
function M.sync()
  if not dirty and common.is_mode_insert_replace() then
    take_snapshot()
  end
end

-- Replay any change made by a backend at the virtual cursors
-- opts.force: flush even if a backend is writing. This is used by key maps
-- before they edit the virtual cursors: the key ends the completion, and
-- changing the buffer stops vim.lsp.completion applying a resolved item later.
-- Returns true if the virtual cursors were edited
function M.flush(opts)

  if not dirty then
    return false
  end

  if not (opts and opts.force) and M.is_writing() then
    return false
  end

  -- Wait until back in insert or replace mode (e.g. selecting a snippet placeholder)
  if not common.is_mode_insert_replace() then
    return false
  end

  dirty = false

  -- Any pending characters are part of the delta
  require("multiple-cursors.insert_mode.character").discard_pending()

  local delta = compute_delta()

  local edited = false

  if delta and (delta.old_before ~= delta.new_before or delta.old_after ~= delta.new_after) then
    virtual_cursors.edit(function(vc)
      replay(vc, delta)
    end)
    edited = true
  end

  take_snapshot()

  return edited

end

-- Flush after a backend has finished writing
local function commit()
  local tries = 0

  local function try()
    if not dirty then
      return
    end

    if M.is_writing() then
      tries = tries + 1
      if tries < 200 then
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
    dirty = true
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

  namespace_id = vim.api.nvim_create_namespace("multiple-cursors-completion")
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
        vim.notify("multiple-cursors: unknown completion backend \"" .. backend .. "\"", vim.log.levels.WARN)
        backend = nil
      end
    end

    if backend and (backend.available == nil or backend.available()) then
      backend.attach(bridge, group)
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
      backend.detach()
    end
  end

  active_backends = {}
  dirty = false
  clear_snapshot()

end

return M
