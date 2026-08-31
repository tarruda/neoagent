# Neoagent architecture

Neoagent is built from plain Lua values with explicit dependencies. The Agent
Loop can run without Neovim configuration, persistence, or UI; the bundled
plugin adds those pieces as higher-level compositions.

```text
Neovim commands
      │
      ▼
Neoagent Applet
  ├── Profiles
  ├── retained unbound Profile Applets
  ├── Agent switcher Applet
  ├── authentication and shared provider runtimes
  ├── Provider Shell ──► View ──► Applet
  └── Agent
       ├── Agent Applet ──► View ──► Applet
       ├── Workspace and resources
       ├── Session ──► append-only JSONL tree
       ├── model, retry, compaction
       └── chat.run()
            └── agent_loop.run()
                 ├── Model:stream() ──► API ──► transport
                 └── execute_tool() ──► Tool.execute()
```

## Core

The reusable core consists of:

- `neoagent.async`, which provides cancellable coroutine-based Runs.
- `neoagent.transport.*`, which handles curl and bounded SSE parsing.
- `neoagent.api.*`, which translates messages and streaming events for each
  provider protocol.
- `neoagent.agent_loop`, which runs the model and tool loop.

A Model is any value implementing:

```lua
local run = model:stream({
  messages = messages,
  tools = schemas,
  on_event = on_event,
  on_done = on_done,
})
```

The call returns a cancellable Run. `agent_loop.run()` receives its Model,
messages, tools, executor, context, and steering callback explicitly. It
copies the input messages, streams an assistant turn, executes tool calls, and
repeats until the model finishes or the Run is cancelled.

Core modules do not import configuration, Sessions, storage, Workspace,
Agents, bundled tools, or UI. Cancellation propagates through Models,
tools, and nested Runs and completes once. Partial assistant output remains
available when a request fails or is cancelled.

## Models, providers, and authentication

`neoagent.registry` composes built-in provider definitions with user
configuration. Each provider definition carries its API connection,
authentication method, catalog definition, exact-ID Model configuration, and
optional Provider Service constructor. `neoagent.provider_runtimes` materializes
one plain runtime per configured provider:

```lua
{
  id = provider_id,
  definition = provider_definition,
  catalog = model_catalog,
  service = provider_service,
}
```

Every runtime owns one `ModelCatalog`. Construction restores sparse discovery
state synchronously and builds an effective snapshot before authentication or
network work. `start()` refreshes missing or expired state and schedules future
validation. Remote catalogs use a fourteen-day TTL; the local router catalog
uses five minutes. The normal composition persists strict version-1 discovery
records under `stdpath("state") .. "/neoagent/model-catalog"`.

Each candidate inventory is built from normalized discoveries and configured
exact-ID upserts, followed by the provider's bundled and configured
`transform_model` callbacks, exact-ID overlays and removals, and complete Model
validation. Successful discovery produces an effective inventory containing at
least one Model after transformations, overlays, and removals. An empty
effective inventory is a refresh error that preserves the current snapshot,
validator, and persisted record. Empty persisted discovery records are ignored
during restoration so the packaged or configured fallback becomes active and
stale. Explicit provider operations may publish an empty inventory.
`neoagent.model_rules` expresses ordered family patterns, while
`neoagent.model_efforts` builds request-option profiles for provider thinking
protocols. Publication is atomic and revisioned. Catalog snapshots are owned
copies, and resolved Models remain independent from later revisions.

`neoagent.models` uses catalog snapshots as the inventory for both selection
and resolution. Open selectors subscribe to catalog revisions and preserve
their query, selected item identity, and focus as choices change. Health and
the Provider Shell read the same snapshots. Rich sources are authoritative for
the bounded capabilities they report. Family transforms enrich providers whose
discovery sources return only IDs.

The built-in adapters support Anthropic Messages, OpenAI-compatible Chat
Completions, OpenAI Responses, and Codex Responses.

Providers, models, and individual calls may supply `request_opts`. These layers
merge across `url`, `headers`, and `body`. Thinking levels are model-declared
request-option layers selected by Agents. Models also declare accepted
input modalities. An adapter replaces unsupported images in a request copy
with a text placeholder while the Session keeps the original content.

