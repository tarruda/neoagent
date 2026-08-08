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
provider protocol. Models expose accepted message modalities through `input`.
The adapters transform a request copy by replacing images with explicit text
placeholders when `input` excludes `image`; Sessions retain the original
multimodal messages. Request bodies and replayed JSON tool arguments use
canonical key ordering so process restarts do not perturb otherwise unchanged
prompt-cache prefixes for persisted Sessions. Provider, model, and per-call
`request_opts` are recursively layered before sending the request. The Codex
adapter classifies provider errors, retries transient requests that produced no
output, and reports safe metadata through an injected diagnostic callback.

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

The Codex-compatible `update_plan` tool is an opt-in bundled composition. It
stores successful snapshots in tool results, indexes derived current state by
an opaque per-Session identity, and reconstructs that state by scanning the
active conversation path after resume or branch navigation.

Tools may define `on_messages(messages, ctx)` for Controller compositions. The
Controller supplies complete active-conversation copies and the same opaque
`ctx.session_id` that execution exposes as `ctx.context.session_id`. This hook
keeps Session ownership above the reusable agent loop: direct `agent.run()`
neither imports a Session nor interprets tool state.

Tools may also carry a bundled-View `render(opts)` callback. The Window resolves
the active tool by name, and the View converts its line-and-segment
presentation into transcript text and highlights. Tool-specific rendering
therefore stays on the tool value while the View owns Neovim drawing and a
malformed callback falls back to the generic card.

`execute_tool(tool, arguments, ctx)` is the policy boundary. A custom
composition can add dialogs, sandboxing, logging, or post-edit checks
there without changing the tool or core agent loop. The context includes the
Model, active Run, caller context, executor, update callback, and a copy of the
current tool call.

Bundled tools resolve model-directed disk and subprocess work through optional
`ctx.fs` and `ctx.process` capabilities. Direct Lua calls use the host
filesystem and `neoagent.process` runner. A decorated executor can copy the
context and replace either capability for one invocation. Shell output uses
bounded memory, represents non-text bytes explicitly in tool results, and
streams original overflow through the filesystem capability. Results that
contain escape bytes include a bounded, valid UTF-8 display copy in details.
The bundled View interprets SGR sequences from that copy while rendering shell
cards. Its process runtime uses the configured default timeout unless the tool
call supplies one. The agent tool boundary accepts text blocks with valid UTF-8
strings.

## Workspace trust composition

`lua/neoagent/workspace_trust.lua` is an optional higher-level policy used by
the built-in `setup()` composition and available to custom compositions. It
resolves canonical trust targets, reads and updates the versioned trust store,
owns process-lifetime decisions, defines the transcript trust dialog, and
returns a visibility-aware View factory alongside the policy.

```text
Controller config ──► workspace_trust.compose() ──► View factory + policy
       │                                                │          │
       └──► Controller + explicit runtime policy ◄──────┘          │
                    │                                              │
                    └── unresolved ──► scoped dialog source ──► Window
```

The default composition injects one policy into Neo when tools or project
resource discovery make it trust-protected. Custom compositions use the same
`compose()` result, pass the policy through the explicit `neoagent.new()`
runtime object, pass the View factory and dialog source to their Window, and
attach that Window to the policy. Controller construction configuration stays
reusable across compositions. Chat and direct Controller construction receive
only policies supplied by their caller. The Controller invokes an injected
check before Session creation, Model selection, project discovery, and Run
startup. Its preparation path can publish the workspace context while
unresolved, which allows the View decorator to wait for an active visible
Controller before scheduling the dialog. Programmatic sends invoke the same
check and activate the protected Controller before dialog publication.

The policy uses the canonical Git worktree root or canonical cwd as an exact
target and uses case-insensitive keys on Windows. Session decisions live in a
module-owned process table. Persistent positive decisions use a deterministic
JSON document. Updates create private state paths, acquire a bounded
same-directory process lock, merge the current document, write a private
temporary file, and atomically rename it.

