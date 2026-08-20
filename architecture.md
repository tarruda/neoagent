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
  success and failure; failures also retain bounded process diagnostics. SSE
  parsing bounds both pending lines and complete multiline event payloads.
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
Calls carrying a provider argument-normalization error produce error tool results
without entering the executor. A final assistant response or cancellation ends
the Run.

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
The built-in adapters normalize malformed or non-object tool arguments into
non-executable calls so the agent can return each failure to the model.

Authentication wraps a Model. Credentials are tagged API-key or OAuth values
and are resolved at stream time, which keeps authentication independent from
the API and UI layers. A stored credential owns its provider; an ambient API
key is consulted when storage has no credential, and deleting the stored value
restores the ambient source. OAuth refresh, login writes, and deletion are
serialized by a credential-store lock. Lock acquisition is bounded, retries only
contention, and refreshes the lock timestamp while a mutation is active.
Enumeration exposes only credential IDs and types. Anthropic's plan composition
uses cancellable PKCE callback or manual-code login and derives Claude Code
identity headers at request time.
The configured Codex composition injects a private rotating JSONL diagnostic
sink. Rotation and append share a cross-process lock for each path; direct
Model construction remains independent from file logging.

A Provider Service is an explicit runtime value for provider state,
operations, and optional dynamic catalogs. It is a plain table with `id`,
`name`, `state()`, and an `operations` table. Optional members include
`get_models()`, `refresh_models(ctx)`, `refresh_catalog(opts)`,
`wrap_model(model)`, `subscribe(listener)`, `on_event(event)`, and
`destroy()`. `lua/neoagent/provider_service.lua` validates the value, exposes
sorted operation metadata, builds operation contexts, and starts operations
as cancellable Runs. Its service-owned runtime serializes operations across
Controllers and holds a usage lease for every agent or compaction Run. A
usage lease blocks mutating operations on the shared service, and an active
mutating operation blocks new usage leases. Failed service composition
destroys every value constructed during that attempt.
`lua/neoagent/provider_state.lua` normalizes console snapshots and bounds
every retained string and collection. Its dashboard value owns a copied
snapshot and a subscriber list. Providers call `dashboard:push()` with
JSON-compatible `status`, `field`, `progress`, `list`, and `activity` blocks.
Pushes from libuv callbacks schedule subscriber delivery onto Neovim's main
loop. Renderers convert those semantic blocks into presentation.

Configured providers may declare a `service` constructor.
`lua/neoagent/provider_services.lua` builds the values from secret-free
projections and injects them through `runtime.providers`. `service_opts`
and `catalog_cache` carry copied provider-specific configuration. A catalog
cache policy is `false` or a table with a non-negative `ttl_ms`. The basic Codex
service (`lua/neoagent/providers/codex.lua`) pushes plan and rolling-window
meters from `provider_status` events produced from response headers, plus
request token counts from usage events. The
dynamic catalog seam in `models.available()` and `models.resolve()` merges
validated `get_models()` entries under the configured model table and honors
user removals recorded by `registry.compose()`. Providers with
`auth_optional = true` expose Models and resolve credentials opportunistically.

Operations receive a copied public provider projection, the selected model,
`agent_running`, a cancellable auth resolution Run, and a provider-neutral
`interact` adapter with select, input, confirm, progress, and notify
capabilities. An operation descriptor may provide synchronous argument
completion. A successful operation may return a bounded document artifact,
which the Controller command adapter opens in a scratch tab.
`auth.Manager:resolve()` may include validated `public_metadata` from an auth
method; credential values stay outside provider state and interactions.

The llama.cpp provider (`lua/neoagent/providers/llama.lua`) composes a curl
client for router `list`, `load`, `unload`, `download`, SSE progress, and
bounded wait loops; a Hugging Face search client; a persisted dynamic
catalog; and catalog, refresh, load, unload, download, and preset operations.
Model definitions carry an HF source, router load parameters, and inference
parameters. Alias ids route inference to the router model id through
`request_opts`, and the preset operation renders a current server-side
`--models-preset` INI document. Definitions merge ahead of the server
catalog. The default cache TTL is 60 seconds and the provider accepts
`catalog_cache = false` or a custom TTL. Catalog-dependent operations publish
their fresh router results through the same cache helper. A startup refresh
runs for explicit and default-model providers; login and provider mutations
trigger a forced refresh. A Controller shows a pending dynamic selection and
resolves it when discovery publishes the matching model.

The service owns one SSE subscription while its dashboard has subscribers,
including when the catalog was restored from cache. Router events push load
and download progress, update catalog status, and record lifecycle activity.
Its Model wrapper gives each concurrent request independent preparation,
generation, completion, and token state. The wrapper reads the latest catalog
status to disable a configured request deadline while the router loads the
requested model. Load, unload, and download command waits have configured
deadlines, and cancellation of a load or download requests a server-side
unload. The auth method stores the server URL, uses anonymous access when
accepted, prompts for an API key after an authorization failure, and exposes
the URL as public metadata.