Authentication wraps a Model at stream time. Login methods and credential
stores are injected values, which keeps OAuth flows separate from API codecs
and UI. Credential writes, refreshes, and deletion are serialized and atomic.
Provider IDs resolve their configured login method, so related compositions
can share one stored credential.
Provider state and diagnostics contain bounded, secret-free data. Each runtime
carries its upper-layer reporter through Model resolution. A failing Codex
diagnostic sink reports one warning through that boundary.

Login interactions cross the injected Presenter boundary. Browser-callback
events open their authorization URI and publish a managed waiting notice.
Device-code events publish a managed notice containing the verification URI
and code, leaving navigation with the user. Authentication owns each notice
Run through login completion, cancellation, or destruction; dismissing the
notice leaves the authorization operation active.

A Provider Service supplies live management status, provider-scoped
operations, optional Model wrapping, and provider events. Services are shared
within a composition and injected into Agents for wrapping, events, and
model-use leases. Runtime coordination is keyed by the concrete service value.
Model and compaction Runs acquire shared-use leases, while mutating operations
acquire exclusive access across every Agent using that service.

The top-level Neoagent Applet owns one Provider Shell alongside the shared
provider runtimes and credential manager. The shell owns provider selection,
authentication presentation, operation progress and cancellation, and one
standalone View. It is usable with zero Agents, and its lifecycle is independent
of Agent and Session lifecycles. Services publish semantic state; the Provider
Pane composes it into content Tree nodes.

The shell attaches its owned Presenter to this Applet. Selection and
confirmation snapshots become an action submenu; input and notice snapshots
become modal presentation Panes. The same Presenter resolves choices, input,
cancellation, notifications, and URI effects. Secret input uses a sensitive
transient Pane with concealed text. The selected catalog snapshot supplies
model count, source, freshness, and bounded errors. Every provider exposes the
standard `neoagent.catalog.refresh` action independently from service-owned
management operations.

The shell derives authentication actions from credential state. Provider
operations receive provider configuration, raw arguments, authentication
resolution, and interaction helpers. Their contract contains no selected Model
or Agent-running state.

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
handling. The Agent Loop contains no approval or permission policy.

The Agent Loop validates model-produced argument objects before they enter
`execute_tool`. Local validation covers the JSON Schema vocabulary used by
bundled Tools: `type`, `enum`, `required`, `properties`,
`additionalProperties`, `items`, `minItems`, and `maxItems`. Mismatches become
one bounded error result with deterministic paths for every reported issue.
Tool implementations enforce domain semantics beyond that structural
vocabulary.

Bundled file and process tools use optional `ctx.fs` and `ctx.process`
capabilities. Direct calls use the host implementations. A sandbox or other
decorator replaces those capabilities for one invocation. File tools read and
write disk; loaded buffers are refreshed only after a successful mutation and
only when they have no local changes.

Tools may define two higher-level hooks:

- `on_messages(messages, ctx)` derives state from a copied active conversation.
- `render(opts)` returns semantic presentation data for the active Renderer.

The Agent calls `on_messages`; direct `agent_loop.run()` remains
Session-independent. Its Agent Applet resolves tool presentation,
and Neoagent components convert the selected semantic result into Pane content
Tree nodes before passing it to the reusable Pane compiler.

## Resources and runtime policy

AGENTS.md and skill discovery live above the reusable core. Agents add
discovered resources to the system prompt when configured, and skills are
loaded on demand through file-reading tools.

Workspace trust is an optional policy used by the built-in Neo composition. It
checks the canonical workspace before project resources are loaded or a
tool-capable Run starts. Persistent decisions are stored atomically outside
user configuration. Custom Agents receive trust policy only through
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
an optional injected store. Session ID, opaque tool-hook identity, Workspace,
and header metadata are fixed at construction. `snapshot()` returns a validated
copy of the complete journal and active leaf for derivation.

The bundled store uses one append-only JSONL tree format. The active path is
projected into model context while the full tree retains branches, linked
forks, model state, and compaction entries. Empty Sessions create no
files. Stores validate the full tree when opening and validate new entries
before appending. Accepting a user message appends any changed model and
thinking state with that message under one Session lock. A model selection
remains live Agent state until a message uses it.

