# Neoagent

A small, hackable LLM and coding-agent toolkit for Neovim.

![](assets/inspect-project.gif)

![](assets/edit-code.gif)

![](assets/local-chat.gif)

## Features

- Stream assistant responses, reasoning, tool calls, usage, and provider status directly in Neovim.
- Use Anthropic Messages, OpenAI-compatible Chat Completions and Responses,
  local models such as llama.cpp, built-in DeepSeek and Z.AI catalogs, or ChatGPT
  subscription authentication through OpenAI Codex.
- Compose Models, tools, executors, Sessions, Controllers, and Views as ordinary Lua values with explicit dependencies.
- Run cancellable agent loops with custom tools, steering messages, retry handling, and context compaction.
- Use the bundled coding tools for reading, writing, editing, shell commands, and on-demand Neoagent documentation.
- Persist conversations as Pi v3 JSONL trees with branches, linked forks, labels, model state, and compaction checkpoints.
- Work from a floating Markdown UI with separate transcript and input windows.
- Start with two bundled Controllers: **Neo** for coding tasks and **Chat** for tool-free conversation.
- See `:help neoagent` for the complete configuration and API reference.

## Quick configuration

Choose a provider:

- Run `:NeoagentLogin openai` to store an OpenAI API key, or set
  `OPENAI_API_KEY` before starting Neovim.
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
the stored credential and leaves environment variables unchanged.

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
