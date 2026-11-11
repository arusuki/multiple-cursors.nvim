-- In-process language server for tests
--
-- opts.items(line, character): completion items for a position (0-based)
-- opts.resolve_delay: if set, the server supports completionItem/resolve and
--   responds after this many milliseconds (like servers that resolve lazily)

return function(opts)
  return function(dispatchers)
    local closing = false
    local next_id = 0

    return {
      -- notify_reply_callback must be called when responding, so that the
      -- client stops tracking the request as pending (like vim.lsp.rpc)
      request = function(method, params, callback, notify_reply_callback)
        next_id = next_id + 1
        local id = next_id

        local function respond(err, res)
          if notify_reply_callback then notify_reply_callback(id) end
          callback(err, res)
        end

        if method == "initialize" then
          respond(nil, { capabilities = {
            completionProvider = { resolveProvider = opts.resolve_delay ~= nil },
          } })
        elseif method == "textDocument/completion" then
          respond(nil, {
            isIncomplete = false,
            items = opts.items(params.position.line, params.position.character),
          })
        elseif method == "completionItem/resolve" then
          vim.defer_fn(function() respond(nil, params) end, opts.resolve_delay or 0)
        else
          respond(nil, nil)
        end

        return true, id
      end,
      notify = function(method)
        if method == "exit" then closing = true end
        return true
      end,
      is_closing = function() return closing end,
      terminate = function() closing = true end,
    }
  end
end