Dialog acceptance records either process or persistent trust and then re-runs
the protected Controller's preparation so its configured model resolves and the
published context reflects it immediately. Trust dialogs carry the protected
Controller name. The Window presents a scoped dialog only
while that Controller is active, retaining the unresolved request across
Controller selection. The Cancel action closes the Window through an attached
callback, while the Window retains its Controller draft. Closing the Window
leaves the decision unresolved. The policy receives current sandbox status
from the composition, including runtime sandbox toggles, so the prompt
describes the effective execution mode. Store and presenter failures leave the
target unresolved.

## Sandbox composition

`lua/neoagent/sandbox/` is an optional higher-level composition around the
execution-policy boundary. Core Models, the agent loop, Sessions, Controllers,
tools, Window, and View contain no sandbox policy.

```text
Default Neo stable toolset (`sandbox.enabled` selects the initial state)
      │
      ▼
sandbox/composition.lua ─────► generic dialog source ─────► Window
      │
      ├── probe/status ──────► sandbox/platform.lua
      │
      └── composes stable tools and a switchable `execute_tool()`
                                   ▲
agent.run() ── tool call ─────► current runtime state
                                   ├── host ──► configured executor
                                   │
                                   └── sandbox
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

The connections back into Neoagent are ordinary Lua extension points. Sandbox
composition consumes a plain `{ tools, execute_tool }` toolset and produces a
decorated toolset with an optional `system_prompt` guidance string. The built-in
switchable composition keeps that toolset and guidance stable while its
executor dispatches each call through the current runtime state. Window
presents a generic dialog source, and the configured executor receives a copied
context. The Controller appends the guidance after the composed agents and
skills sections, so the agent learns about execution controls and escalation
options before the first denial.
The reusable core does not import sandbox modules. Bundled tools participate
by calling the injected `ctx.fs` and `ctx.process` values.

The built-in Neo composition owns an editor-local sandbox selection behind one
stable toolset. `sandbox.enabled` selects the initial state. A disabled initial
state delays the platform probe until activation. Enabling prepares or selects
a restricted executor and one-shot escalation selector around the configured
host executor. Disabling makes the stable dispatcher bypass both layers and
strip escalation arguments before host execution. Each call selects its path
when it starts, so toggles can occur during a Run while in-flight capabilities
retain their existing lifetime. Runtime status owns the probe result and
established capabilities for `:NeoagentSandboxInfo`. Chat remains tool-free.

Enforcement copies each tool context and injects:

- a filesystem capability that evaluates lexical and canonical profile access
  before performing direct file operations inside the selected backend; and
- a process capability that resolves the profile, cwd, argv, environment,
  streaming, timeout, and cancellation behavior for the selected backend.

Both capabilities expire at the end of the tool call. The shell overflow path
uses a host temporary file recorded by path and inode. Later sandboxed reads
revalidate its identity and add an exact read grant to the selected backend.
Backend filesystem operations accept regular files and run with a bounded
timeout. Process exit status passes through to the tool. Nonzero exits with
recognized sandbox-denial text in bounded output, plus Linux `SIGSYS`, receive
restricted-execution guidance. Explicit policy denials and backend failures
produce sandbox-owned errors.

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
Shell approvals offer prefix retention when the command starts with at least
one literal argument token, and the escalation decorator retains any edited
argument-token prefix of that leading segment. The Controller supplies an
opaque Session identity, and the decorator discards its in-memory prefix set
when that identity changes. Only later calls that explicitly request
escalation consult the set. Conservative POSIX, cmd, and PowerShell
tokenizers end the offered prefix at the first operator, redirection,
expansion, substitution, or unsupported shell syntax and match remembered
rules only against one complete literal command.

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

Activation failure selects the configured host path. The workspace trust
prompt reports the failure when the built-in trust policy is active. With
workspace trust disabled, an initial failure wraps the configured View factory
with a sandbox-owned warning shown once when the requesting Controller first
becomes visible; a runtime request reports the failure immediately. Successful
activation records its full or degraded isolation status for
`:NeoagentSandboxInfo`. Runtime failure after activation is fail-closed.

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
files; persistence begins when the first message is accepted. Stores validate
JSON encoding and UTF-8 before mutating the tree or creating a file. A Store
validates complete trees when opening them, maintains an entry index, and
updates messages and model state incrementally for linear appends. Branch
selection rebuilds the active projection from the maintained index. Default
Store mutations return copied append or replacement projection updates for
the Session cache. Custom Stores may omit these updates; Sessions then reload
the projection and return structured storage errors when that reload fails.

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
- Active toolset
- Session and persistent store
- Current cancellable Run
- Steering queue
- Authentication interactions
- Retryable turn replay and cancellable backoff
- Context compaction
- AGENTS.md and skill discovery

The Controller owns shared mutable state and composes focused internal modules.
The session lifecycle module creates, activates, resumes, branches, and forks
Sessions. The run lifecycle module launches interactions, consumes steering,
classifies transient failures, retries eligible turns, compacts context, and
finishes or cancels Runs. Context metrics and session choices remain focused
calculations.

Its active toolset is a plain tools-and-executor pair that can be atomically
replaced while idle. Each Run snapshots that pair, so retries, continuations,
and tool calls share one selection. Provider retry metadata can declare
eligibility, delay, and a stricter attempt cap. Successful tool results carry
changed paths for unmodified-buffer refresh, and read-capable tools declare
skill-discovery metadata. The Controller publishes updates and feeds complete
active-conversation copies to optional tool state hooks after activation,
message changes, resume, forks, and branch changes. Message updates and
snapshots project the latest compaction checkpoint with its retained suffix,
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
- Keeps the current selection and presentation when visible target
  preparation fails
- Keeps a separate input draft per Controller
- Shares workspace input history
- Leaves inactive Controllers running independently

The passive View consumes Controller snapshots and updates and invokes callbacks
supplied by the Window. Its replaceable interface keeps presentation independent
from the model and agent loop. The bundled renderer produces compact transcript
cards and full card content from the same block values. Transcript cards clip
lines at the current visible width by default and rebuild after layout changes;
configured card wrapping presents their complete lines. The Window supplies a
tool resolver, so the bundled View can consume an optional semantic renderer
carried by the active tool without recognizing tool names. The View can omit
thinking blocks while the Controller and Session retain complete messages. The
View resolves the card beneath the focused transcript cursor, provides
count-aware previous and next card motions, draws the card outline in a
presentation namespace, and owns the read-only floating details buffer and
window.

An optional dialog source lets an executor inject a lifetime-scoped
`ctx.dialog` capability and publish bounded asynchronous requests to a Window.
Requests select transcript or floating placement, provide their own actions,
and may collect editable text. An optional Controller name scopes presentation
to that Controller; `dialog.wrap()` derives this scope from an agent execution
context when the request omits it. The Window retains the unresolved request
while another Controller is active. The Window owns presenter attachment and
teardown, while the bundled View renders requests without interpreting action
IDs. The source resolves requests in FIFO order and cancels pending requests
when its presenter detaches.

## Public composition

`lua/neoagent/init.lua` provides the public facade. `new(opts, runtime)` keeps
Controller configuration and explicitly injected runtime policies as separate
values.

`setup()` creates two Controllers in one default Window:

- **Neo** uses the configured coding prompt, tools, AGENTS.md, skills, a
  workspace trust guard, and runtime-selectable sandbox execution.
- **Chat** uses an empty system prompt and tool list, with resource discovery
  disabled.

Top-level conversation functions and commands target the Controller currently
selected by the default Window. Sandbox controls target the built-in Neo
Controller owned by `setup()`.

`plugin/neoagent.lua` defines commands such as `:Neoagent`,
`:NeoagentModel`, and `:NeoagentResume`, then delegates to the public API.

## Request flow

1. The View submits text to the Window.
2. The Window calls the active Controller.
3. The Controller checks an injected workspace trust policy, then resolves its
   Workspace, Session, Model, tools, and prompt.
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
