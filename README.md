# Neoagent

Neoagent is a small, hackable LLM and agent toolkit for Neovim. Its reusable
core provides streamed models, cancellable runs, and a tool loop. Sessions,
workspace-aware tools, persistence, and the floating chat UI are ordinary
layers built on that core and can be replaced independently.

Neoagent supports OpenAI-compatible Chat Completions and stateless Responses
APIs, including llama.cpp, plus ChatGPT subscription authentication for the
OpenAI Codex Responses endpoint. Requests use `curl`; the UI uses only Neovim
buffers, windows, mappings, extmarks, and autocommands.

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

Use `openai-responses` for a Responses-compatible endpoint. A model can expose
thinking levels as ordinary request-option layers. Opaque response item
signatures are retained in assistant messages so complete history can be
replayed with `store = false`:

```lua
providers = {
  local_llama = {
    api = "openai-responses",
    base_url = "http://127.0.0.1:8080/v1",
    models = {
      coder = {
        max_output_tokens = 8192,
        thinking = {
          off = {},
          low = { body = { reasoning = { effort = "low", summary = "auto" } } },
          high = { body = { reasoning = { effort = "high", summary = "auto" } } },
        },
      },
    },
  },
}
```

Neoagent includes Pi's explicit OpenAI model catalog. Set `OPENAI_API_KEY`
before starting Neovim and the `openai/*` entries become available in
`:NeoagentModel`. To select one automatically:

```lua
require("neoagent").setup({
  default_model = { provider = "openai", model = "gpt-5.4" },
})
```

The built-in Codex catalog becomes available after a successful ChatGPT
Plus/Pro login:

```vim
:NeoagentLogin openai-codex
:NeoagentModel
```

Choose browser or headless device-code login. Without an argument,
`:NeoagentLogin` selects from every configured login method through
`vim.ui.select`; `:NeoagentLogin!` cancels an active login. The explicit model
catalog mirrors Pi and may change as the service changes.

OAuth credentials are saved to
`stdpath("state") .. "/neoagent/auth.json"`. Neoagent writes the file atomically
with mode `0600`; credential directories it creates use mode `0700`. An expired
access token is refreshed before a Model request. The credential file is
independent from session persistence and should never be committed or shared.

`:Neoagent` opens two focusable floating windows. The input starts in Insert
mode and remains an ordinary editable buffer. The transcript is an ordinary
read-only buffer, so search, Visual selection, and yank work normally.

The transcript renders assistant Markdown with headings, inline emphasis,
links, lists, quotes, fenced code, rules, and tables. Thinking is muted and
italic. User messages and tool calls use separate padded backgrounds; pending
tools change to green on success or red on failure. Built-in tools show concise
arguments and useful output instead of JSON. Read output is limited to ten
lines until tool output is expanded. A spinner remains visible while the agent
is working.

Default UI mappings:

| Mapping | Action |
| --- | --- |
| `<C-s>` | Send from input, in Normal or Insert mode |
| `<C-c>` | Clear the current draft and return to Insert mode |
| `<C-w>w` | Move directly between input and transcript |
| `<C-o>` | Expand or collapse tool output |
| `<S-Tab>` | Cycle through the current model's thinking levels |
| `<C-w>H/J/K/L` | Dock left, bottom, top, or right |
| `<C-w>=` | Center the UI |
| `q` | Hide the UI while the transcript is focused |

Commands are `:Neoagent`, `:NeoagentNew`, `:NeoagentResume [path]`,
`:NeoagentStop`, `:NeoagentModel [provider/model]`,
`:NeoagentThinking [level]`, and
`:NeoagentLogin [method]`. Without an argument, the resume, model, and login
commands use `vim.ui.select`, so UI providers such as Telescope's `ui-select`
extension enhance all three pickers automatically.
Selecting or directly specifying an entry also opens the agent UI when it is
closed. Resume entries include a preview of the first user message.

```lua
require("telescope").load_extension("ui-select")
```

## Configuration

The complete shape is intentionally small:

