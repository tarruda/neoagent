# Neoagent Architecture

> [!IMPORTANT]
> Keep this file up to date with Neoagent's architecture. Update it whenever
> component ownership, layer boundaries, public contracts, data flow, or
> persistence behavior changes.

Neoagent is a layered composition of plain Lua values. The reusable agent core
is separated from Neovim-specific orchestration and UI.

```text
Neovim commands
      │
      ▼
Default Window ───────────────► Passive View/UI
      │                           ▲
      │ selects                   │ updates
      ▼                           │
Controller ───────────────────────┘
      │
      ├── Workspace / configuration / auth
      ├── Session ──► Pi v3 JSONL storage
      ├── model selection / thinking / compaction
      └── chat.run()
             │
             ▼
         agent.run()
          ├── Model:stream()
          │      └── API codec ──► SSE ──► curl
          └── execute_tool()
                 └── Tool.execute()
```

## Reusable core

The lowest layers are independent of configuration, Sessions, persistence,
Controllers, and UI:

- `lua/neoagent/async.lua` provides the cancellable coroutine-based `Run`
  abstraction.
- `lua/neoagent/transport/` provides curl transport and SSE parsing. Curl
  executes one HTTP exchange and returns response status and headers on both
  success and failure; failures also retain bounded process diagnostics.
- `lua/neoagent/api/` provides provider protocol encoders and streaming
  decoders.
- `lua/neoagent/agent.lua` implements the model and tool loop.

A Model has one primary contract:

```lua
model:stream({
  messages = messages,
  tools = schemas,
  on_event = callback,
  on_done = callback,
})
```

It returns a cancellable `Run`.

`agent.run()` receives every dependency explicitly: Model, messages, exact
tools, executor, context, and steering callback. It copies the input messages,
streams an assistant response, executes requested tools, appends tool results,
and repeats while the model requests tools or steering supplies another turn.
A final assistant response or cancellation ends the Run.

## Models and providers

`lua/neoagent/models.lua` resolves provider and model configuration into
concrete Models.

The built-in API adapters are:

- OpenAI-compatible chat completions
- OpenAI Responses
- OpenAI Codex Responses

Each adapter translates Neoagent's normalized messages and events into the
provider protocol. Provider, model, and per-call `request_opts` are recursively
layered before sending the request.

Authentication wraps a Model. Credentials are resolved at stream time, which
keeps authentication independent from the API and UI layers.

## Tools and execution policy

Tools are plain tables:

```lua
{
  name = "tool_name",
  description = "...",
  input_schema = {...},
  execute = function(arguments, ctx) ... end,
}
```

The default coding tools live under `lua/neoagent/tools/`:

- `read_file`
- `write_file`
- `edit_file`
- `shell`
- `read_agent_documentation`

`execute_tool(tool, arguments, ctx)` is the policy boundary. A custom
composition can add confirmation, sandboxing, logging, or post-edit checks
there without changing the tool or core agent loop.

## Sessions and persistence

`lua/neoagent/session.lua` owns conversation state. A bare `Session.new()` is
an in-memory, tool-free message owner; persistence is injected as a store.

`lua/neoagent/storage.lua` implements Pi v3 append-only JSONL sessions. The
session is a tree that supports:

- Active-branch projection
- Moving to previous leaves
- Branch summaries and labels
- Linked session forks
- Model and thinking changes
- Context compaction entries

Only the active path is projected into model context. Empty sessions create no
files; persistence begins when the first message is accepted.

Workspace-scoped settings, input history, and sessions are stored beneath a
hash of the canonical working directory.

## Controller

`lua/neoagent/controller.lua` is the main higher-level composition boundary.
Each Controller owns:

- Complete configuration
- Workspace
- Model selection and thinking level
- Session and persistent store
- Current cancellable Run
- Steering queue
- Authentication interactions
- Context compaction
- AGENTS.md and skill discovery

The Controller starts `chat.run()`, handles storage, retries context overflows
after compaction, refreshes unmodified buffers after file edits, and publishes
updates:

```lua
{ type = "messages", ... }
{ type = "context", ... }
{ type = "event", ... }
{ type = "finish", ... }
```

This publish and snapshot interface lets consumers observe a Controller without
owning its agent loop.

## Window and passive View

`lua/neoagent/window.lua` owns one View and one or more uniquely named
Controllers.

The Window:

- Selects the active Controller
- Subscribes the View to that Controller
- Restores its transcript and transient events
- Keeps a separate input draft per Controller
- Shares workspace input history
- Leaves inactive Controllers running independently

The View in `lua/neoagent/ui.lua` is passive: it renders messages and events and
invokes callbacks supplied by the Window. It does not own the model or agent
loop, which makes it replaceable with a custom UI.

## Public composition

`lua/neoagent/init.lua` provides the public facade.

`setup()` creates two Controllers in one default Window:

- **Neo** uses the configured coding prompt, tools, AGENTS.md, and skills.
- **Chat** uses an empty system prompt and tool list, with resource discovery
  disabled.

Top-level functions and commands target the Controller currently selected by
the default Window.

`plugin/neoagent.lua` defines commands such as `:Neoagent`,
`:NeoagentModel`, and `:NeoagentResume`, then delegates to the public API.

## Request flow

1. The View submits text to the Window.
2. The Window calls the active Controller.
3. The Controller resolves its Workspace, Session, Model, tools, and prompt.
4. `chat.run()` records the user message and invokes `agent.run()`.
5. The agent streams from the Model.
6. API events flow back through Controller publications to the View.
7. Tool calls pass through `execute_tool`, then return as tool-result messages.
8. Completed messages are appended to the Session and store.
9. Cancellation propagates through nested Runs, including model requests and
   tools.

The central architectural principle is that each layer is directly usable and
replaceable. Models, tools, executors, Sessions, Controllers, Windows, and
Views are ordinary Lua compositions with explicit dependencies.
