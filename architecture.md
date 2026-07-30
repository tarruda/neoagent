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
composition can add dialogs, sandboxing, logging, or post-edit checks
there without changing the tool or core agent loop. The context includes the
Model, active Run, caller context, executor, update callback, and a copy of the
current tool call.

Bundled tools resolve model-directed disk and subprocess work through optional
`ctx.fs` and `ctx.process` capabilities. Direct Lua calls use the host
filesystem and `neoagent.process` runner. A decorated executor can copy the
context and replace either capability for one invocation. Shell output uses
bounded memory and streams overflow through the filesystem capability.

## Sandbox composition

`lua/neoagent/sandbox/` is an optional higher-level composition around the
execution-policy boundary. Core Models, the agent loop, Sessions, Controllers,
tools, Window, and View contain no sandbox policy.

```text
Default Neo setup (`sandbox.enabled`)
      │
      ▼
sandbox/composition.lua ─────► generic dialog source ─────► Window
      │
      ├── probe/status ──────► sandbox/platform.lua
      │
      └── decorates the Controller's `execute_tool()`
                                   ▲
agent.run() ── tool call ──────────┘
                                   │
                                   ▼
                      dialog.wrap(): per-call ctx.dialog
                                   │
                                   ▼
                         sandbox/escalation.lua
                          ├── approved once
                          │      └── configured executor
                          │          + revocable host ctx.fs / ctx.process
                          │                    │
                          │                    ▼
                          │               Tool.execute()
                          │
                          └── ordinary
                                 │
                                 ▼
                           sandbox/enforce.lua
                            ├── profile.lua / policy.lua
                            ├── configured executor ──────► Tool.execute()
                            └── per-call ctx.fs / ctx.process
                                             │
                                             ▼
                              selected backend (`fs` / `exec`)
                               │
                               ├── Linux
                               │    ├── lua/neoagent/sandbox/linux/
                               │    │     check/fs/exec adapter, protocol,
                               │    │     platform data
                               │    └── scripts/sandbox_linux_runtime.lua
                               │          standalone headless child:
                               │          namespaces, mounts, seccomp,
                               │          supervision, framed output
                               │
                               ├── macOS
                               │    ├── lua/neoagent/sandbox/macos/
                               │    │     check/fs/exec adapter,
                               │    │     Seatbelt profile compiler
                               │    ├── /usr/bin/sandbox-exec
                               │    └── scripts/sandbox_macos_runtime.lua
                               │          filesystem and process supervision
                               │
                               └── Windows
                                    ├── lua/neoagent/sandbox/windows/
                                    │     check/fs/exec adapter,
                                    │     ACL-plan compiler, framed protocol
                                    └── scripts/sandbox_windows_runtime.lua
                                          standalone headless child:
                                          Win32 FFI, accounts, DPAPI, ACLs,
                                          restricted tokens, WFP, Job Objects
```

The connections back into Neoagent are ordinary Lua extension points: default
setup installs a decorated `execute_tool()` function, Window presents a generic
dialog source, and the configured executor receives a copied context. The
reusable core does not import sandbox modules. Bundled tools participate by
calling the injected `ctx.fs` and `ctx.process` values.

The default setup path asks `neoagent.sandbox.composition` to decorate Neo only
when `sandbox.enabled` is true. The composition runs an active platform probe,
then layers a restricted executor and one-shot escalation selector around the
configured executor. It returns a generic dialog source for the default
Window. The copied Controller configuration retains the probe result and
established capabilities for `:NeoagentSandboxInfo`. Chat explicitly disables
sandbox composition.

Enforcement copies each tool context and injects:

- a filesystem capability that evaluates lexical and canonical profile access
  before performing direct file operations inside the selected backend; and
- a process capability that resolves the profile, cwd, argv, environment,
  streaming, timeout, and cancellation behavior for the selected backend.

Both capabilities expire at the end of the tool call. The shell overflow path
uses a host temporary file recorded by path and inode. Later sandboxed reads
revalidate its identity and add an exact read grant to the selected backend.
Backend filesystem operations accept regular files and run with a bounded
timeout.

The default profile grants a platform-selected shared temporary directory and
points `TMPDIR`, `TMP`, and `TEMP` at it. POSIX systems use the active host
temporary directory and also grant canonical `/tmp`. Windows uses the managed
`shared-tmp` directory beneath the protected sandbox state. Temporary
artifacts remain available across tool invocations.

Escalation copies tool schemas and adds reserved request fields under
`options`. A valid request publishes a sandbox-defined transcript dialog
through `ctx.dialog`. Approval selects the configured host executor for one
call through revocable host filesystem and process proxies. Denial and
presenter failure return structured tool errors.
Eligible shell approvals can retain an edited argument-token prefix in the
escalation decorator. The Controller supplies an opaque Session identity, and
the decorator discards its in-memory prefix set when that identity changes.
Only later calls that explicitly request escalation consult the set.
Conservative POSIX, cmd, and PowerShell tokenizers accept one literal command;
operators, redirections, expansions, substitutions, and unsupported shell
syntax suppress the option and cannot match an existing prefix.

