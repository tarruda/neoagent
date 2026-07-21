# Neoagent

Neoagent is a small, hackable LLM and agent toolkit for Neovim. Its reusable
core provides streamed models, cancellable runs, and a tool loop. Sessions,
workspace-aware tools, persistence, and the floating chat UI are ordinary
layers built on that core and can be replaced independently.

V1 targets OpenAI-compatible chat completions APIs, particularly llama.cpp.
Requests use `curl`; the UI uses only Neovim buffers, windows, mappings,
extmarks, and autocommands.

## Requirements

- Neovim 0.10 or newer
- curl 7.76 or newer
- `rg` and `fd` for the bundled search tools
- optional `magick` for image orientation and resizing

Run `:checkhealth neoagent` after installation.

## Setup

Install this directory with your plugin manager, then configure a provider and
model. Neoagent installs no global mapping.

```lua
require("neoagent").setup({
  providers = {
    local_llama = {
      api = "openai-completions",
      base_url = "http://127.0.0.1:8080/v1",
      models = {
        ["qwen3-coder"] = {
          max_output_tokens = 8192,
        },
      },
    },
  },
  default_model = { provider = "local_llama", model = "qwen3-coder" },
})

vim.keymap.set("n", "<leader>a", "<cmd>Neoagent<cr>")
```

`:Neoagent` opens two focusable floating windows. The input starts in Insert
mode and remains an ordinary editable buffer. The transcript is an ordinary
read-only buffer, so search, Visual selection, and yank work normally.

Default UI mappings:

| Mapping | Action |
| --- | --- |
| `<C-s>` | Send from input, in Normal or Insert mode |
| `<C-c>` | Clear the current draft and return to Insert mode |
| `<C-w>w` | Move directly between input and transcript |
| `<C-w>H/J/K/L` | Dock left, bottom, top, or right |
| `<C-w>=` | Center the UI |
| `q` | Hide the UI while the transcript is focused |

Commands are `:Neoagent`, `:NeoagentNew`, `:NeoagentResume [path]`,
`:NeoagentStop`, and `:NeoagentModel provider/model`.

## Configuration

The complete shape is intentionally small:

```lua
require("neoagent").setup({
  providers = {},
  apis = {},
  default_model = nil,
  system_prompt = nil,          -- string or function(context) -> string
  tools = nil,                  -- nil selects the coding preset
  execute_tool = nil,           -- function(tool, arguments, ctx)
  interaction = nil,            -- replace the default chat.run composition
  max_tool_rounds = 12,
  persistence = {
    enabled = true,
    directory = vim.fn.stdpath("state") .. "/neoagent/sessions",
  },
  ui = {
    position = "auto",          -- auto, left, right, top, bottom, center
    width = nil,                 -- fraction or absolute columns
    height = nil,                -- fraction or absolute rows
    margin = 1,
    input_height = 5,
    border = "rounded",
    mappings = {},               -- recursively merged with the defaults
  },
})
```

Set a mapping to `false` to disable it. With `position = "auto"`, Neoagent
prefers floating over a non-focused ordinary window so the source stays
visible; with one editor window it docks right.

### Request options

A provider, a model, and an individual `Model:stream()` call may each supply
`request_opts`. Each value is either a table or a function returning a table:

```lua
providers = {
  local_llama = {
    api = "openai-completions",
    base_url = "http://127.0.0.1:8080/v1",
    request_opts = {
      headers = { ["X-Client"] = "neovim" },
      body = { temperature = 0.2, extra_body = { chat_template_kwargs = { enable_thinking = true } } },
    },
    models = {
      coder = {
        request_opts = function(ctx)
          return { body = { extra_body = { request_id = tostring(vim.uv.hrtime()) } } }
        end,
      },
    },
  },
}
```

The merge order is provider, model, then call. `body` and `headers` merge
recursively; lists replace lists, and header keys are case-insensitive. A
callback receives `model`, `messages`, `system_prompt`, `tools`, and a snapshot
of the request produced by earlier layers. It must return only `url`,
`headers`, and/or `body`.

## Use the core without the UI

