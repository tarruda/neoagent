# Neoagent architecture

Neoagent is a composition of plain Lua values with explicit dependencies. The
Agent Loop can run without configuration, persistence, Workspace discovery,
bundled tools, or UI. The plugin entry point assembles those optional layers
for interactive use.

```text
Neovim commands
      │
      ▼
Neoagent Applet
  ├── Profiles and retained drafts
  ├── Agent switcher
  ├── shared provider runtimes
  ├── Provider Shell ──► View ──► Applet
  └── Agent
       ├── Agent Applet ──► View ──► Applet
       ├── Workspace and resources
       ├── Session ──► append-only store
       └── chat.run()
            └── agent_loop.run()
                 ├── Model:stream() ──► API ──► transport
                 └── execute_tool() ──► Tool.execute()
```

## Core

The reusable core consists of:

- `neoagent.async`, which provides cancellable coroutine-based Runs.
- `neoagent.transport.*`, which provides HTTP and bounded event-stream
  transport.
- `neoagent.api.*`, which translates semantic messages and provider events.
- `neoagent.semantic_message`, which validates the shared message vocabulary.
- `neoagent.agent_loop`, which runs model and tool turns.

A Model is a validated value with identity, declared input modalities, and a
`model:stream(opts)` method. Streaming returns a cancellable Run and reports
semantic events and one terminal result through named callbacks. Provider API
adapters are responsible for protocol encoding, stream decoding, and recovery
of meaningful partial output.

The Agent Loop receives its Model, copied messages, exact toolset, commit
command, executor, context, and steering source explicitly. It has no
configuration or Session dependency. Preparation validates the complete turn
before work starts. Generated assistant, tool-result, and steering messages
cross the commit command before any dependent tool or model turn begins.

Runs provide the common cancellation and completion boundary. Cancellation
propagates through child Runs and active effects, while completion callbacks
observe one settled result. Resource-producing awaits transfer or dispose their
value exactly once. Callback failures are isolated from the primary result and
flow through an injected diagnostic reporter.

Core modules do not import configuration, Sessions, storage, Workspace,
bundled tools, Agents, or UI.

## Models and provider runtimes

`neoagent.registry` combines built-in provider definitions with user
configuration. Each definition describes an API connection, authentication,
model catalog, exact model overrides, and an optional Provider Service.
`neoagent.provider_runtimes` materializes one runtime for each configured
provider and shares it across the interactive composition.

A provider runtime groups five concerns:

- ProviderCredentials resolves stored, configured, environment, optional, and
  absent credential state without publishing secret material.
- ModelCatalog owns the provider's selectable inventory and refresh lifecycle.
- Authentication performs login, refresh, logout, and Model wrapping.
- Provider Service supplies management state, operations, optional Model
  wrapping, and provider events.
- Transport carries provider HTTP and may be wrapped by the recorder.

Model catalogs publish complete revisioned snapshots. Discovery-backed sources
and explicit catalog additions own inventory membership; source-free catalogs
derive membership from packaged and configured models. Provider transforms add
family knowledge, catalog additions supply their base configuration, then exact
model configuration applies final overrides and removals. Model resolution and
model selection consume the same snapshot. A resolved Model is independent of
later catalog revisions.

Catalog persistence stores sparse provider discoveries and a fingerprint of
the inputs that determine them. Account-scoped fingerprints use a hashed
credential identity. Credentials and effective configured Models stay outside
the cache. A stale or unusable cache leaves the packaged fallback inventory
available while refresh owns the network work.

`request_opts` is the request customization boundary. Provider, model, and call
layers merge in that order across the URL, headers, and body. Thinking levels
are named model-owned request layers selected by an Agent or Profile draft.
Models declare whether they accept text, images, or both; API adapters replace
unsupported images in the request copy while the Session retains the original
content.

Authentication wraps Models at stream time and remains separate from API
codecs and presentation. A provider binds its primary inference method and may
bind independent methods to named Provider Service scopes. Each method owns one
credential record, login protocol, and request-option derivation. Credential
changes publish a method revision. Catalogs associated with the primary method
refresh after its credential identity changes. Browser authentication receives
credentials on a bounded loopback callback owned by Authentication.

Provider Service coordination is keyed by the concrete shared Service value.
Model, compaction, catalog, and non-mutating operation Runs may share use.
Mutating operations acquire exclusive use. Login and logout coordinate every
Service that shares their Authentication method. Retired runtimes destroy a
Service after its active leases and operations finish.

