# Neoagent architecture

Neoagent's core is a Model API and Agent Loop. Sessions, tools, persistence,
Workspace policy, and UI are optional compositions. Public APIs and
configuration are documented in [neoagent.txt](doc/neoagent.txt); the UI package
has its own [Applet reference](doc/applet.txt).

```text
Neoagent Applet
  ├── Profile drafts and Agent selection
  ├── shared provider runtimes
  ├── Provider Shell ──► View ──► Applet
  └── Agent
       ├── Agent Applet ──► View ──► Applet
       ├── Workspace and resources
       ├── Session ──► optional store
       └── chat ──► Agent Loop
                     ├── Model ──► API adapter ──► transport
                     └── execute_tool ──► Tool
```

## Core and execution

The reusable core consists of `neoagent.async`, `neoagent.transport.*`,
`neoagent.api.*`, `neoagent.semantic_message`, and `neoagent.agent_loop`.
These modules must not import configuration, Sessions, storage, Workspace,
bundled tools, Agents, or UI.

A Model supplies identity, input modalities, and `stream(opts)`. API adapters
encode requests, decode provider streams, and recover meaningful partial
output. They adapt images and provider-specific metadata in request copies;
the original conversation remains unchanged.

The Agent Loop receives its Model, messages, toolset, executor, context,
steering source, and commit function explicitly. It validates the turn before
starting. Assistant, tool-result, and steering messages commit before dependent
tool execution, model requests, or final observation.

Runs own cancellation and completion. Cancellation propagates to child Runs
and active effects; resource-producing awaits transfer or dispose their values
once. Each Run settles once. Callback failures go to the diagnostic reporter
without replacing the primary result.

## Agents and the top-level composition

An Agent has fixed Profile, Workspace, and Session identity. It owns model and
thinking selection, tools, steering, dialogs, and one activity Run. That Run
covers preparation, compaction, interaction, retry, continuation, and provider
use. Destruction cancels activity and prevents new work; owned runtimes are
disposed after pending work settles.

A Profile is an Agent recipe. Neo supplies coding tools and Workspace policy;
Chat supplies a tool-free conversation. `neoagent.new()` constructs an
independent Agent. `neoagent.setup()` registers Profiles in the command-facing
Neoagent Applet and creates Agents when work begins. Headless Agents do not
load UI modules.

The top-level Applet owns Profile drafts, Agent registration and selection,
live Session claims, shared provider runtimes, and the Provider Shell. It keeps
one live Agent claim per Session ID. Direct Agents are independent of this
composition.

Drafts are keyed by Profile and canonical Workspace. They retain input and
request choices until a message is accepted. Acceptance binds the new Agent;
failure before acceptance leaves the draft available for retry. A resumed
Agent restores request choices from its Session.

| Value | Owner | Lifetime |
| --- | --- | --- |
| Provider runtimes and Authentication | top-level or direct Agent composition | until owner destruction and pending use settles |
| Provider Shell | top-level Applet | independent of Agent selection |
| Profile draft | top-level Applet | until binding, replacement, or destruction |
| Session and activity | Agent | bound to that Agent |
| Agent Applet and View | Agent | retained across UI close and reopen |
| Pane | UI component | until component or owning mount destruction |
| ImageSystem | View | shared by its image-capable Panes |

Closing an Agent's visible UI leaves its activity running. Agent publications
are copied, revisioned values. Durable submission acceptance is a separate
event so a composer clears only input that the Session accepted.

## Provider runtimes

Provider definitions describe API connections, Authentication methods, model
catalogs, and optional Provider Services. Each runtime shares concrete
credentials, catalog, service, and transport values across its consumers.
Provider operations receive provider-scoped state, not Agent state.

ModelCatalog owns selectable inventory and publishes complete revisioned
snapshots. Selection and resolution use the same snapshot; resolved Models
remain independent of later catalog changes. Discovery-backed inventory
combines source results with explicit additions, then applies model overrides.
The cache stores discoveries and input fingerprints, excluding credentials and
resolved Models. Account-scoped caches use hashed credential identities.