`lua/neoagent/state_store.lua` persists provider entries with atomic writes
and file locks. `lua/neoagent/provider_catalog.lua` guards publications by
generation and applies the configured cache window. Direct publications from
provider operations invalidate older in-flight refreshes. State reads and
writes report structured failures. The llama.cpp cache contains a versioned
projection of model identity, status, modalities, context, and size. Router
command lines, paths, presets, progress payloads, and credentials stay outside
runtime snapshots and persistence. The curl transport accepts `GET` requests
without bodies and numeric `timeout_ms` values; `false` disables curl's
deadline for router-managed autoload streams.

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

Tools may also carry a renderer-neutral `render(opts)` callback. Its copied
inputs contain tool arguments, the current result, and lifecycle state. It
receives no Renderer identity, layout dimensions, spinner state, or Neovim
resources. The callback returns semantic activity, plan, edit, or plain-text
data. The Window resolves the active tool by name and supplies that capability
to the selected Renderer. Transcript block rendering also receives adjacent
blocks so a Renderer can express grouping without placing presentation state
in Sessions. Tool-specific semantic data stays on the tool value while the
Renderer owns layout, card chrome, highlights, clipping, animation, source
syntax, and malformed-presentation fallback. The View owns Neovim drawing.

Bundled filesystem and process tools expose activity actions and subjects.
The Edit tool parses its retained unified patch into numbered semantic rows,
and the plan tool exposes explanation text plus step statuses. Codex presents
compact activity headings, command gutters, numbered patch previews, and todo
lists. Pi uses ordinary tool cards for activities and edits, and presents plans
inside its card chrome. Complete Read and Write presentations may identify
source ranges for filetype syntax according to the selected Renderer.

`execute_tool(tool, arguments, ctx)` is the policy boundary. A custom
composition can add dialogs, sandboxing, logging, or post-edit checks
there without changing the tool or core agent loop. The context includes the
Model, active Run, caller context, executor, update callback, and a copy of the
current tool call.

Bundled tools resolve model-directed disk and subprocess work through optional
`ctx.fs` and `ctx.process` capabilities. Direct Lua calls use the host
filesystem and `neoagent.process` runner. The host runner owns one process tree
per call through POSIX process groups or Windows Job Objects and closes that
tree on completion, timeout, or cancellation. Retained process capture may
carry a combined byte limit. `read_file` bounds source image bytes, decoded
pixels, encoded payloads, and every ImageMagick invocation; conversion receives
explicit time, memory, map, disk, pixel, and capture limits. A decorated
executor can copy the context and replace either capability for one invocation.
Shell output uses bounded memory, represents non-text bytes explicitly in tool
results, and streams original overflow through the filesystem capability. Results that
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
account. Elevated setup and capability ACL leases are serialized per state
directory by one named OS mutex. Capability leases are revoked at completion.
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
validates complete trees when opening them, including leaf, label,
branch-summary, and compaction references. Compaction retention starts on the
active parent path. The Store maintains an entry index and updates messages and
model state incrementally for linear appends. Branch selection rebuilds the
active projection from the maintained index. Default Store mutations return
copied append or replacement projection updates for the Session cache. Custom
Stores may omit these updates; Sessions then reload the projection and return
structured storage errors when that reload fails.

Each workspace has a disposable `session-index.json` containing the bounded
picker text and optional parent path for every persisted session. Session file
mtimes provide recent-activity ordering. First persistence, session naming,
fork creation, and lazy repair merge index entries under a cross-process lock
and replace the index atomically. Missing and malformed indexes are rebuilt
from the authoritative Pi session files when sessions are listed. Ordinary
conversation entries only append to their session files. Existing session
reads and appends share a per-file lock so readers cannot observe a partial
append.

Workspace-scoped settings, input history, and sessions are stored beneath a
hash of the canonical working directory. Workspace-settings updates and
input-history additions reload and merge under their file locks.

`lua/neoagent/file_lock.lua` owns the reusable cross-process protocol for these
persistence layers. It creates private token-bearing lock files exclusively,
polls contention with bounded synchronous or cancellable asynchronous
acquisition, recovers stale leases, optionally refreshes long leases, validates
ownership on release, and runs protected callbacks with guaranteed cleanup.
The default timeout is 15 seconds, the poll interval is 50 milliseconds, and
the stale threshold is two minutes. Credential storage retains its public
30-second acquisition default and composes the same primitive.

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
- Provider Service binding, provider operation Runs, and bounded provider
  context
- Retryable turn replay and cancellable backoff
- Context compaction
- AGENTS.md and skill discovery

The Controller owns shared mutable state and composes focused internal modules.
The session lifecycle module creates, activates, resumes, branches, and forks
Sessions. The run lifecycle module launches interactions, consumes steering,
classifies transient failures, retries eligible turns, compacts context, and
finishes or cancels Runs. Context metrics and session choices remain focused
calculations.

