local M = {}

function M.envelope(env)
  env = env or vim.env
  local term = type(env.TERM) == "string" and env.TERM or ""
  if term:match("^tmux") or env.TMUX and env.TMUX ~= "" then return "tmux" end
  return nil
end

function M.eligible(uis)
  uis = uis or vim.api.nvim_list_uis()
  return #uis == 1 and type(uis[1]) == "table"
    and type(uis[1].chan) == "number"
end

function M.diagnostics(opts)
  opts = opts or {}
  if M.envelope(opts.env) ~= "tmux" then return {} end
  local is_executable = opts.executable or vim.fn.executable
  if is_executable("tmux") ~= 1 then
    return { {
      level = "error",
      message = "tmux is required but was not found",
    } }
  end
  local output, status
  if opts.system then
    output, status = opts.system({
      "tmux", "show-options", "-gv", "allow-passthrough",
    })
  else
    output = vim.fn.system({
      "tmux", "show-options", "-gv", "allow-passthrough",
    })
    status = vim.v.shell_error
  end
  if status == 0 and vim.trim(output or "") == "all" then
    return { {
      level = "ok",
      message = "tmux passes terminal graphics through every pane",
    } }
  end
  return { {
    level = "warn",
    message = "tmux terminal images require: set -g allow-passthrough all",
  } }
end

return M
