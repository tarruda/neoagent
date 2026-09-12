# Neoagent architecture

Neoagent's core is a Model API and Agent Loop. Sessions, tools, persistence,
Workspace policy, provider management, and UI are optional compositions.
Public APIs and configuration are documented in
[neoagent.txt](doc/neoagent.txt); the UI package has its own
[Applet reference](doc/applet.txt).

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

The reusable core contains cancellable Runs, transports, API adapters,
semantic messages, file interfaces, and the Agent Loop. It has no dependency
on configuration, Sessions, storage, Workspace policy, bundled tools, Agents,
or UI.

A Model owns its identity and capabilities and exposes `stream(opts)`. API
adapters translate between semantic messages and provider protocols. Image
data reaches an adapter through an explicit file reader, and request shaping
works on copies of conversation and request state.

The shared HTTP client owns protocol-independent JSON and SSE decoding. A byte
transport beneath it owns network I/O. API adapters, Authentication, catalogs,
Services, and file backends consume the HTTP client without depending on its
concrete transport.

The Agent Loop receives the Model, messages, tools, executor, context,
steering, and commit function as explicit dependencies. The message owner
commits authoritative state before the loop starts work that depends on it.
Cancellation propagates through Models, tools, child Runs, and provider use.

## Agents and the top-level composition

An Agent has fixed Profile, Workspace, and Session identity. It owns model and
thinking selection, tools, steering, dialogs, and one activity lifecycle.
Closing its UI does not transfer or end that ownership.

A Profile is an Agent recipe. Neo supplies coding tools and Workspace policy;
Chat supplies a tool-free conversation. `neoagent.new()` constructs an
independent Agent. `neoagent.setup()` registers Profiles with the command-facing
Neoagent Applet, which creates Agents when work begins. Headless Agents do not
load UI modules.

The top-level Applet owns Profile drafts, Agent registration and selection,
live Session claims, shared provider runtimes, and the Provider Shell. A draft
holds input and request choices until an accepted message binds a new Agent.
Direct Agents remain outside this composition.

| Value | Owner | Lifetime |
| --- | --- | --- |
| Provider runtimes and Authentication | top-level or direct Agent composition | until owner destruction and pending use settles |
| Provider Shell | top-level Applet | independent of Agent selection |
| Profile draft | top-level Applet | until binding, replacement, or destruction |
| Session and activity | Agent | bound to that Agent |
| Agent Applet and View | Agent | retained across UI close and reopen |
| Pane | UI component | until component or owning mount destruction |
| ImageSystem | View | shared by its image-capable Panes |

Agent publications are copied, revisioned values. The Session owns durable
submission acceptance; presentation code observes that event without becoming
the message owner.

## Provider runtimes

A provider definition composes API connections, Authentication methods, a
ModelCatalog, an optional Service, and transport. The owning top-level or direct
Agent composition may share one runtime among multiple consumers.

Shared provider operations receive provider-scoped state, not Agent state.
Per-Model request shaping is the boundary where copied Workspace, Agent, and
Session identity may enter a request. A Model resolved for an Agent keeps that
identity; standalone Session adapters supply Session identity per call.

ModelCatalog owns selectable inventory and publishes complete revisioned
snapshots. Authentication owns credentials and login, refresh, logout, and
Model wrapping. A Provider Service owns management state and operations.
Service and Authentication boundaries coordinate shared and exclusive provider
use.

Provider runtimes own remote file preparation and upload protocols. Sessions
retain local image bytes, while the workspace provider cache owns remote
references. A Workspace supplies file and cache capabilities explicitly;
semantic request state never owns either. Request-scoped preparation uses
Service leases independent of the calling Agent's lifecycle.

The Provider Shell presents Authentication, catalogs, and Service state. It is
owned by the top-level Applet and is independent of Agent selection.

## Tools and Workspace policy

Tools are plain values. The Agent Loop validates calls and delegates them to
`execute_tool(tool, arguments, ctx)`, which is the composition boundary for
approval, logging, sandboxing, and other execution policy.

Bundled tools receive file and process capabilities through their context.
Project instructions and skills are Agent inputs governed by Workspace trust.
Sandboxing and host escalation decorate tool execution without adding policy
to the Agent Loop.

Tool presentation and message hooks belong to the Agent layer. Render hooks
produce semantic data and do not depend on the Agent Loop.

## Sessions and persistence

A Session is a tool-free owner of messages and an active path through a
conversation tree. It can use memory or an injected store. Model context is a
projection of Session state.

Workspace storage owns Session documents, immutable attachment blobs, provider
mappings, and its rebuildable index. Sessions refer to attachments by content
identity rather than source path. Same-workspace derivations share Workspace
storage; cross-workspace derivations import retained attachments before the
new Session is published.

The top-level Applet owns derivation work until it can publish the resulting
Agent. Session and storage modules remain independent of Profiles and UI.

Compaction consumes a Session path and Model and returns a summary for a
prefix. The Agent owns compaction policy; the Session retains the complete
conversation tree.

## Presentation

The public `applet` package depends only on Neovim and its own modules.

- Views consume copied semantic state and choose layouts.
- Renderers produce Pane content Trees.
- Panes own buffer content and interaction.
- Applets own Hosts, native surfaces, layout, and focus.
- InteractionDomain coordinates publication with native editing.

State and Tree submissions are immutable borrowed values. Publication is
transactional: Applets own native mutations while components retain semantic
state. Semantic presentation may use a fallback host without a View.

A View receives the Session file reader separately from semantic messages.
Renderers produce resource descriptors, Panes request visible resources, and
the View's ImageSystem owns prepared images and backend presentation. The
Applet package has no dependency on Sessions or Workspace storage.

## HTTP recording

Recording observes the byte transport beneath the shared HTTP client. The
transport remains the owner of request results; recording failure cannot
change them.

Request context assigns exchanges to Workspace/Session or shared-provider
scopes. The recorder owns capture, retention, and storage. Each exchange owns
sanitization, while Authentication supplies response sensitivity
classification. User-visible formats and sharing precautions are documented in
`:help neoagent-recording`.