Workspace settings, input history, session indexes, and provider state use
atomic writes and cross-process file locks. Session files remain authoritative;
disposable indexes can be rebuilt from them. Credential and state directories
use private permissions. The first accepted message in a new Session commits
its model as the Workspace/Profile preference. Resumed Sessions read their
model from the active Session branch and leave that Workspace preference
unchanged.

`neoagent.profile_sessions` composes registered Profiles with ordinary
Sessions and storage. It records the stable Profile ID under
`metadata.neoagent.profileId`, preserves unrelated metadata, and projects the
binding into the disposable Workspace index. `storage.derive()` validates and
atomically publishes a complete new header-and-tree document before indexing
it. Copies keep the full journal and active leaf and record one-hop source
provenance. Publication makes a persisted derivation authoritative. A later
Agent construction or activation failure returns the created Session path so
the user can resume it. Generic Session and storage constructors carry no
Profile policy.

Compaction receives the Session path and Model explicitly. A successful summary
becomes a tree entry and replaces the compacted prefix in model context. The
Agent owns automatic thresholds, overflow recovery, and continuation after
a length-limited response.

## Agent

`neoagent.agent` is the main orchestration boundary. An Agent owns:

- configuration, Workspace, model, and thinking selection;
- its Session, store, active toolset, and current Run;
- retry, steering, and compaction state;
- independent dialogs, semantic presentation, and attention;
- provider-runtime bindings for the selected Model's catalog revisions,
  service wrapper, events, and shared-use lease;
- AGENTS.md and skill discovery.

Each Run snapshots its toolset. Steering enters the core through the explicit
`get_steering_messages` callback and is consumed between assistant/tool turns.
Retries remove the failed partial response from the active branch before
replaying, while the Session retains it as inactive history.

Agents have opaque runtime IDs, Profile IDs, and independent display
labels. They publish transcript snapshots, bounded activity, and four update
types: `messages`, `context`, `event`, and `finish`. Consumers observe this
interface without owning the Agent Loop. A bundled Agent owns one
Agent Applet; a direct Agent may be headless. Destruction cancels active
work and releases its Applet and provider subscriptions.

## Profiles and Applets

Neo and Chat are ordered Profile recipes. A Profile closes over explicit shared
resources and constructs a ProfileDraft or a configured Agent. Neo composes
coding tools, trust, resources, and the switchable
sandbox executor. Chat composes a tool-free conversation.

`setup()` creates the top-level Neoagent Applet, its Profiles, shared provider
runtimes and credential resources, and one Provider Shell. It creates zero
Agents. Opening New retains one ProfileDraft for that Profile and canonical
Workspace. The ProfileDraft owns its retained Agent Applet, RequestSelection,
staged options, and explicit draft/provisional/bound/destroyed typestate. The
first accepted message constructs an Agent, binds the exact draft Applet
permanently, registers both values atomically, and submits the retained message.
Model and preparation failures restore the exact ProfileDraft. Workspace trust
owns an accepted pending submission and its exact retry. Selecting a persisted
Session is an immediate construction boundary.

Each ProfileDraft owns copied model, thinking, sandbox, and UI choices. Its
RequestSelection composes configured and Workspace defaults with the live
resolved Model and thinking choice. The draft initializes Profile-scoped
choices and persistent input history from the canonical Workspace. Model
selection falls through the Profile configuration to the first available
provider/model. The Profile remains a static recipe, and the constructed Agent
receives the draft's exact option copy. Draft model and thinking mutations
resolve the Profile's concrete Model first and expose only its declared
thinking levels.

The top-level Neoagent Applet owns every bundled Agent, foreground
selection, retained `(Profile ID, canonical Workspace)` drafts, live Session
claims, the Agent switcher, and the Provider Shell. One live Agent may claim a
Session ID. New, resume, fork, and copy construct Agents at this boundary;
branching moves within the Session owned by an existing Agent.
Resume resolves the Profile and Workspace from the Session header and selects
an existing claim owner when present. Fork creates a same-Profile Agent. Copy
selects a target Profile, preserves the source Agent, and applies the target
recipe to future turns.

