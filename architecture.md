# Neoagent architecture

Neoagent is built from plain Lua values with explicit dependencies. The agent
core can run without Neovim configuration, persistence, or UI; the bundled
plugin adds those pieces as higher-level compositions.

```text
Neovim commands
      │
      ▼
Window ─────────────────────────► View
  │                                ▲
  │ selects                        │ updates
  ▼                                │
Controller ────────────────────────┘
  ├── Workspace and resources
  ├── Session ──► Pi v3 JSONL store
  ├── model, auth, retry, compaction
  └── chat.run()
         └── agent.run()
              ├── Model:stream() ──► API ──► transport
              └── execute_tool() ──► Tool.execute()
```

## Core

The reusable core consists of:

- `neoagent.async`, which provides cancellable coroutine-based Runs.
- `neoagent.transport.*`, which handles curl and bounded SSE parsing.
- `neoagent.api.*`, which translates messages and streaming events for each
  provider protocol.
- `neoagent.agent`, which runs the model and tool loop.

A Model is any value implementing:

```lua
local run = model:stream({
  messages = messages,
  tools = schemas,
  on_event = on_event,
  on_done = on_done,
})
```

The call returns a cancellable Run. `agent.run()` receives its Model, messages,
tools, executor, context, and steering callback explicitly. It copies the input
messages, streams an assistant turn, executes tool calls, and repeats until the
model finishes or the Run is cancelled.

Core modules do not import configuration, Sessions, storage, Workspace,
Controllers, bundled tools, or UI. Cancellation propagates through Models,
tools, and nested Runs and completes once. Partial assistant output remains
available when a request fails or is cancelled.

## Models, providers, and authentication

`neoagent.models` resolves provider and model configuration into Models.
`neoagent.registry` composes the built-in catalog with user overrides. The
built-in adapters support Anthropic Messages, OpenAI-compatible Chat
Completions, OpenAI Responses, and Codex Responses.

Providers, models, and individual calls may supply `request_opts`. These layers
merge across `url`, `headers`, and `body`. Thinking levels are model-declared
request-option layers selected by Controllers. Models also declare accepted
input modalities. An adapter replaces unsupported images in a request copy
with a text placeholder while the Session keeps the original content.

Authentication wraps a Model at stream time. Login methods and credential
stores are injected values, which keeps OAuth flows separate from API codecs
and UI. Credential writes, refreshes, and deletion are serialized and atomic.
Provider state and diagnostics contain bounded, secret-free data.

A Provider Service supplies live status, operations, and optional model
discovery for one provider. Services are shared within a composition and are
injected into Controllers. Agent and compaction Runs hold usage leases so a
mutating provider operation cannot race an active request. Services publish
semantic state; the Renderer decides how that state appears.

The bundled Codex, OpenCode Go, and llama.cpp services use this interface for
account limits or router state. Dynamic catalogs merge beneath configured model
entries and may be cached in the provider state store.

## Tools and execution

A Tool is a plain table:

```lua
{
  name = "tool_name",
  description = "...",
  input_schema = { ... },
  execute = function(arguments, ctx) ... end,
}
```

`execute_tool(tool, arguments, ctx)` is the execution-policy boundary. A caller
can decorate it with logging, dialogs, approval, sandboxing, or custom process
handling. The agent loop contains no approval or permission policy.

Bundled file and process tools use optional `ctx.fs` and `ctx.process`
capabilities. Direct calls use the host implementations. A sandbox or other
decorator replaces those capabilities for one invocation. File tools read and
write disk; loaded buffers are refreshed only after a successful mutation and
only when they have no local changes.

Tools may define two higher-level hooks:

- `on_messages(messages, ctx)` derives state from a copied active conversation.
- `render(opts)` returns semantic presentation data for the active Renderer.

The Controller calls `on_messages`; direct `agent.run()` remains
Session-independent. The Window resolves tool presentation, and the View owns
all Neovim resources.

## Resources and runtime policy

AGENTS.md and skill discovery live above the reusable core. Controllers add
discovered resources to the system prompt when configured, and skills are
loaded on demand through file-reading tools.

