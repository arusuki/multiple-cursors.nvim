-- Backend for nvim-cmp (https://github.com/hrsh7th/nvim-cmp)
--
-- nvim-cmp writes to the buffer (confirming, inserting a selected item,
-- aborting) with feedkeys while completion is suspended. The typed characters
-- trigger InsertCharPre, so mirroring is suppressed while cmp is suspended, and
-- the change is replayed after confirm_done or menu_closed.
--
-- cmp.core.suspending is a single boolean, but suspensions are nested (e.g.
-- select_next_item suspends, then the entries view suspends again to insert the
-- item) and the outer release can clear it before the inner keys are processed.
-- cmp.core.suspend is wrapped to count nested suspensions instead.

local M = {}

M.name = "cmp"

local unsubscribe = {}

-- Number of unreleased suspensions
local depth = 0

-- The original suspend function, if wrapped
local original_suspend = nil
local wrapped_suspend = nil

-- The original suspend function was set on the cmp.core instance
local original_is_own = false

local function wrap_suspend(cmp, bridge)
  local core = cmp.core

  if original_suspend or type(core.suspend) ~= "function" then
    return
  end

  original_suspend = core.suspend
  original_is_own = rawget(core, "suspend") ~= nil

  wrapped_suspend = function(self, ...)
    depth = depth + 1
    bridge.begin()

    local release = original_suspend(self, ...)
    local released = false

    return function(...)
      local result = release(...)
      if not released then
        released = true
        -- cmp releases with vim.schedule, so decrement after it
        vim.schedule(function()
          depth = math.max(0, depth - 1)
        end)
      end
      return result
    end
  end

  -- Shadow the method on the instance (the original is from the metatable)
  core.suspend = wrapped_suspend
end

local function unwrap_suspend()
  local cmp = package.loaded["cmp"]

  -- Only restore if it hasn't been wrapped again by something else
  if cmp and cmp.core and rawget(cmp.core, "suspend") == wrapped_suspend then
    -- nil restores the method from the metatable
    cmp.core.suspend = original_is_own and original_suspend or nil
  end

  original_suspend = nil
  wrapped_suspend = nil
  depth = 0
end

local function get_cmp()
  local ok, cmp = pcall(require, "cmp")
  if ok then
    return cmp
  end
  return nil
end

-- The internals of nvim-cmp that are used: cmp.core.suspend (wrapped),
-- cmp.core.suspending, cmp.core.prepare and cmp.event:on
local function is_supported(cmp)
  local core = cmp.core
  return type(core) == "table"
    and type(core.suspend) == "function"
    and type(core.prepare) == "function"
    and type(cmp.event) == "table"
    and type(cmp.event.on) == "function"
end

local warned = false

function M.available()
  local cmp = get_cmp()

  if not cmp then
    return false
  end

  if not is_supported(cmp) then
    if not warned then
      warned = true
      vim.notify("multiple-cursors: this version of nvim-cmp isn't supported by the \"cmp\" completion backend, "
        .. "so its completions aren't replayed at the virtual cursors", vim.log.levels.WARN)
    end
    return false
  end

  return true
end

function M.is_writing()
  local cmp = package.loaded["cmp"]
  return depth > 0 or (cmp ~= nil and cmp.core ~= nil and cmp.core.suspending == true)
end

function M.attach(bridge, group)

  local cmp = get_cmp()

  if not cmp then
    return
  end

  wrap_suspend(cmp, bridge)

  -- Suspensions don't span insert mode sessions, so reset in case a release was
  -- never called, which would suppress mirroring characters
  vim.api.nvim_create_autocmd({"InsertLeave"}, {
    group = group,
    callback = function() depth = 0 end,
  })

  -- cmp.event:on returns a function to remove the listener
  -- confirm_done is emitted while cmp is still suspended, bridge.commit waits
  -- until it isn't
  for _, event in ipairs({"confirm_done", "menu_closed"}) do
    table.insert(unsubscribe, cmp.event:on(event, bridge.commit))
  end

  -- If initialised in insert mode, the key maps of this plug-in hide the cmp
  -- key maps until the next InsertEnter, so prepare them again to use this
  -- plug-in's key maps as their fallback
  local mode = vim.api.nvim_get_mode().mode
  if mode == "i" or mode == "ic" or mode == "R" or mode == "Rc" then
    vim.schedule(function()
      pcall(cmp.core.prepare, cmp.core)
    end)
  end

end

function M.detach()
  for _, func in ipairs(unsubscribe) do
    pcall(func)
  end
  unsubscribe = {}
  unwrap_suspend()
end

return M