At most one Agent Applet is open. Selection closes the previous
Applet and opens the selected one; closing changes presentation state and
leaves the Agent running. Each Applet keeps its own draft, transcript,
dialogs, focus, scrolling, and pending attention. The Provider Shell has its
own Applet lifecycle and selected-provider state.

The principal ownership scopes are:

| Value/state | Owner | Share scope | Mutation rule |
| --- | --- | --- | --- |
| Provider definition | registry composition | one top-level or direct composition | immutable configuration value |
| Model catalog | concrete `ModelCatalog` | every consumer of one provider runtime | atomic revisioned snapshot publication |
| Provider Service semantic state | provider composition | top-level composition | service serializes publication |
| Provider Service runtime | concrete Provider Service | every Agent and Provider Shell using the service | shared model leases and exclusive mutating operations |
| Provider operation presentation | Provider Shell | top-level composition | one active shell action |
| Profile draft | `ProfileDraft` | top-level Applet | explicit draft, provisional, bound, and destroyed typestates |
| Live Session claim | top-level Applet | process composition | one live Agent per Session ID |
| Agent Session identity | Agent | Agent lifetime | fixed at construction |
| Agent Applet | Agent | one Agent | permanent binding |
| Agent View/Applet | Agent Applet | one presentation | closes and reopens with its owner |
| Provider Shell View/Applet | Provider Shell | top-level composition | closes and reopens with the shell |
| Live request selection | `RequestSelection` | Agent or Profile draft | mutable between accepted messages |
| Journaled request selection | Session active branch | Session branch | changes with an accepted message |
| Workspace preference | `(Workspace, Profile ID)` settings | future Sessions in that scope | updates on the first accepted message of a new Session |

The switcher is a transient selection Applet. It receives copied Agent
summaries and owns one visible-only animation timer. A background request
remains in its owning interaction source until the Agent is selected or a
caller resolves it programmatically.

## Agent Applet, View, Applet, Pane, and Renderer

The built-in View constructor is `require("neoagent.ui").new`. Each Agent Applet
owns one View. A direct headless Agent publishes copied semantic snapshots for a
caller-owned UI, and native Renderer values customize transcript presentation.

The Agent View consumes its Agent's messages, context, events, and presentation
requests, updates semantic component state, and submits one host-neutral
Applet layout. Its complete immutable ViewState contains every
topology-affecting value for one generation; layout is a pure mapping from that
state and the bounded Applet environment. Transcript documents and editable
text remain in their owning Panes. Model selection, tools, and Session branch
operations remain Agent operations. Session creation and Agent publication
remain top-level Applet operations.
Neovim buffers, windows, tabs, focus, scrolling, mappings, extmarks, and modes
remain owned by the Applet package.

`require("applet")` is the complete public package entry point. It publishes the
concrete Applet, Pane, layout, Host, Theme, InteractionDomain, ImageSystem,
presentation, Presenter, and host-effect values consumed by Neoagent. Compiler
caches, reconciler, Surface, Scene, namespace, and generation representations
remain package implementation details.

Applet is the top-level presentation composition. It owns one Host lifecycle,
the mounted Pane set, layout, focus, buffers, windows, observation, and atomic
publication. Its layout contains a main Pane topology, nested binding scopes,
focus intent, and modal or non-modal Layers. Host descriptors select either
coordinated floating windows or a dedicated tabpage with native splits. Both
Host drivers consume the same pure Frame and use floating windows for Layers.

A Pane is one buffer's semantic content and runtime. Each transcript, composer,
dialog, details, provider selector, or provider detail component owns one Pane
and mounts that same value in its owning Applet. Managed transcript and
Provider Shell Panes render documents; composer and text-entry Panes preserve
native editing. A component or Renderer returns a Pane content Tree. Pane
compiles and reconciles that Tree against the buffer and window supplied by its
Applet.