```lua
require("neoagent").setup({
  default_registry = true,      -- compose the built-in OpenAI catalogs
  providers = {},
  apis = {},
  auth = {
    path = vim.fn.stdpath("state") .. "/neoagent/auth.json",
    methods = {},                -- recursively merged with built-in methods
  },
  default_model = nil,
  default_thinking_level = "medium",
  system_prompt = nil,          -- nil uses the built-in coding prompt
  tools = nil,                  -- nil selects the coding preset
  execute_tool = nil,           -- function(tool, arguments, ctx)
  interaction = nil,            -- replace the default chat.run composition
  max_tool_rounds = 12,
  agents = {
    global_files = { vim.fn.stdpath("config") .. "/AGENTS.md" },
    project_filenames = { "AGENTS.md" },
  },
  skills = {
    global_dirs = {
      vim.fn.expand("~/.agents/skills"),
      vim.fn.stdpath("config") .. "/neoagent/skills",
    },
    project_dirs = { ".agents/skills" },
  },
  persistence = {
    enabled = true,             -- false disables bundled sessions and settings
    workspace_settings = true,  -- merge cwd-scoped model/thinking overrides
    directory = vim.fn.stdpath("state") .. "/neoagent/workspaces",
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

### Model registry

The final registry is the composition of Neoagent's defaults and the user
`providers` table. The built-in `openai` provider is available when
`OPENAI_API_KEY` resolves to a non-empty value. The built-in `openai-codex`
provider is available when an `openai-codex` OAuth credential is stored.
Providers without `auth` or `api_key`, such as local llama.cpp providers, are
always available.

User provider and model tables recursively override or extend matching
defaults. Set a provider or model to `false` to remove it:

```lua
require("neoagent").setup({
  providers = {
    openai = {
      api_key = function() return vim.env.MY_OPENAI_API_KEY end,
      models = {
        ["gpt-5.4"] = {
          thinking = {
            minimal = false,
            high = { body = { reasoning = { effort = "high" } } },
          },
        },
        ["gpt-4"] = false,
      },
    },
    ["openai-codex"] = false,
  },
})
```

Set `default_registry = false` to remove the complete built-in registry and
use only `providers` from `init.lua`. The unmodified catalog is available from
`require("neoagent.registry").defaults()`. The final composed table is
`require("neoagent.config").get().providers`, while
`require("neoagent.models").available()` returns the currently authenticated
`provider/model` choices.

### Thinking levels

Models opt into thinking controls with a `thinking` table. Keys use the fixed
order `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. Each value
is an ordinary `request_opts` table or callback. Missing keys are unsupported;
`false` removes an inherited built-in level. The selected layer merges after
provider and model request options and before the request is sent.

`default_thinking_level` is clamped to the closest level supported by the
selected model. Use `:NeoagentThinking [level]`,
`require("neoagent").set_thinking_level(level)`, or
`require("neoagent").cycle_thinking_level()`. The default UI displays the
effective level in its title and maps `<S-Tab>` in both windows. A change is
rejected while an interaction is active so every agent run uses one level.

The core agent remains unaware of thinking. Resolved Models expose their
`thinking` table, and the default controller passes the selected layer through
`model_options.request_opts`. Direct callers may do the same explicitly.

### Workspace settings

With persistence enabled, `:NeoagentModel` and `:NeoagentThinking` save their
selection for the active Workspace. The setup values remain the base; overrides
from `workspaces/<sha256-of-canonical-root>/settings.json` merge recursively on
top. A resumed session's last Pi `model_change` and `thinking_level_change`
entries take precedence for that session. Set `persistence.workspace_settings`
to `false` to keep `init.lua` authoritative while retaining session
persistence.

Reading settings or opening an empty Session creates nothing. Selecting a model
or thinking level creates `settings.json` atomically; the session JSONL still
does not exist until its first accepted message. The built-in controller only
owns `default_model` and `default_thinking_level`, but the workspace settings
layer is reusable by other Lua workflows:

```lua
local settings = require("neoagent.workspace_settings").new({
  directory = vim.fn.stdpath("state") .. "/my-plugin/workspaces",
  root = vim.fn.getcwd(),
})

local effective, overrides = assert(settings:merge(my_defaults))
assert(settings:update({ my_option = { enabled = true } }))
-- settings:write(overrides) replaces the complete local override object.
```

The built-in prompt follows the active tool set and includes the current
working directory. A string replaces it completely. To append instructions,
compose the exported default from a callback:

```lua
local default_prompt = require("neoagent.system_prompt").default

require("neoagent").setup({
  system_prompt = function(context)
    return table.concat({
      default_prompt(context),
      "Run the project formatter after editing Lua files.",
    }, "\n\n")
  end,
})
```

The callback context contains `session`, `model`, `workspace`, the submitted
`prompt`, the active `tools`, and the discovered `agents` and `skills`. A
custom string or callback replaces the base prompt; contextual resources are
still appended. Set their configuration to `false` when the final prompt must
exclude them.

