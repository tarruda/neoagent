# Neoagent

A small, hackable LLM and coding-agent toolkit for Neovim.

![](assets/local-chat.gif)

![](assets/inspect-project.gif)

![](assets/edit-code.gif)

## Features

- Stream assistant responses, reasoning, tool calls, usage, and provider status directly in Neovim.
- Use OpenAI-compatible Chat Completions and Responses APIs, local models such as llama.cpp, the built-in DeepSeek catalog, or ChatGPT subscription authentication through OpenAI Codex.
- Compose Models, tools, executors, Sessions, Controllers, and Views as ordinary Lua values with explicit dependencies.
- Run cancellable agent loops with custom tools, steering messages, retry handling, and context compaction.
- Use the bundled coding tools for reading, writing, editing, shell commands, and on-demand Neoagent documentation.
- Persist conversations as Pi v3 JSONL trees with branches, linked forks, labels, model state, and compaction checkpoints.
- Work from a floating Markdown UI with separate transcript and input windows, model and thinking selection, input history, filename completion, and multiple independent Controllers.
- Start with two bundled Controllers: **Neo** for coding tasks and **Chat** for tool-free conversation.
- Extend execution policy with a custom `execute_tool` function for confirmation, logging, or sandbox delegation.
- Run without Lua plugin dependencies. Neoagent requires Neovim 0.10+, curl 7.76+, `rg`, and `fd`; ImageMagick is optional.
- See `:help neoagent` for the complete configuration and API reference.

## Quick configuration

Choose a provider:

- Set `OPENAI_API_KEY` before starting Neovim to use the built-in OpenAI models.
- Set `DEEPSEEK_API_KEY` before starting Neovim to use `deepseek/deepseek-v4-flash` or `deepseek/deepseek-v4-pro`.
- For a ChatGPT Plus or Pro subscription, run `:NeoagentLogin openai-codex`, complete the browser or device-code login, then select a subscription model with `:NeoagentModel`.

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
