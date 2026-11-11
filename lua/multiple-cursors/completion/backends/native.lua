-- Backend for Neovim's built-in insert mode completion (ins-completion)
-- This covers CTRL-N/CTRL-P, CTRL-X submodes, 'autocomplete' and
-- vim.lsp.completion, which all use the popup menu and the CompleteDone event

local M = {}

M.name = "native"

function M.available()
  return true
end

-- Time an item was accepted, while waiting for vim.lsp.completion to resolve it
local accepted_time = nil

-- b:changedtick when the item was accepted
local accepted_tick = nil

-- Maximum time to wait for an accepted item to be resolved, so that a server
-- that doesn't respond doesn't stop characters being copied to virtual cursors
local resolve_timeout = 1000

-- vim.lsp.completion resolves an accepted item asynchronously, then expands a
-- snippet and applies additional text edits, but only if the buffer hasn't
-- changed since CompleteDone
-- Returns true while a completionItem/resolve request is in flight after an
-- item was accepted and the buffer hasn't changed, i.e. while the resolved item
-- will still be applied. A key map that changes the buffer (including replaying
-- the completion at the virtual cursors) ends this.
function M.is_pending()
  if not accepted_time then
    return false
  end

  if vim.uv.now() - accepted_time <= resolve_timeout and vim.b.changedtick == accepted_tick then
    for _, client in ipairs(vim.lsp.get_clients({bufnr = 0})) do
      for _, request in pairs(client.requests or {}) do
        if request.type == "pending" and request.method == "completionItem/resolve" then
          return true
        end
      end
    end
  end

  accepted_time = nil
  accepted_tick = nil
  return false
end

-- Completion text has been inserted at the real cursor
-- Note: when there's a single match the popup menu isn't shown and
-- CompleteChanged isn't triggered, so the completion mode is checked
function M.is_writing()
  local info = vim.fn.complete_info({"mode", "selected"})
  if info.mode ~= "" and info.mode ~= "ctrl_x" and info.selected ~= -1 then
    return true
  end
  return M.is_pending()
end

function M.attach(bridge, group)

  -- Selecting an item inserts it
  vim.api.nvim_create_autocmd({"CompleteChanged", "TextChangedP"}, {
    group = group,
    callback = function()
      if M.is_writing() then
        bridge.begin()
      end
    end,
  })

  -- Completion accepted, cancelled, or discarded
  -- vim.lsp.completion applies text edits in its own CompleteDone autocmd
  vim.api.nvim_create_autocmd({"CompleteDone"}, {
    group = group,
    callback = function()
      -- Accepted (e.g. CTRL-Y): the item was inserted, but CompleteChanged and
      -- TextChangedP may not have been triggered if the keys were typed
      -- together. When a key map of this plug-in ends the completion, the reason
      -- is "discard" and the key map has already replayed the completion.
      if vim.v.event.reason == "accept" then
        accepted_time = vim.uv.now()
        accepted_tick = vim.b.changedtick
        bridge.begin()
      end
      bridge.commit()
    end,
  })

end

function M.detach()
  accepted_time = nil
  accepted_tick = nil
end

return M