The shared InteractionDomain commits Applet Frame changes before Pane content
changes, defers unsafe updates, and reconciles image overlap across the
complete composition. Neoagent uses Pane methods for text, cursor, targets,
scrolling, focus, and completion.
Semantic target movement resolves the containing candidate first. A cursor in
free document space uses candidate points to find the preceding or following
target, so document boundaries propagate to the owning component's focus
policy.
Connected Panes activate the Domain key observer. Closing an Applet disconnects
its Panes and releases that observer when the final active participant leaves.
Applet window, tab, option, mode, resize, and scroll observers follow the live
Host epoch. Closed retained buffers keep only buffer-local unload, delete, and
wipeout observation until remount or destruction.
The Applet mode policy classifies active Insert, Replace, and temporary Normal
editing intent as one retained Insert state. Mapping dispatch retains its
originating editing intent while actions move focus or open another Applet,
then applies the final focused Pane policy at the callback boundary. A managed
Pane requests Normal mode from the same policy during native focus and
InsertEnter events.
Focus of an existing mounted Pane uses its live native cursor and viewport.
Applet snapshots restore cursor and viewport at Host and Frame mount
transitions.

`Applet.presentation` turns semantic input requests into editable Panes,
semantic selection requests into a two-Pane picker, and notice requests into
managed Panes. A modal Applet Layer stacks the editable picker filter Pane
above its managed results Pane and sizes each presentation from measured
content. Notices use a focused read-only Pane with direct cancellation
bindings. `Applet.Presenter` supplies the default semantic host fallback for
callers without a View. Notifications, URI opening, file refresh, process-exit
observation, display measurement, and Theme color derivation also cross
package-owned presentation or host-effect boundaries.

A Pane content Tree can compose fixed two-dimensional containers.
A container owns an inner clipping rectangle, an optional box model, one
ordinary child, and absolute child containers with stable z-order. The
compiler resolves their visible cells into one Layout and projects text,
decorations, interaction rectangles, source ranges, and image viewports through
the same composition.

Compiled document roots are retained by immutable table identity. Updates to
chrome, view intent, and editable state reuse the retained Layout while equal
layout constraints, Theme generation, and image generation preserve its
meaning. Transcript snapshots retain copied semantic blocks and replace only
dirty block copies, so status animation and focus changes remain independent
of conversation length.

Compiled Layouts are immutable values. Pane compares their lines and
metadata exactly, with retained tables and Lua strings providing constant-cost
equality for unchanged values. Reconciliation consumes one categorized change
set and applies only the affected buffer content, decorations, mappings,
images, source annotations, virtual text, chrome, and view state.

Pane schedules automatic commits through its InteractionDomain. An optional
frame interval coalesces frequent state and content Tree submissions while
retaining the newest pending generation. Eager submissions and native
viewport, surface, Theme, and image-resource invalidations request the next
safe domain turn; explicit flushes commit synchronously. Complete image frames
remain available to reconciliation.

The View owns one optional ImageSystem shared by transcript and details Panes.
ImageSystem composes bounded cancellable PNG loading with one explicit
persistent-placement backend. The bundled View selects Kitty. ImageSystem
validates loaded PNG resources, owns the bounded set of referenced resources
and one current presentation per Pane, and publishes preparation generations.
The default file loader serializes
open, inspection, read, and close operations. Cancellation suppresses its
completion and closes the descriptor when active I/O settles.

Pane owns semantic image slots and derives one complete presentation from the
current Layout, viewport, screen position, and canonical union of higher
z-index floating rectangles. The presentation maps slot keys to source
identities and includes every exposed placement fragment. ImageSystem resolves
the owned resources before calling the backend. The backend accepts the
complete owner presentation synchronously after the Pane transaction has
resolved. Compilation uses the presented source while a desired revision
prepares. Desired and presented references retain only the resources they use;
failed Pane commits keep the current presentation and release their candidate.

Backends are direct Lua values with an `available` boolean and
`cell_dimensions`, `replace`, `clear`, `release`, `redraw`, and `destroy`
operations. They receive validated PNG resources, source viewports, fixed cell
rectangles, and screen positions. An optional error handler reports asynchronous
transport failures to ImageSystem, which makes the complete image presentation
unavailable.