Workspace trust is an optional policy used by the built-in Neo composition. It
checks the canonical workspace before project resources are loaded or a
tool-capable Run starts. Persistent decisions are stored atomically outside
user configuration. Custom Controllers receive trust policy only through
explicit runtime injection.

The optional sandbox decorates the bundled executor with filesystem and process
capabilities. Linux uses namespaces and seccomp, Windows uses restricted tokens,
ACLs, Job Objects, and WFP, and macOS uses Seatbelt through
`/usr/bin/sandbox-exec`. Sandbox profiles define filesystem and network access.
Tool Lua runs in Neovim, so custom tools participate by routing effects through
the injected capabilities.

Escalation is another executor decoration. A request is presented through an
injected dialog source and grants host capabilities for one tool call after
approval. Remembered shell prefixes are scoped to one Session and apply only to
later calls that explicitly request escalation.

## Sessions and persistence

`Session.new()` creates an in-memory, tool-free message owner. Persistence is
an optional injected store.

The bundled store uses the Pi v3 append-only JSONL tree format. The active path
is projected into model context while the full tree retains branches, linked
forks, labels, model state, and compaction entries. Empty Sessions create no
files. Stores validate the full tree when opening and validate new entries
before appending.

Workspace settings, input history, session indexes, and provider state use
atomic writes and cross-process file locks. Session files remain authoritative;
disposable indexes can be rebuilt from them. Credential and state directories
use private permissions.

Compaction receives the Session path and Model explicitly. A successful summary
becomes a tree entry and replaces the compacted prefix in model context. The
Controller owns automatic thresholds, overflow recovery, and continuation after
a length-limited response.

## Controller

`neoagent.controller` is the main orchestration boundary. A Controller owns:

- configuration, Workspace, model, and thinking selection;
- its Session, store, active toolset, and current Run;
- retry, steering, and compaction state;
- authentication and Provider Service interaction;
- AGENTS.md and skill discovery.

Each Run snapshots its toolset. Steering enters the core through the explicit
`get_steering_messages` callback and is consumed between assistant/tool turns.
Retries remove the failed partial response from the active branch before
replaying, while the Session retains it as inactive history.

Controllers publish transcript snapshots and four update types: `messages`,
`context`, `event`, and `finish`. Consumers observe this interface without
owning the agent loop. Destruction cancels active work and releases provider
subscriptions.

## Window, View, and Renderer

A Window owns one View and one or more uniquely named Controllers. It selects
the active Controller, preserves one input draft per Controller, shares
workspace input history, and keeps inactive Controller Runs alive. The
command-facing default Window can be replaced by a custom composition.

The View is passive. It consumes Controller messages, context, events, and
dialogs, then owns buffers, windows, mappings, extmarks, focus, and scrolling.
It does not select Models, execute tools, or mutate Sessions.

Every bundled View receives an explicit Renderer. Renderer methods consume
copied semantic blocks and bounded layout context, then return declarative
lines, highlights, backgrounds, and metadata. Pi and Codex are bundled
Renderers. A custom Renderer can replace either one without changing Session
content or Controller state.

Dialogs follow the same separation: an executor publishes a semantic request,
the Renderer formats it, and the View owns interaction and response routing.

## Public composition

`require("neoagent").setup()` creates two Controllers in one default Window:

- **Neo** uses the coding prompt, bundled tools, project resources, workspace
  trust, and the runtime-selectable sandbox executor.
- **Chat** uses an empty system prompt and tool list with resource discovery
  disabled.

`neoagent.new(opts, runtime)` creates an independent Controller, and
`neoagent.new_window(opts)` assembles Controllers into another Window. Runtime
policies and shared Provider Services are passed separately from Controller
configuration.

## Request flow

1. The View submits input to the Window.
2. The Window sends it to the active Controller.
3. The Controller checks trust and resolves the Workspace, Session, Model,
   resources, and toolset.
4. `chat.run()` records the user message and calls `agent.run()`.
5. Model events flow through Controller publications to the View.
6. Tool calls pass through the configured executor and return as tool-result
   messages.
7. Completed messages are appended to the Session and optional store.
8. Cancellation propagates through the active Model, tool, and nested Runs.
