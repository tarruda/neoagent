# Neoagent

A hackable LLM and coding-agent toolkit for Neovim.

Neoagent streams conversations, reasoning, tool calls, and provider status in a
floating Markdown UI. It includes coding tools, persistent sessions, multiple
providers, optional native sandboxing, and Lua APIs for headless composition.

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

Open the Provider Shell with `:NeoagentProvider`, select a provider, and choose
Log in. You can also set the provider's environment variable before starting
Neovim:

| Provider | Provider ID | Environment variable |
| --- | --- | --- |
| OpenAI API | `openai` | `OPENAI_API_KEY` |
| ChatGPT subscription | `openai-codex` | — |
| Anthropic API | `anthropic` | `ANTHROPIC_API_KEY` |
| DeepSeek | `deepseek` | `DEEPSEEK_API_KEY` |
| Alibaba Cloud Token Plan Personal | `alibaba-token-plan` | `BAILIAN_TOKEN_PLAN_API_KEY` |
| Z.AI API | `zai` | `ZAI_API_KEY` |
| Z.AI Plan | `zai-coding-plan` | `ZAI_API_KEY` |
| OpenCode Go | `opencode-go` | `OPENCODE_API_KEY` |
| llama.cpp | `llama.cpp` | — |

Stored credentials take precedence over environment variables. Logged-out
authentication methods expose their login actions, and each stored credential
exposes its own confirmed logout action. Environment and configured inference
credentials remain managed at their source.

Use `:NeoagentModel` to choose another model. The Provider Shell exposes each
provider's status, authentication, operations, and model catalog. Providers
with dynamic catalogs offer a refresh action. Use `:NeoagentCycle` to switch
between live Agents or start a new conversation.

Provider HTTP recording is available for debugging:

```lua
require("neoagent").setup({
  recording = { enabled = true },
})
```

Recordings preserve conversation and provider bodies. Treat them as sensitive.
See `:help neoagent-recording` for storage, format, retention, and redaction.

## Trust and sandboxing

Before project instructions and tools are loaded, a prompt asks you to trust
the workspace. Trust allows repository content to influence the agent; tool
effects are controlled separately by the executor and sandbox.

Native sandboxing was ported from Codex. It is currently experimental and
disabled by default. To enable:

```lua
require("neoagent").setup({
  sandbox = { enabled = true },
})
```

`:NeoagentToggleSandbox` changes the built-in executor for the current
editor, and `:NeoagentSandboxInfo` shows the active backend. See
`:help neoagent-sandbox` for platform requirements and policy configuration.

See `:help neoagent` for commands, configuration, and the Lua API.
Implementation boundaries are described in [architecture.md](architecture.md).
