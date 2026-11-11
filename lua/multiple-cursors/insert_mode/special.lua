local M = {}

local common = require("multiple-cursors.common")
local virtual_cursors = require("multiple-cursors.virtual_cursors")
local completion = require("multiple-cursors.completion")
local extmarks = require("multiple-cursors.extmarks")

-- Delete word
function M.c_w()
  completion.flush({force = true})
  virtual_cursors.edit_with_normal_command(0, "db", nil)
  common.feedkeys(nil, 0, "<C-w>", nil)
end

-- Indent
function M.c_t()
  completion.flush({force = true})

  -- Update the cursor position from the extmark so that the cursor stays in place
  virtual_cursors.edit_with_cursor_no_save(function(vc)
    common.normal_bang(nil, 0, ">>", nil)
    extmarks.update_virtual_cursor_position(vc)
  end)

  common.feedkeys(nil, 0, "<C-t>", nil)
end

-- Deindent
function M.c_d()
  completion.flush({force = true})

  -- Update the cursor position from the extmark so that the cursor stays in place
  virtual_cursors.edit_with_cursor_no_save(function(vc)
    common.normal_bang(nil, 0, "<<", nil)
    extmarks.update_virtual_cursor_position(vc)
  end)

  common.feedkeys(nil, 0, "<C-d>", nil)
end

return M