Provider Services are shared per composition. A Controller binds the service
for its selected provider, publishes the bounded `context.provider` snapshot,
forwards Model events through an optional `service:on_event()` hook, and owns
one cancellable provider operation Run independent of the agent Run. A
provider without a service publishes `state = false` and an empty operations
list, so the console opens empty. `controller:destroy()` and the
`VimLeavePre` lifecycle release that Run and unsubscribe the service.

Its active toolset is a plain tools-and-executor pair that can be atomically
replaced while idle. Each Run snapshots that pair, so retries, continuations,
and tool calls share one selection. Provider retry metadata can declare
eligibility, delay, and a stricter attempt cap. Successful tool results carry
changed paths for unmodified-buffer refresh, and read-capable tools declare
skill-discovery metadata. The Controller publishes updates and feeds complete
active-conversation copies to optional tool state hooks after activation,
message changes, resume, forks, and branch changes. Model context projects the
latest compaction checkpoint before its retained suffix. Transcript snapshots
use the same projection, placing the compaction card before retained and later
messages while omitting the compacted prefix. A replay
removes a failed partial assistant message from the active branch before
continuing the interaction. A successful assistant `length` stop continues
once, compacting first when the context threshold is reached. Completion
transitions are guarded by one finalizer. An unexpected lifecycle error clears
the active Run and publishes a structured Controller failure with the
transition error:

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
- Owns provider console visibility and forwards provider context

The passive View consumes Controller snapshots and updates and invokes callbacks
supplied by the Window. Its replaceable interface keeps presentation independent
from the model and agent loop. The Window injects an explicit Renderer into the
bundled View. Renderer methods receive copied semantic blocks and dialogs with
bounded layout context, then return lines, highlights, line backgrounds, and
presentation metadata. These inputs contain no buffers, windows, namespaces,
extmarks, mutable View state, execution callbacks, or dialog-response
callbacks. The optional tool value contains its name and semantic `render`
callback. The View validates each result and materializes it through Neovim
resources. Each rendered block owns its range and decoration extmarks;
incremental redraw replaces those marks and lets neighboring range anchors
track line shifts. Transcript cards clip lines at the current visible width by
default and rebuild after layout changes; configured card wrapping presents
their complete lines. The Window supplies a tool resolver, so a bundled
Renderer can consume an optional semantic renderer carried by the active tool
without recognizing tool names. The View can omit thinking blocks while the
Controller and Session retain complete messages.

The Renderer also presents transient steering status, active-card focus
decorations, semantic dialogs, and the optional provider console. Provider
snapshots contain presentation-neutral dashboard blocks. The Renderer
determines prompt text, action labels, and floating titles while the View owns
dialog buffers, windows, mappings, focus, transcript copying, and response
routing. An optional `render_provider(snapshot, opts)` method returns console
content, a title, and selectable operation rows. The View owns the provider
buffer and window, arrow navigation, selection routing, and close behavior.

Pi and Codex are bundled Renderer values assembled from a shared private layout
engine and their own card chrome. Codex is the default. Pi uses its fixed user
shade plus shaded tool and compaction cards. Codex derives user-card shading
from the editor background with Codex's light and dark blend ratios,
uses transparent tool and compaction cards, prefixes tool headings with a
bullet, and places horizontal rules against the tool side of tool/prose group
boundaries with one spacer on the prose side. Codex shell summaries preserve
command newlines, clip command and output rows, and bound each group
independently. Codex read, grep, find, and shell
details use the normal foreground as their base, and shell summaries and
details preserve parsed ANSI spans. A Window can replace the Renderer on its
live View and re-render the complete transcript from the same blocks.
The Renderer also selects an inline details hint for one-line Codex tool cards.
Multiline Codex tool outlines continue from the visible heading. Their bottom
edge occupies a following semantic group separator when present and otherwise
occupies the card's structural trailing spacing row. Other cards use the
Unicode focus outline. The View resolves the card beneath the focused
transcript cursor, provides count-aware previous and next card motions across
the transcript and an open details window, draws focus decoration in a
presentation namespace, and owns the read-only floating details buffer and
window.
Codex Write presentations and expanded Read cards identify their source range
and target path. The View detects each target filetype and includes its Neovim
syntax inside the contained transcript or details range, preserving the
surrounding tool presentation. Included filetypes do not change the buffer's
syntax sync, so comment and string patterns outside a source range cannot
recolor surrounding cards.

An optional dialog source lets an executor inject a lifetime-scoped
`ctx.dialog` capability and publish bounded asynchronous requests to a Window.
Requests select transcript or floating placement, provide their own actions,
and may collect editable text. An optional Controller name scopes presentation
to that Controller; `dialog.wrap()` derives this scope from an agent execution
context when the request omits it. The Window retains the unresolved request
while another Controller is active. The Window owns presenter attachment and
teardown. The Renderer formats the semantic request for its transcript or
floating surface. The View copies the transcript when required, creates buffers
and windows, installs mappings, and routes semantic action IDs. The source
resolves requests in FIFO order and cancels pending requests when its presenter
detaches.

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
`:NeoagentProvider` toggles the provider console, runs a named operation, or
cancels the active provider operation with a bang.

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