`neoagent.sandbox.platform` selects explicit Linux, macOS, and Windows modules.
Shared path operations select POSIX or Windows semantics for roots,
containment, canonical candidates, sorting, and environment keys. The Windows
profile compiler projects longest-path policy into writable ACL roots and
explicit read/write deny paths. A missing protected child of a writable root
becomes a journaled, identity-checked placeholder when its parent exists. The
compiler supports a nested writable root beneath a read rule and rejects
writes reopened below a deny rule and policy shapes whose ACL projection would
widen access.

The Windows Lua adapter launches a standalone headless Neovim runtime and
speaks a bounded, versioned, binary-safe framed protocol over its standard
streams. Elevated setup provisions random dedicated offline and online local
accounts, current-user DPAPI state, persistent account-scoped Windows
Filtering Platform rules with per-state random filter identifiers, and a
managed shared temporary directory inside the protected state tree. A live
probe proves the required capabilities before activation. Each execution uses
a freshly generated restricting SID, revalidates canonical profile paths and
state-directory separation, and applies ACL grants and carveouts. Parent write
grants omit delete-child authority. The owner runtime starts an internal
runner under the selected sandbox account with `CreateProcessWithLogonW` over
account-scoped named pipes whose peer process IDs are verified. The runner
restricts its primary token and handles direct filesystem calls through
impersonation.
Process launch uses `CreateProcessAsUserW`, quoted Windows argv, executable
resolution through the explicit `PATH` and `PATHEXT`, a case-insensitive
explicit environment, and a fresh private desktop. The owner runtime and account
runner each assign their suspended child atomically to a kill-on-close Job
Object, so cancellation covers both stages and every descendant. Restricted
network profiles use the offline account; enabled profiles use the online
account. Capability ACL leases are serialized per state directory and revoked
at completion.
The owner-only state records dedicated account identities, each transient
capability ACL lease, and owned placeholder identities. The next run
reconciles the mutation journal after interruption. Stale capability SIDs
carry no authority.

The Linux runtime is a standalone headless Neovim script that uses LuaJIT FFI for
user, mount, PID, IPC, and UTS namespaces, bind mounts, tmpfs, capability
removal, seccomp, descendant supervision, and framed binary MessagePack output.
Restricted-network profiles also use a network namespace and socket filters.
Missing read and deny entries beneath writable grants become protected-create
rules. Seccomp user notifications send pathname creation and removal syscalls
to the namespace supervisor, which resolves their target paths and performs
permitted operations while the calling thread remains blocked. Restricted
paths remain absent from the host filesystem until an unrelated host process
creates them, and host-created replacements retain creation and removal
protection.
The probe prefers a fresh procfs owned by the PID namespace. A procfs setup
restriction selects the inherited read-only host procfs and records the
degraded stage and procfs isolation while preserving the other established
boundaries. macOS compiles a parameterized Seatbelt profile for
`/usr/bin/sandbox-exec` and uses a Neovim runtime for sandboxed filesystem
operations and process-tree supervision. Linux staging roots are created
atomically beneath `/run/user/<uid>` or `/dev/shm`; the namespace presents
dedicated `/run`, `/dev`, and `/dev/shm` paths to the launched process. The
staging root's device and inode identity is recorded and revalidated before use
and cleanup. Profiles that expose every host staging directory and changed root
identities fail closed.

Activation failure preserves the configured host executor and wraps the
configured View factory with a sandbox-owned warning shown once when the
requesting Controller first becomes visible. Successful activation records
its full or degraded isolation status for `:NeoagentSandboxInfo`. Runtime
failure after activation is fail-closed.

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
- Retryable turn replay and cancellable backoff
- Context compaction
- AGENTS.md and skill discovery

The Controller starts `chat.run()`, handles storage, classifies transient
transport and provider failures, and replays eligible turns under the configured
retry budget. Provider retry metadata can declare eligibility, delay, and a
stricter attempt cap. It retries context overflows after compaction, refreshes
unmodified buffers after file edits, and publishes updates. Focused internal
modules calculate context usage and format session choices; the Controller owns
the mutable run and session state. Message updates and snapshots project the
latest compaction checkpoint with its retained suffix, while the Session tree
retains the complete active path. A replay removes a failed partial assistant
message from the active branch before continuing the interaction:

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

The passive View consumes Controller snapshots and updates and invokes callbacks
supplied by the Window. Its replaceable interface keeps presentation independent
from the model and agent loop.

An optional dialog source lets an executor inject a lifetime-scoped
`ctx.dialog` capability and publish bounded asynchronous requests to a Window.
Requests select transcript or floating placement, provide their own actions,
and may collect editable text. The Window owns presenter attachment and
teardown, while the bundled View renders requests without interpreting action
IDs. The source resolves requests in FIFO order and cancels pending requests
when its presenter detaches.

## Public composition

`lua/neoagent/init.lua` provides the public facade.

`setup()` creates two Controllers in one default Window:

- **Neo** uses the configured coding prompt, tools, AGENTS.md, skills, and
  optional sandbox composition.
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
