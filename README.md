# Neoagent

A hackable LLM and harness toolkit for Neovim.

Neoagent streams conversations, reasoning, tool calls, and provider status in a
floating Markdown UI. It includes coding tools, persistent sessions, multiple
providers, and optional native sandboxing. Its Models, tools, Sessions,
Agents, Profiles, Applets, Renderers, and Views are ordinary Lua
values, so each layer can be used or replaced on its own.

Requirements: Neovim 0.10+, curl 7.76+, `rg`, and `fd`. Terminal images use
the Kitty graphics protocol.

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
| Z.AI API | `zai` | `ZAI_API_KEY` |
| Z.AI Plan | `zai-coding-plan` | `ZAI_API_KEY` |
| OpenCode Go | `opencode-go` | `OPENCODE_API_KEY` |
| llama.cpp | `llama.cpp` | — |

Claude Pro/Max access uses Anthropic's Claude Code product. Anthropic publishes
no third-party subscription API or OAuth client contract, so Neoagent's
`anthropic` provider uses the supported metered Messages API.

Stored credentials take precedence over environment variables. The Provider
Shell shows Log out for a stored credential; configured and environment
credentials remain managed at their source. Both Z.AI provider IDs use the same
stored API key.

Use `:NeoagentModel` to choose another model. The Provider Shell exposes each
provider's status, authentication, operations, and model-catalog refresh.
Use `:NeoagentCycle` to switch between live Agents or start a Neo coding or
Chat conversation.

Provider HTTP recording is opt-in and intended for debugging:

```lua
require("neoagent").setup({
  recording = { enabled = true },
})
```

It writes one credential-scrubbed, Session-linked exchange file per request
under `stdpath("state") .. "/neoagent/workspaces/recordings"`. Compatible `yq`
v4 selects readable YAML automatically; JSON Lines is used when `yq` is absent.
Model request and ordinary provider response bodies are retained exactly, so
recordings contain private conversation content. See `:help neoagent-recording`
for format, privacy, and path configuration.

## Trust and sandboxing

Before Neo loads project instructions or uses tools, it asks you to trust the
workspace. Trust allows repository content to influence the agent; tool effects
are controlled separately by the executor and sandbox.

Native sandboxing is experimental and disabled by default:

```lua
require("neoagent").setup({
  sandbox = { enabled = true },
})
```

`:NeoagentToggleSandbox` changes the built-in Neo executor for the current
editor, and `:NeoagentSandboxInfo` shows the active backend. Linux and Windows
use bundled native runtimes; macOS uses `/usr/bin/sandbox-exec`. Windows
sandboxing requires Neovim 0.12+ and one-time elevated setup.

See `:help neoagent` for commands, configuration, and the Lua API.
Implementation boundaries are described in [architecture.md](architecture.md).
