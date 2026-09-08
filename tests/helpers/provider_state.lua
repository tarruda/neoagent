local M = {}

---@overload fun(snapshot: Neoagent.ProviderState|false, kind: "status", label?: string): Neoagent.ProviderStatusBlock?
---@overload fun(snapshot: Neoagent.ProviderState|false, kind: "field", label?: string): Neoagent.ProviderFieldBlock?
---@overload fun(snapshot: Neoagent.ProviderState|false, kind: "progress", label?: string): Neoagent.ProviderProgressBlock?
---@overload fun(snapshot: Neoagent.ProviderState|false, kind: "limit", label?: string): Neoagent.ProviderLimitBlock?
---@overload fun(snapshot: Neoagent.ProviderState|false, kind: "list", label?: string): Neoagent.ProviderListBlock?
---@overload fun(snapshot: Neoagent.ProviderState|false, kind: "activity", label?: string): Neoagent.ProviderActivityBlock?
---@param snapshot Neoagent.ProviderState|false
---@param kind string
---@param label? string
---@return Neoagent.ProviderBlock?
function M.block(snapshot, kind, label)
  assert(snapshot)
  for _, candidate in ipairs(snapshot.blocks) do
    if candidate.type == kind and (label == nil
        or rawget(candidate, "label") == label
        or rawget(candidate, "title") == label) then
      return candidate
    end
  end
end

return M