The Provider Shell owns provider selection, authentication interaction,
catalog refresh, Service operations, progress, and cancellation. It belongs to
the top-level composition and can run without an Agent or Session. Operations
receive provider-scoped state and interaction helpers, keeping Agent selection
out of the Provider Service contract.

## Tools and runtime policy

A Tool is a plain value containing a name, description, input schema, and
execute function. The Agent Loop validates model-produced arguments before
calling the configured executor.

`execute_tool(tool, arguments, ctx)` is the policy boundary for logging,
approval, sandboxing, and host effects. The Agent Loop contains no permission
policy. Bundled file and process tools use optional filesystem and process
capabilities from the context, allowing the same Tool values to run through
host or sandbox implementations.

Bundled file mutations operate on disk through same-directory temporary files.
They verify the target before publication, preserve an existing regular file's
mode, and reject symbolic-link targets. The interactive Neo composition may
refresh a matching loaded buffer only after the disk change succeeds and when
the buffer has no local edits.

Optional Tool hooks belong to the Agent layer. `on_messages` derives state from
a copied active conversation, and `render` produces semantic presentation data.
The reusable Agent Loop remains independent of Sessions and UI.

AGENTS.md and skill discovery are higher-level resources. The Agent adds them
to its prompt when configured. Workspace trust guards project resource loading
and tool-capable execution in the built-in Neo Profile. Sandboxing decorates
the executor with restricted filesystem and process capabilities. Escalation
temporarily decorates one tool call with host capabilities after an injected
interaction succeeds.

## Sessions and persistence

A Session owns semantic messages and an active path through a conversation
tree. It is tool-free and works entirely in memory when no store is supplied.
The full tree retains branches, linked derivations, request state, and
compaction entries; model context is a projection of the active path.

An accepted user message records the Model and thinking selection used for that
turn. Omitted thinking state inherits the active branch value, while an
explicit null clears it. Branching, reopening, copying, and forking derive
request state from the selected journal path.

The bundled store is an append-only JSONL tree. Empty Sessions create no file.
Session documents are authoritative; Workspace indexes are disposable
projections used for discovery. A persisted derivation publishes its complete
document before higher-level Agent construction, allowing the new Session to
be resumed even when activation fails.

Persistent state uses private files, verified same-directory publication, and
cross-process locks. A Store verifies regular-file identity around mutation and
refuses later writes when the outcome of a persistence step cannot be
confirmed. Opening a Session can recover one incomplete final record before
validating the remaining tree.

Workspace settings own Profile-scoped model and thinking preferences plus
Workspace-wide presentation and input-history state. A new Session updates its
Profile preference when its first message is accepted. Resuming an existing
Session restores its recorded branch state without changing that preference.

Compaction receives its Session path and Model explicitly. A successful
summary becomes a tree entry and replaces the compacted prefix in subsequent
model context. The Agent owns automatic thresholds, provider-overflow recovery,
and continuation.

## Agents, Profiles, and ownership

`neoagent.agent` is the main orchestration boundary. An Agent has immutable
Profile, Workspace, and Session identity and owns:

- live Model and thinking selection;
- one replaceable toolset;
- steering, retry, continuation, and compaction state;
- one authoritative activity Run;
- semantic presentation, dialog, and attention state.

The outer activity Run spans preparation, optional compaction, interaction,
model and tool turns, retries, continuation, cancellation, and provider-use
release. Agent publications are copied, revisioned semantic values. Durable
submission acceptance is a separate update so an Agent Applet clears only the
composer value that was committed.

A Profile is a recipe for constructing an Agent. Neo supplies coding tools,
project resources, trust, and the selected executor; Chat supplies a tool-free
conversation. `setup()` registers the recipes without creating Agents.

Interactive work begins in a retained Profile draft keyed by Profile and
canonical Workspace. The draft owns staged request, sandbox, composer, and
presentation choices. Its first submission or a resumed Session creates and
provisionally adopts an Agent. Failure before acceptance restores the draft;
durable acceptance binds the Agent. Session creation remains authoritative
when later activation fails.

Agent construction receives draft configuration and the staged request
selection as distinct values. The selection carries model identity and
thinking level atomically and governs the first accepted message, while a
resumed Agent restores request state from its selected Session path.

Each bundled Agent owns one permanent Agent Applet, and each Agent Applet owns
one View. Closing the visible surface leaves the Agent and its semantic state
alive. Background Agent Runs continue independently while the top-level
Neoagent Applet selects another foreground Agent.

The principal ownership scopes are:

| Value | Owner | Lifetime |
| --- | --- | --- |
| Provider runtimes and Authentication | top-level composition or direct Agent composition | until composition destruction |
| Provider Shell | top-level Neoagent Applet | independent of Agent selection |
| Profile draft | top-level Neoagent Applet | until binding, replacement, or destruction |
| Session and activity | Agent | fixed for the Agent lifetime |
| Agent Applet | Agent | retained across open and close |
| View | Agent Applet or Provider Shell | one presentation composition |
| Pane | semantic component | mounted by one live Applet |
| ImageSystem | View | shared by that View's image-capable Panes |

The top-level Applet owns command routing, Agent registration and selection,
Profile drafts, live Session claims, the Agent switcher, shared provider
runtimes, and the Provider Shell. Direct Agents have no dependency on that
singleton composition.

## Presentation

The public `applet` package provides host-neutral UI composition:

- A View maps one complete semantic state to an Applet layout.
- A Renderer converts copied transcript blocks into Pane content Trees.
- A Pane owns one buffer's content, interaction, scrolling, and optional image
  placements.
- An Applet owns layout, Hosts, buffers, windows, focus, and observation.
- An InteractionDomain schedules safe publication around native editing state.

Agent Views use separate Panes for transcript, composer, details, and dialogs.
The Provider Shell uses its own selector, detail, and interaction Panes.
Semantic presentation sources remain above this stack; they can also use a
fallback host without creating a View.

Applet and Pane submissions are immutable borrowed values. Stable keys and
explicit revisions identify reusable content. Each publication is
transactional: compilation or native mutation failure preserves the previous
committed presentation. Components own semantic state, while the Applet package
owns Neovim handles and lifecycle.

Renderers receive copied blocks and bounded layout context, then return native
content Tree nodes for transcript and details surfaces. Tool render hooks
produce renderer-neutral semantic data. Replacing a Renderer changes
presentation without changing Session content or Agent state.

A View may own one ImageSystem shared by its Panes. Panes submit complete
visible placement plans; ImageSystem owns prepared PNG resources and delegates
persistent placement to a backend. The bundled backend uses the Kitty graphics
protocol. Backend failure clears backend-owned state and leaves compact text
fallbacks in the content Tree.

Sensitive input uses transient Applet mounts. Replacing such a mount allocates
a fresh buffer and disposes the prior buffer while its sensitive descriptor is
retained through cleanup.

The full Applet API and content Tree vocabulary are documented in
`:help applet`. Neoagent configuration, commands, and Renderer contracts are
documented in `:help neoagent`.

## HTTP recording

HTTP recording wraps the provider transport assembled by the Agent or top-level
composition. API adapters, catalog discovery, Authentication, and Provider
Services use bound transport copies that add correlation context while
remaining unaware of recorder configuration and storage.

A recorder associates model exchanges with Workspace, Agent, Session,
provider, and model identities. Shared catalog, authentication, and Provider
Shell work is grouped by provider. Each exchange streams ordered protocol and
timing records to one private staging file, closes it, and publishes one JSON
Lines or YAML recording.

Retention applies within the exchange's owning Session or shared provider
directory. Rolling retention keeps the latest successfully published exchange;
complete retention keeps all exchanges. Publication precedes pruning, so a
failed finalization preserves the previous recording and current staging
evidence.

Sanitization is protocol-aware. Credential headers, credential-bearing URL
values, known credential request fields, and explicitly classified
authentication response bodies are masked before persistence. Model request
bodies and ordinary provider response bodies retain their content. Recorder
failures are content-free diagnostics and never replace the provider result.

Storage layout, formats, redaction coverage, and the security implications of
captured conversation bodies are public configuration behavior documented in
`:help neoagent-recording`.

## Public composition

`require("neoagent").setup()` creates the command-facing Neoagent Applet,
registers the Neo and Chat Profiles, and creates no Agents. `neoagent.new()`
constructs an independent Agent and can receive a caller-owned Session,
Workspace, or provider runtime set.

Headless Agent construction loads semantic presentation and host effects on
demand. Applet, Pane, image, and bundled Renderer modules materialize when a UI
composition is requested.

## Request flow

1. A Profile draft or Agent Applet accepts composer input.
2. The top-level Applet provisionally constructs an Agent when the draft is
   unbound.
3. The Agent checks trust and prepares its Model, resources, toolset, provider
   use, and commit command.
4. Chat appends the user message and its request state to the Session.
5. Durable acceptance binds a provisional Agent and updates the new Session's
   Workspace preference.
6. The Agent Loop streams the Model and commits assistant, tool-result, and
   steering messages before dependent work.
7. Agent publications update its View while provider events update the shared
   Provider Shell.
8. Completion or cancellation releases active tools, child Runs, and provider
   use exactly once.