Authentication owns login, refresh, logout, and stream-time Model wrapping.
Providers may bind separate methods for inference and management scopes.
Credential changes invalidate the affected catalog identity. Credentials use
private atomic storage and never enter provider state or diagnostics.

Provider Service coordination is keyed by the shared Service value. Models,
catalog requests, compaction, and non-mutating operations may share use.
Mutating operations require exclusive use. Login and logout coordinate all
Services using the affected Authentication method. Retired Services are
destroyed after leases and operations finish.

The Provider Shell presents authentication, catalogs, Service state, and
operations independently of Agent selection. Provider diagnostics exclude
HTTP bodies and conversation content.

## Tools and Workspace policy

Tools are plain tables. The Agent Loop validates arguments before calling
`execute_tool(tool, arguments, ctx)`, which owns approval, logging, sandboxing,
and other execution policy. The core contains no built-in permission policy.

Bundled tools route file and process effects through optional context
capabilities. File mutations verify regular-file targets, reject symbolic
links, and publish through same-directory replacement. The interactive
composition refreshes a loaded buffer only after success and only when that
buffer has no local edits.

Tool presentation and message hooks belong to the Agent layer. Render hooks
produce semantic data; they have no dependency on the Agent Loop.

The Agent adds configured AGENTS.md and skill resources to its prompt.
Workspace trust guards project resource loading and tool-capable execution in
Neo. Sandboxing decorates the executor with restricted capabilities;
escalation supplies host capabilities for one approved call.

## Sessions and persistence

A Session is a tool-free owner of messages and an active path through a tree.
It works in memory or with an injected store. The tree retains branches,
derivations, request selections, and compaction entries. Model context is a
projection of that path.

The bundled store is append-only JSONL. Session documents are authoritative;
Workspace indexes are rebuildable discovery data. Derivations publish their
document before Agent activation, allowing recovery when activation fails.
No file is created for an empty Session.

Persistence uses private files, verified atomic publication, and cross-process
locks. Uncertain write outcomes make the affected Store reject later
mutations. Opening a Session can recover an incomplete final record before
validating the tree.

Accepted user messages record model and thinking choices. Resuming or
branching restores choices from the selected path. Workspace settings store
Profile preferences plus shared UI position and input history. Only the first
accepted message of a new Session updates its Profile's Workspace preference.

Compaction receives a Session path and Model and returns a summary for the
compacted prefix. The Agent owns thresholds, overflow recovery, and
continuation. The Session retains the full tree.

## Presentation

The public `applet` package depends only on Neovim and its own modules.

- Views consume copied semantic state and choose layouts.
- Renderers produce Pane content Trees.
- Panes own buffer content, mappings, cursor interaction, and scrolling.
- Applets own Hosts, layout, buffers, windows, and focus.
- InteractionDomain defers unsafe updates during native editing operations.

State and Tree submissions are immutable borrowed values. Keys and revisions
identify reusable content. Publication is transactional: compilation or native
mutation failure preserves the previous committed presentation. Applet owns
native handles; components own semantic state.

Semantic presentation can use a fallback host without a View. Sensitive input
uses transient mounts whose buffers are cleared and disposed on unmount.

A View's ImageSystem owns prepared PNG resources and replaces each Pane's
complete visible placement set through a backend. Backend failure clears
placements and leaves text fallbacks.

## HTTP recording

Recording observes the provider transport. It cannot change provider results.
Exchanges carry request correlation, protocol data, timing, and terminal
results; Workspace/Session recordings and shared-provider recordings have
separate retention scopes.

Publication precedes pruning. A failed finalization preserves the previous
completed recording and current staging evidence.

Sanitization masks protocol credentials and Authentication-classified
sensitive response bodies. Model and ordinary provider bodies retain their
content. Recordings use private storage; failures emit content-free
diagnostics. Storage, formats, and sharing precautions are documented in
`:help neoagent-recording`.
