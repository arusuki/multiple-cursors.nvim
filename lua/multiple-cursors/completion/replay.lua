-- Track the completion at the real cursor and replay its text at virtual cursors.

local M = {}

local virtual_cursors = require("multiple-cursors.virtual_cursors")

local namespace_id = vim.api.nvim_create_namespace("multiple-cursors-completion")

-- Synchronised state of the real cursor:
-- { bufnr, line, col0, start_mark_id, end_mark_id, line_insertions }
local snapshot = nil

-- A buffer keeps its listener across snapshots. The next edit after detach
-- removes the listener if multiple cursors haven't reattached in the meantime.
local watched_buffers = {}

-- Snapshot -------------------------------------------------------------------

function M.clear()
  if snapshot then
    pcall(vim.api.nvim_buf_clear_namespace, snapshot.bufnr, namespace_id, 0, -1)
  end
  snapshot = nil
end

-- Keep the byte ranges of whole lines inserted in a separate edit (e.g. an
-- import). Changes at either boundary leave the inserted text intact. An edit
-- inside the range makes it part of the completion, as with a snippet field.
local function track_line_insertions(_, bufnr, _, _, col, start_byte, _, _, old_bytes, new_rows, new_col, new_bytes)
  if not snapshot or snapshot.bufnr ~= bufnr then
    watched_buffers[bufnr] = nil
    return true
  end
  local insertions = snapshot.line_insertions
  local byte_shift = new_bytes - old_bytes
  for i = #insertions, 1, -1 do
    local insertion = insertions[i]
    if start_byte + old_bytes <= insertion.first then
      insertion.first = insertion.first + byte_shift
      insertion.last = insertion.last + byte_shift
    elseif start_byte < insertion.last then
      table.remove(insertions, i)
    end
  end
  if col == 0 and old_bytes == 0 and new_rows > 0 and new_col == 0 then
    table.insert(insertions, { first = start_byte, last = start_byte + new_bytes })
  end
end

-- Save the line and cursor column of the real cursor. Extmarks with opposing
-- gravities enclose the line through edits, including multiline completions.
function M.capture()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row = pos[1] - 1
  local line = vim.api.nvim_get_current_line()

  if snapshot and snapshot.bufnr ~= bufnr then
    M.clear()
  end

  local old = snapshot or {}

  if not watched_buffers[bufnr] then
    watched_buffers[bufnr] = vim.api.nvim_buf_attach(bufnr, false, {
      on_bytes = track_line_insertions,
      on_detach = function() watched_buffers[bufnr] = nil end,
    })
  end

  snapshot = {
    bufnr = bufnr,
    line = line,
    col0 = math.min(pos[2], #line),
    line_insertions = {},
    start_mark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace_id, row, 0,
        { id = old.start_mark_id, right_gravity = false }),
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

-- Read both sides of the real cursor, excluding independently inserted lines.
local function read_completion_text(bufnr, old_after)
  local start_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace_id, snapshot.start_mark_id, {})
  local end_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace_id, snapshot.end_mark_id, {})

  if next(start_pos) == nil or next(end_pos) == nil then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local min_row = start_pos[1]
  local last_row = math.max(end_pos[1], row)

  -- The cursor must be within the changed region
  if row < min_row then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, min_row, last_row + 1, true)
  local text = table.concat(lines, "\n")
  local first_byte = vim.api.nvim_buf_get_offset(bufnr, min_row)
  local last_byte = first_byte + #text
  local cursor_byte = vim.api.nvim_buf_get_offset(bufnr, row) + math.min(cursor[2], #lines[row - min_row + 1])
  local offset = cursor_byte - first_byte

  -- Remove separate line insertions from right to left to preserve offsets.
  -- At a trailing newline, an unchanged suffix puts the cursor at the end of
  -- the multiline completion. A changed suffix can be a snippet starting
  -- with its final tabstop immediately after an import.
  local insertions = snapshot.line_insertions
  table.sort(insertions, function(a, b) return a.first > b.first end)
  for _, insertion in ipairs(insertions) do
    if insertion.first >= first_byte and insertion.last <= last_byte then
      local before = insertion.last < cursor_byte
          or (insertion.last == cursor_byte and text:sub(offset + 1) ~= old_after)
      local after = insertion.first >= cursor_byte and insertion.first > first_byte
      if before or after then
        text = text:sub(1, insertion.first - first_byte) .. text:sub(insertion.last - first_byte + 1)
        if before then offset = offset - (insertion.last - insertion.first) end
      end
    end
  end

  return text:sub(1, offset), text:sub(offset + 1)
end

local function compute_delta()
  local bufnr = vim.api.nvim_get_current_buf()
  if not snapshot or snapshot.bufnr ~= bufnr then
    return nil
  end

  local old_before = snapshot.line:sub(1, snapshot.col0)
  local old_after = snapshot.line:sub(snapshot.col0 + 1)
  local new_before, new_after = read_completion_text(bufnr, old_after)
  if new_before == nil or (old_before == new_before and old_after == new_after) then
    return nil
  end

  -- Include the start of the keyword so each virtual cursor can match its own prefix.
  local prefix_length = common_prefix_length(old_before, new_before)
  local start_col = vim.fn.match(old_before:sub(1, prefix_length), [[\k*$]])
  local suffix_length = common_suffix_length(old_after, new_after)
  return {
    old_before = old_before:sub(start_col + 1),
    new_before = new_before:sub(start_col + 1),
    old_after = old_after:sub(1, #old_after - suffix_length),
    new_after = new_after:sub(1, #new_after - suffix_length),
  }
end

-- Number of bytes to delete before a virtual cursor
local function matched_prefix_bytes(text_before, delta)

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

function M.apply()
  local delta = compute_delta()
  if not delta then return false end

  local replacement = delta.new_before .. delta.new_after
  local new_lines = vim.split(replacement, "\n", { plain = true })
  local before_lines = vim.split(delta.new_before, "\n", { plain = true })
  local cursor_row_offset = #before_lines - 1
  local cursor_col = #before_lines[#before_lines] + 1
  local mode = vim.api.nvim_get_mode().mode
  local replace_chars
  if mode == "R" or mode == "Rc" then
    replace_chars = vim.fn.strcharlen(replacement)
  end

  virtual_cursors.edit(function(vc)
    local row = vc.lnum - 1
    local line = vim.api.nvim_buf_get_lines(0, row, row + 1, true)[1]
    local col0 = math.min(vc.col - 1, #line)
    local text_before = line:sub(1, col0)
    local text_after = line:sub(col0 + 1)
    local start_col = col0 - matched_prefix_bytes(text_before, delta)
    local end_col = col0

    if replace_chars then
      -- Overwrite only the characters still needed after this cursor's prefix.
      local remaining = math.max(0, replace_chars - vim.fn.strcharlen(text_before:sub(start_col + 1)))
      end_col = col0 + #vim.fn.strcharpart(text_after, 0, remaining, 1)
    elseif text_after:sub(1, #delta.old_after) == delta.old_after then
      end_col = col0 + #delta.old_after
    end

    vim.api.nvim_buf_set_text(0, row, start_col, row, end_col, new_lines)
    vc.lnum = vc.lnum + cursor_row_offset
    vc.col = cursor_col + (cursor_row_offset == 0 and start_col or 0)
    vc.curswant = -1
  end)
  return true
end

return M
