# Neoagent

A small, hackable LLM and coding-agent toolkit for Neovim.

![](assets/inspect-project.gif)

![](assets/edit-code.gif)

![](assets/local-chat.gif)

## Features

- Stream assistant responses, reasoning, tool calls, usage, and provider status
  directly in Neovim.
- Use Anthropic Messages, OpenAI-compatible Chat Completions and Responses,
  local models with llama.cpp, built-in Anthropic, DeepSeek, and Z.AI
  catalogs, or Claude and ChatGPT subscription authentication.
- Compose Models, tools, executors, Sessions, Controllers, Renderers, and
  Views as ordinary Lua values with explicit dependencies.
- Run cancellable agent loops with custom tools, steering messages, retry
  handling, and context compaction.
- Use bundled coding tools for file operations, shell commands, and on-demand
  Neoagent documentation.
- Experimental sandboxed tools (disabled by default).
- Persist conversations with branches, linked forks, labels, model state, and
  context compaction.
- Work from a floating Markdown UI with separate transcript and input windows.
- Use bundled Pi and Codex Renderers or inject a custom presentation for the
  bundled View.
- Start with **Neo** for coding tasks and **Chat** for tool-free conversation.
- See `:help neoagent` for the complete configuration and API reference.

## Quick configuration

Choose a provider:

- Run `:NeoagentLogin openai` to store an OpenAI API key, or set
  `OPENAI_API_KEY` before starting Neovim.
- Run `:NeoagentLogin anthropic` to store an Anthropic API key, or set
  `ANTHROPIC_API_KEY` before starting Neovim.
- For Claude Pro or Max authentication, run `:NeoagentLogin anthropic-plan`,
  or provide an existing `ANTHROPIC_OAUTH_TOKEN`.
- Run `:NeoagentLogin deepseek` to store a DeepSeek API key, or set
  `DEEPSEEK_API_KEY` before starting Neovim.
- Run `:NeoagentLogin zai` to store a Z.AI API key, or set `ZAI_API_KEY`
  before starting Neovim. The credential enables both the metered API and
  global Coding Plan catalogs.
- For a ChatGPT Plus or Pro subscription, run
  `:NeoagentLogin openai-codex`, complete the browser or device-code login,
  then select a subscription model with `:NeoagentModel`.

API keys are entered through a masked prompt. A stored credential takes
precedence over its environment variable. `:NeoagentLogout [method]` removes
the stored credential and leaves environment variables unchanged. Anthropic
currently bills third-party Claude subscription OAuth requests as extra usage
per token; they do not consume included Claude plan limits.

Configure an OpenAI model and a mapping:

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

For Anthropic API-key billing, use `anthropic`; use `anthropic-plan` with
Claude Pro/Max OAuth:

```lua
default_model = {
  provider = "anthropic",
  model = "claude-sonnet-4-6",
}
```

Set `provider = "anthropic-plan"` in the same value for Claude Pro/Max OAuth.

To use DeepSeek by default, replace `default_model` with:

```lua
default_model = {
  provider = "deepseek",
  model = "deepseek-v4-flash",
}
```

For Z.AI, use `zai` for the metered API or `zai-coding-plan` for the global
Coding Plan:

```lua
default_model = {
  provider = "zai-coding-plan",
  model = "glm-5.2",
}
```

## Workspace trust

The built-in **Neo** composition asks for explicit workspace trust before it
loads project instructions or starts a tool-capable agent. Review the canonical
workspace path and effective sandbox status, then choose persistent trust,
trust until Neovim exits, or cancel. **Chat** and direct Lua compositions keep
their explicit caller-defined policy; custom Controllers can compose the same
trust policy through `workspace_trust.compose()` and `neoagent.new()` runtime
injection. Workspace trust does not make repository content, commands, or model
output safe; native sandboxing and executor policy control runtime effects. See
`:help neoagent-workspace-trust` for complete behavior and configuration.

## OS-enforced sandbox

Codex ported sandboxing is experimental and disabled by default. The setup flag
selects its initial editor state:

```lua
sandbox = {
  enabled = true,
}
```

Use `:NeoagentToggleSandbox` to switch the built-in Neo executor between host
and sandbox execution and `:NeoagentSandboxInfo` to inspect the active backend,
isolation level, and capabilities. Runtime changes are editor-local, preserve
the advertised tools, and can occur while Neo is working.

Linux and Windows use a bundled LuaJIT FFI runtime to invoke native isolation
APIs; macOS uses `/usr/bin/sandbox-exec`. The sandbox mediates bundled-tool
file and process operations. Custom tool Lua runs in Neovim and must use the
injected capabilities to participate.

Neoagent sandbox behavior follows Codex's bundled-tool sandboxing model, with
platform-specific implementation notes:

- Linux performs namespace setup and seccomp filtering directly in the bundled
  LuaJIT FFI runtime, without a bubblewrap dependency.
- Windows drains pipe output from the runner loop with `PeekNamedPipe`,
  `WaitForSingleObject`, and bounded sleeps, while Codex uses blocking
  `ReadFile` readers on separate Rust threads.
- macOS follows Codex's backend shape by compiling a Seatbelt profile and
  executing it through `/usr/bin/sandbox-exec`.

See `:help neoagent-sandbox` for configuration and platform details. Windows
sandboxing requires Neovim 0.12+ and an elevated one-time setup command before
it is enabled.
