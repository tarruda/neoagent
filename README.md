# Neoagent

LLM conversations and coding agents in Neovim, with persistent sessions,
multiple providers, a Markdown UI, and headless Lua APIs.

Requirements: Neovim 0.10+, curl 7.76+, `rg`, and `fd`. Bundled terminal images
use the Kitty graphics protocol.

Command tools support Linux (x86, x64, ARM, ARM64), macOS (x64, ARM64), and
Windows. Run `:checkhealth neoagent` to check dependencies; see
`:help neoagent-subprocess` for PTY requirements.

## Setup

Choose a model and map a key in your Neovim configuration:

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
```

Set `OPENAI_API_KEY` before starting Neovim, or open `:NeoagentProvider` and
choose Log in. See `:help neoagent-built-in-providers` for credentials and
subscription access.

Open `:Neoagent`, enter a prompt, and press Enter to submit. Use
`:NeoagentModel` to change models and `:NeoagentCycle` to switch Agents or
start another conversation.

## Trust and sandboxing

Workspace trust allows project instructions to enter the prompt. Tool effects
are controlled separately by the executor and sandbox.

Native sandboxing is experimental and disabled by default. Enable it with
`sandbox = { enabled = true }` in your setup options.

Use `:NeoagentToggleSandbox` to toggle it and `:NeoagentSandboxInfo` to inspect
support. See `:help neoagent-sandbox` for requirements and policy.

See `:help neoagent` for configuration and APIs, and
[architecture.md](architecture.md) for system boundaries. Optional HTTP
recordings contain private conversation data; read `:help neoagent-recording`
before enabling or sharing them.
