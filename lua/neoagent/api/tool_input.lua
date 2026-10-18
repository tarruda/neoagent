local util = require("neoagent.util")

local M = {}

---@param tool Neoagent.ToolDefinition
function M.validate(tool)
  local input = tool.text_input
  if input == nil then
    return
  end
  assert(type(input) == "table" and not util.is_list(input), "text_input must be an object")
  for key in pairs(input) do
    assert(key == "parameter" or key == "grammar", "unsupported text_input field: " .. tostring(key))
  end
  assert(
    type(input.parameter) == "string" and input.parameter:match("^[%a_][%w_]*$"),
    "text_input.parameter must be a parameter name"
  )
  assert(
    input.grammar == nil
      or type(input.grammar) == "string" and input.grammar ~= "" and util.is_valid_utf8(input.grammar),
    "text_input.grammar must be non-empty UTF-8 Lark grammar"
  )
  local schema = tool.input_schema
  local required = schema.required or {}
  local properties = schema.properties or {}
  local parameter = properties[input.parameter]
  assert(
    schema.type == "object" and parameter and parameter.type == "string",
    "text_input requires a string parameter in an object schema"
  )
  assert(
    schema.additionalProperties == false and #required == 1 and required[1] == input.parameter,
    "text_input requires exactly one required parameter"
  )
  for name in pairs(properties) do
    assert(name == input.parameter, "text_input cannot encode additional parameters")
  end
end

return M