### AGENTS.md and skills

The default controller reads `stdpath("config") .. "/AGENTS.md"`, then every
`AGENTS.md` from the Git root through the active Workspace directory. Existing
files are included in broad-to-specific order, so the nearest instructions
have the last word. If no Git root exists, discovery walks from the filesystem
root.

Skills use the [Agent Skills](https://agentskills.io) `SKILL.md` layout. By
default Neoagent recursively scans `~/.agents/skills`,
`stdpath("config") .. "/neoagent/skills"`, and `.agents/skills` in each project
ancestor. Later global directories override earlier ones by skill name;
project skills override global skills, and nearer project skills override
broader ones.

Only each skill's name, description, and `SKILL.md` path enter the prompt. The
model uses `read_file` to load the complete instructions when a task matches,
then resolves referenced files relative to the skill directory. Consequently,
skills are included only when the active tool set contains `read_file`.

Replace either directory/file list to customize discovery, use an empty list
to disable one class of location, or set `agents = false` or `skills = false`
to disable that resource type entirely:

```lua
require("neoagent").setup({
  agents = {
    global_files = {},
    project_filenames = { "AGENTS.md", "NEOAGENT.md" },
  },
  skills = {
    global_dirs = { vim.fn.stdpath("config") .. "/my-skills" },
    project_dirs = {},
  },
})
```

These layers are usable without the controller or UI. `neoagent.agents` and
`neoagent.skills` each expose `discover(opts)` and `format(resources)`; their
discovery results include non-fatal `diagnostics` for malformed resources.

Set a mapping to `false` to disable it. With `position = "auto"`, Neoagent
prefers floating over a non-focused ordinary window so the source stays
visible; with one editor window it docks right.

Neoagent maps `NormalFloat` to `Normal` in its windows so unstyled content
inherits the editor background. Its own highlight groups are defined with
`default = true`, so colors can be changed with normal Neovim configuration.
The card groups are `NeoagentUserBackground`,
`NeoagentToolPendingBackground`, `NeoagentToolSuccessBackground`, and
`NeoagentToolErrorBackground`; Markdown groups use the
`NeoagentMarkdown...` prefix.

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

### Provider login

Provider login is also plain Lua. A provider names an entry from
`auth.methods`. A method has `name`, `login(interaction)`,
`refresh(credential)`, and `request_opts(credential)`. Login and refresh return
cancellable Runs; `interaction.prompt(spec, done)` and
`interaction.notify(event)` keep authentication independent from any UI. The
last function derives recursive request options for a valid credential.

Third-party plugins can supply methods directly in `setup()` or construct a
standalone manager:

```lua
local manager = require("neoagent.auth").new({
  methods = { my_plan = my_login_method },
  store = my_credential_store, -- read(id), write(id, credential)
})

local authenticated_model = manager:wrap(model, "my_plan")
```

The wrapped value is still an ordinary Model. Authentication resolution and
refresh happen when `model:stream()` starts; no Neoagent UI, Session, tools, or
controller are involved.

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

The Responses constructor has the same Model interface:

```lua
local model = require("neoagent.api.openai_responses").new({
  provider = "local",
  model = "reasoning-model",
  base_url = "http://127.0.0.1:8080/v1",
  reasoning = true,
  reasoning_effort = "high",
})
```

`require("neoagent.api.openai_codex_responses").new` exposes the Codex SSE
request profile directly. It intentionally performs no login or credential
lookup; wrap it with an auth manager when authentication is wanted.

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
Storage uses `workspaces/<sha256-of-canonical-root>/sessions/*.jsonl`, and no file
is created until the first message is accepted. Model and thinking changes use
Pi's `model_change` and `thinking_level_change` entries, but remain outside the
Session's message sequence.

`neoagent.chat.send(session, prompt, opts)` adds one model response.
`neoagent.chat.run(session, prompt, opts)` runs the tool loop and appends every
generated message. These adapters permit one active mutation per Session;
independent Models, agent runs, and Sessions remain concurrent.

A buffer-transform plugin can stay much simpler: call `model:stream()`, append
`text_delta` values into a replacement buffer or scratch buffer, and apply
`result.text` as the authoritative final contents. It does not need a Session,
agent, tools, Workspace, or the bundled UI.

See `:help neoagent` for the public contracts.

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
report and aggregate line coverage is strictly greater than 98%.
