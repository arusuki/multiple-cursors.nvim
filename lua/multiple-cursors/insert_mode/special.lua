local M = {}

local common = require("multiple-cursors.common")
local virtual_cursors = require("multiple-cursors.virtual_cursors")
local completion = require("multiple-cursors.completion")
local extmarks = require("multiple-cursors.extmarks")

-- Delete word
function M.c_w()
  local keys = completion.before_key("<C-w>")
  virtual_cursors.edit_with_normal_command(0, "db", nil)
  common.feedkeys(nil, 0, keys, nil)
end

-- Indent
function M.c_t()
  local keys = completion.before_key("<C-t>")

  -- Update the cursor position from the extmark so that the cursor stays in place
  virtual_cursors.edit_with_cursor_no_save(function(vc)
    common.normal_bang(nil, 0, ">>", nil)
    extmarks.update_virtual_cursor_position(vc)
  end)

  common.feedkeys(nil, 0, keys, nil)
end

-- Deindent
function M.c_d()
  local keys = completion.before_key("<C-d>")

  -- Update the cursor position from the extmark so that the cursor stays in place
  virtual_cursors.edit_with_cursor_no_save(function(vc)
    common.normal_bang(nil, 0, "<<", nil)
    extmarks.update_virtual_cursor_position(vc)
  end)

  common.feedkeys(nil, 0, keys, nil)
end

return M
