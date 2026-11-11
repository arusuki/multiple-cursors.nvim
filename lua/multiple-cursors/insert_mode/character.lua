local M = {}

local common = require("multiple-cursors.common")
local virtual_cursors = require("multiple-cursors.virtual_cursors")
local completion = require("multiple-cursors.completion")

-- Characters to insert
-- More than one InsertCharPre event can occur before TextChangedI, e.g. when
-- keys are fed
local chars = nil

-- A character that a key map has already inserted at the virtual cursors, to
-- ignore when the key inserts it at the real cursor
local ignored_char = nil

-- Discard any characters to insert
-- Used when a completion delta is replayed, because it includes the characters
function M.discard_pending()
  chars = nil
end

-- Ignore the next InsertCharPre for char
-- E.g. with 'noexpandtab' <Tab> is inserted as a character, but the <Tab> key
-- map has already inserted it at the virtual cursors
-- Cleared by TextChangedI, i.e. when the key has been processed
function M.ignore_next_char(char)
  ignored_char = char
end

-- Callback for InsertCharPre event
function M.insert_char_pre(event)
  -- A completion engine is inserting text, this is replayed when it's finished
  if completion.is_writing() then
    completion.begin()
    return
  end

  if ignored_char and vim.v.char == ignored_char then
    ignored_char = nil
    return
  end

  -- Save the inserted character
  chars = (chars or "") .. vim.v.char
end

-- Callback for the TextChangedI event
function M.text_changed_i(event)

  ignored_char = nil

  if completion.is_writing() then
    completion.begin()
    return
  end

  -- Text was inserted by a completion engine
  if completion.is_dirty() then
    completion.flush()
    return
  end

  -- If there are saved characters
  if chars then

    local num_chars = vim.fn.strchars(chars)

    -- Put them to virtual cursors
    virtual_cursors.edit_with_cursor(function(vc)

      -- Delete characters if in replace mode
      if common.is_mode("R") then
        vim.cmd("normal! \"_" .. num_chars .. "x")
      end

      -- Put the characters
      vim.api.nvim_put({chars}, "c", false, true)
    end)
    chars = nil
  end

  completion.sync()

end

return M
