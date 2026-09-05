# Neoagent

LLM conversations and coding agents in Neovim.

Neoagent combines a floating Markdown UI, coding tools, persistent sessions,
and multiple providers. Its Lua APIs also support headless use.

Requirements: Neovim 0.10+, curl 7.76+, `rg`, and `fd`. Bundled terminal images
use the Kitty graphics protocol.

## Setup

Choose a model and map a key:

```lua
require("neoagent").setup({
  default_model = {
    provider = "openai",
    model = "gpt-5.4",
  },
})

vim.keymap.set("n", "<leader>a", "<Plug>(NeoagentToggle)", {
  desc = "Open Neoagent",
})
vim.keymap.set("n", "<leader>A", "<Plug>(NeoagentCycle)", {
  desc = "Select a Neoagent Agent",
})
```

Set `OPENAI_API_KEY` before starting Neovim, or open `:NeoagentProvider` and
choose Log in. Stored credentials take precedence over environment variables.
See `:help neoagent-built-in-providers` for other providers and subscription
access.

Open `:Neoagent`, enter a prompt, and press Enter to submit. Use
`:NeoagentModel` to change models and `:NeoagentCycle` to switch Agents or
start a conversation. Run `:checkhealth neoagent` to check dependencies.

## Trust and sandboxing

Before project instructions and tools are loaded, a prompt asks you to trust
the workspace. Trust allows repository content to influence the agent; tool
effects are controlled separately by the executor and sandbox.

Native sandboxing is experimental and disabled by default. Enable it with
`sandbox = { enabled = true }` in your setup options.

`:NeoagentToggleSandbox` toggles sandboxing for the selected Agent or draft;
`:NeoagentSandboxInfo` shows the active backend. See
`:help neoagent-sandbox` for platform requirements and policy configuration.

See `:help neoagent` for commands, configuration, and the Lua API, including
optional HTTP recording for debugging. Recordings contain conversation data;
read `:help neoagent-recording` before enabling or sharing them.
Implementation boundaries are described in [architecture.md](architecture.md).
