local M = {}

local common = require("multiple-cursors.common")
local virtual_cursors = require("multiple-cursors.virtual_cursors")
local completion = require("multiple-cursors.completion")

local function normal_command_and_feedkeys(cmd, key)
  local keys = completion.before_key(key)
  virtual_cursors.move_with_normal_command(0, cmd)
  common.feedkeys(nil, 0, keys, nil)
end

function M.up()
  normal_command_and_feedkeys("k", "<Up>")
end

function M.down()
  normal_command_and_feedkeys("j", "<Down>")
end

function M.left()
  normal_command_and_feedkeys("h", "<Left>")
end

function M.right()
  normal_command_and_feedkeys("l", "<Right>")
end

function M.home()
  normal_command_and_feedkeys("0", "<Home>")
end

function M.eol()
  normal_command_and_feedkeys("$", "<End>")
end

function M.word_left()
  normal_command_and_feedkeys("b", "<C-Left>")
end

function M.word_right()
  normal_command_and_feedkeys("w", "<C-Right>")
end

return M
