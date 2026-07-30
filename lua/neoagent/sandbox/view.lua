local M = {}

local function default_factory(opts)
  return require("neoagent.ui").new(opts)
end

function M.warn_once(factory, message, controller_name)
  assert(factory == nil or type(factory) == "function",
    "sandbox warning View factory must be a function")
  assert(type(message) == "string" and message ~= "",
    "sandbox warning message is required")
  factory = factory or default_factory
  local pending = true
  return function(opts)
    local view = factory(opts)
    assert(type(view) == "table" and type(view.open) == "function",
      "sandbox warning View must implement open")
    local open = view.open
    local selected
    local set_context = view.set_context
    if type(set_context) == "function" then
      view.set_context = function(self, context, ...)
        if type(context) == "table" then selected = context.name end
        local result = { set_context(self, context, ...) }
        if pending and controller_name ~= nil
            and selected == controller_name
            and type(self.is_open) == "function" and self:is_open() then
          pending = false
          vim.notify(message, vim.log.levels.WARN)
        end
        return unpack(result)
      end
    end
    view.open = function(self, ...)
      local result = { open(self, ...) }
      if result[1] and pending
          and (controller_name == nil or selected == controller_name) then
        pending = false
        vim.notify(message, vim.log.levels.WARN)
      end
      return unpack(result)
    end
    return view
  end
end

return M
