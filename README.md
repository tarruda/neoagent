# Neoagent

A hackable LLM and harness toolkit for Neovim.

Neoagent streams conversations, reasoning, tool calls, and provider status in a
floating Markdown UI. It includes coding tools, persistent sessions, multiple
providers, and optional native sandboxing. Its Models, tools, Sessions,
Controllers, Renderers, and Views are ordinary Lua values, so each layer can be
used or replaced on its own.

Requirements: Neovim 0.10+, curl 7.76+, `rg`, and `fd`. ImageMagick's `magick`
is optional and enables image conversion.

## Setup

Choose a model and map a key:

```lua
require("neoagent").setup({
  default_model = {
    provider = "openai",
    model = "gpt-5.4",
  },
})

vim.keymap.set("n", "<leader>a", "<cmd>Neoagent<cr>", {
  desc = "Open Neoagent",
})
```

Authenticate with `:NeoagentLogin provider`, or set the provider's environment
variable before starting Neovim:

| Provider | Login name | Environment variable |
| --- | --- | --- |
| OpenAI API | `openai` | `OPENAI_API_KEY` |
| ChatGPT subscription | `openai-codex` | — |
| Anthropic API | `anthropic` | `ANTHROPIC_API_KEY` |
| Claude subscription | `anthropic-plan` | `ANTHROPIC_OAUTH_TOKEN` |
| DeepSeek | `deepseek` | `DEEPSEEK_API_KEY` |
| Z.AI | `zai` | `ZAI_API_KEY` |
| OpenCode Go | `opencode-go` | `OPENCODE_API_KEY` |
| llama.cpp | `llama` | — |

Stored credentials take precedence over environment variables. Remove one with
`:NeoagentLogout provider`.

Use `:NeoagentModel` to choose another model and `:NeoagentProvider` to open
the active provider's status and operations. The built-in `Neo` Controller is
configured for coding; `Chat` is a tool-free conversation Controller. Switch
between them with `:NeoagentCycle`.

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
sandboxing requires Neovim 0.12+ and one-time elevated setup. The sandbox
implementation was ported from Codex CLI.

See `:help neoagent` for commands, configuration, and the Lua API.
Implementation boundaries are described in [architecture.md](architecture.md).
