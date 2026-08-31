local M = {}

-- Neovim resolves an Insert or Replace mapping after its Lua callback returns.
-- The active context carries that editing intent and the final focused policy
-- across every Applet reached synchronously by the callback.
local mapping_stack = {}
local transition_generation = 0

local function native_mode(value)
  return value or vim.api.nvim_get_mode().mode
end

function M.is_editing(value)
  value = native_mode(value)
  local current = value:sub(1, 1)
  return current == "i" or current == "R" or value:sub(1, 2) == "ni"
end

function M.semantic(value)
  return M.is_editing(value) and "insert" or "normal"
end

local function stop_editing(generation)
  pcall(vim.cmd, "stopinsert")
  if M.is_editing() then
    -- Direct API focus can expose active editing until Neovim returns to its
    -- input loop. Only the newest transition may complete it there.
    vim.schedule(function()
      if transition_generation == generation and M.is_editing() then
        pcall(vim.api.nvim_feedkeys, vim.keycode("<Esc>"), "nx", false)
      end
    end)
  end
end

local function transition(policy)
  transition_generation = transition_generation + 1
  local generation = transition_generation
  local current = native_mode()
  local editing = M.is_editing(current)
  if policy == "insert" and current:sub(1, 1) == "n" and not editing then
    pcall(vim.cmd, "startinsert!")
  elseif policy == "normal" and editing then
    stop_editing(generation)
  end
end

function M.apply(policy)
  assert(policy == "normal" or policy == "insert",
    "Applet mode policy must be normal or insert")
  local mapping = mapping_stack[#mapping_stack]
  if mapping then
    mapping.editing = mapping.editing or M.is_editing()
    mapping.policy = policy
    if mapping.editing then return true end
  end
  transition(policy)
  return true
end

function M.with_mapping(binding_mode, callback)
  local mapping = {
    editing = binding_mode:sub(1, 1) == "i" or M.is_editing(),
  }
  mapping_stack[#mapping_stack + 1] = mapping
  local results = { xpcall(callback, debug.traceback) }
  assert(mapping_stack[#mapping_stack] == mapping,
    "Applet mode mapping stack is inconsistent")
  mapping_stack[#mapping_stack] = nil
  if mapping.editing and mapping.policy == "normal" then
    transition("normal")
  end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2)
end

return M