Constructing a model does not require `setup()`, a Session, tools, or a
Workspace:

```lua
local Model = require("neoagent.api.openai_completions")

local model = Model.new({
  provider = "local",
  model = "qwen3-coder",
  base_url = "http://127.0.0.1:8080/v1",
})

local run = model:stream({
  messages = { { role = "user", content = "Explain this function." } },
  request_opts = { body = { temperature = 0 } },
  on_event = function(event)
    if event.type == "text_delta" then
      vim.api.nvim_echo({ { event.text } }, false, {})
    end
  end,
  on_done = function(result)
    if not result.ok then vim.notify(result.error.message, vim.log.levels.ERROR) end
  end,
})

-- run:cancel(), run:is_done(), run:is_cancelled(), run:result()
```

Callbacks are scheduled onto Neovim's main loop. Completion is exactly once.
The normalized stream events are `text_delta`, `thinking_delta`,
`tool_call_delta`, and `usage`.

Use the tool loop by passing the model, messages, and exact tool values:

```lua
local run = require("neoagent.agent").run({
  model = model,
  messages = messages,
  tools = my_tools,             -- may be empty
  execute_tool = my_executor,   -- optional boundary/decorator
  context = my_context,
  on_event = on_event,
  on_done = on_done,
})
```

`agent.run()` does not mutate `messages`, resolve global configuration, or
invent tools. It executes calls sequentially and returns generated messages in
`result.new_messages`.

## Tools and execution policy

A tool is a plain Lua value:

```lua
local tool = {
  name = "word_count",
  description = "Count words in text",
  input_schema = {
    type = "object",
    properties = { text = { type = "string" } },
    required = { "text" },
    additionalProperties = false,
  },
  execute = function(arguments, ctx)
    local count = #vim.split(arguments.text, "%s+", { trimempty = true })
    return { content = { { type = "text", text = tostring(count) } } }
  end,
}
```

The default coding preset is exactly `read_file`, `write_file`, `edit_file`,
and `shell`. `require("neoagent.tools").read_only()` returns exactly
`read_file`, `grep`, and `find`. All file tools operate on disk. They never use
loaded buffers; the default controller merely asks Neovim to reload a matching
unmodified buffer after a successful write or edit.

Policy belongs at the executor boundary. For example, a third-party plugin can
wrap execution with an approval UI or call a native sandbox binary, then invoke
`tool.execute(arguments, ctx)` only after the policy allows it. Async wrappers
can suspend with `require("neoagent.async").await(start)`; cancellation invokes
the cleanup function returned by `start`.

## Sessions and higher-level composition

`require("neoagent.session").new()` creates only an in-memory message owner. It
has no model, tools, Workspace, or harness. Pass an injected store if desired.
`neoagent.storage` implements the default Pi-compatible v3 JSONL subset.
Storage is namespaced by the SHA-256 of the Session's creation cwd, and no file
is created until the first message is accepted.

`neoagent.chat.send(session, prompt, opts)` adds one model response.
`neoagent.chat.run(session, prompt, opts)` runs the tool loop and appends every
generated message. These adapters permit one active mutation per Session;
independent Models, agent runs, and Sessions remain concurrent.

A buffer-transform plugin can stay much simpler: call `model:stream()`, append
`text_delta` values into a replacement buffer or scratch buffer, and apply
`result.text` as the authoritative final contents. It does not need a Session,
agent, tools, Workspace, or the bundled UI.

See `:help neoagent` and [design.md](design.md) for contracts and rationale.

## Development

The runtime has no Lua dependencies. Tests use pinned Plenary and LuaCov
checkouts. Machine-specific overrides can go in the gitignored `local.mk`:

```sh
cp local.mk.example local.mk
```

Then adjust its values if needed:

```make
NVIM := /path/to/nvim
PLENARY_DIR := /path/to/plenary.nvim
export PATH := /path/to/extra/bin:$(PATH)
```

Portable defaults need no local configuration:

```sh
make deps
make test
make coverage
```

The coverage target fails unless every shipped Lua file is present in the
report and aggregate line coverage is strictly greater than 90%.
