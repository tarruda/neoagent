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
  decoders. Protocol packages keep request construction and event decoding as
  focused internal modules while the public Model owns transport and
  cancellation.
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
concrete Models. `lua/neoagent/registry.lua` composes user overrides with the
explicit provider catalogs under `lua/neoagent/registry/`.

The built-in API adapters are:

- Anthropic Messages
- OpenAI-compatible chat completions
- OpenAI Responses
- OpenAI Codex Responses

Each adapter translates Neoagent's normalized messages and events into the
provider protocol. Request bodies and replayed JSON tool arguments use
canonical key ordering so process restarts do not perturb otherwise unchanged
prompt-cache prefixes for persisted Sessions. Provider, model, and per-call
`request_opts` are recursively layered before sending the request. The Codex
adapter
classifies provider errors, retries transient requests that produced no output,
and reports safe metadata through an injected diagnostic callback.

Authentication wraps a Model. Credentials are tagged API-key or OAuth values
and are resolved at stream time, which keeps authentication independent from
the API and UI layers. A stored credential owns its provider; an ambient API
key is consulted when storage has no credential, and deleting the stored value
restores the ambient source. OAuth refresh, login writes, and deletion are
serialized by the credential store. Enumeration exposes only credential IDs
and types. Anthropic's plan composition uses cancellable PKCE callback or
manual-code login and derives Claude Code identity headers at request time.
The configured Codex composition injects a private rotating JSONL
diagnostic sink; direct Model construction remains independent from file
logging.

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

`lua/neoagent/compaction.lua` is the stable compaction API. Its planning module
owns token estimates, safe boundaries, and preparation; its summary module
owns serialization and cancellable Model execution.

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
- Retryable turn replay
- Context compaction
- AGENTS.md and skill discovery

The Controller starts `chat.run()`, handles storage, replays provider-declared
retryable turns after cancellable backoff, retries context overflows after
compaction, refreshes unmodified buffers after file edits, and publishes
updates. Focused internal modules calculate context usage and format session
choices; the Controller owns the mutable run and session state. Message updates
and snapshots project the latest compaction checkpoint with its retained suffix,
while the Session tree retains the complete active path. A replay removes a
failed partial assistant message from the active branch before continuing the
interaction:

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

The passive View facade in `lua/neoagent/ui.lua` owns the paired window
lifecycle and composes focused layout, rendering, transcript, and input modules
under `lua/neoagent/ui/`. It renders messages and events, presents compaction
checkpoints as expandable cards, and invokes callbacks supplied by the Window.
The transcript title renders the Controller label, model, and thinking level.
Its footer renders active state on the left and context usage followed by
provider status on the right. Steering status uses virtual-line decoration.
Transcript text updates wait for pending operators and active Visual selections,
preserving register, operator, and selection state while streaming. The
replaceable View remains independent of the model and agent loop.

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