Pane and Applet borrow immutable state and Tree submissions. Callers retain
ownership and submit a new value, affected subtree, or revision for each
semantic change. Transaction checkpoints, observations, and error payloads
are owned copies. Current target and focus intent tokens are constant-sized.
Each Theme value owns a distinct bounded derived-highlight namespace.

Agent publications carry monotonically increasing revisions and copy each
semantic update per listener. The Agent Applet retains the newest semantic
snapshot for View hydration and rejects stale publications. Async Runs retain
the newest 32 callback diagnostics with bounded sanitized messages
independently from their completion result. An injected reporter receives a
copied neutral record. Unreported child diagnostics flow to the awaiting
parent, and owning compositions translate records into presentation policy.

Kitty uploads each prepared PNG through bounded direct chunks, shares one
content upload across owner presentations, and assigns a persistent protocol
placement to each visible fragment. A replacement uploads and places every
candidate fragment before deleting the prior owner's placements. Queued
revisions for one owner coalesce to the newest complete presentation. Kitty
deletes unplaced image data and uploads it again when the resource becomes
visible. Surface redraws reapply current placements in screen order. A
terminal output failure makes the backend unavailable.

Active multiplexer state determines the transport envelope. Kitty orders
protocol output after Neovim text through a serialized UI API or the built-in
TUI's synchronous acknowledgement barrier. Image presentation fails closed
when neither ordered path is available. A terminal output failure destroys the
backend before ImageSystem releases its prepared resources and presentations.

Pane content Trees with unavailable resources retain their compact fallback
height. Image geometry remains native content Tree metadata.

The Transcript assigns byte images a process-unique scope for its complete
message collection. Appends retain that scope so transcript and details Panes
share prepared resources. Replacing the collection rotates the scope
so a shared ImageSystem cannot alias equal block keys from different
conversations. Presentation revisions keep that image identity stable, and
Pane retains equal resolved screen placements across text-only reconciliation.
Transient tool results remain copied in the owning Transcript block's `update`
field. Bundled Renderers select image content from the final message, active
update, or direct block in that order. Stable semantic image IDs map each
revision to one Pane slot, so transcript and details consume one prepared
resource through independent placements. Tool completion clears the update;
an equal final image retains the resource, while a text-only final result
removes the slot. Chat journals only `message_end` values, which keeps frame
sequences outside Session storage, model context, and compaction input.

Every bundled Renderer receives copied semantic blocks and bounded layout
context, then returns a native Pane content Tree node from `render_block()` and
`render_details()`. Each call also receives the opaque continuation returned
by the previous call for that block and surface. The bundled Renderers retain
incremental Markdown documents and completed region Trees through this value.
A Renderer also supplies an Applet Theme. A custom native Renderer can replace
a bundled Renderer without changing Session content or Agent state.

Dialogs and provider screens use the same Tree primitives. An executor
publishes a semantic request, a component composes its content and bindings,
and the active Pane owns interaction and response routing. Surfaces retain
buffers while their host windows are recreated.

## Public composition

`require("neoagent").setup()` creates the command-facing Neoagent Applet with
Neo and Chat Profile recipes and zero Agents. `neoagent.new(opts, runtime)`
creates an independent Agent and composes its provider runtimes when the caller
does not inject them.
An explicit `runtime.runtimes` shares caller-owned provider runtimes;
`runtime.session` and `runtime.workspace` bind direct compositions to
caller-owned values.
`neoagent.default()` returns the active or last foreground Agent and returns
nil until an interactive message or Session selection constructs one.

## Request flow

1. An Agent Applet accepts composer input.
2. An unbound Profile Applet atomically constructs and binds its Agent.
3. The Agent checks trust and resolves its Model, resources, and toolset within
   its bound Workspace and Session.
4. `chat.run()` records the user message with its model state and calls
   `agent_loop.run()`.
5. A new Session commits that accepted model and thinking selection as its
   Workspace/Profile preference.
6. Model events flow through Agent publications to its permanent View.
7. Tool calls pass through the configured executor and return as tool-result
   messages.
8. Completed messages are appended to the Session and optional store.
9. Cancellation propagates through the active Model, tool, and nested Runs.
