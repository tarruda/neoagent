# Neoagent architecture

Neoagent has a reusable Model API and Agent Loop. Agents compose them with
Sessions, Tools, Workspace policy, persistence, and presentation. Configuration
and API usage belong in [neoagent.txt](doc/neoagent.txt); the independent UI
package is documented in [applet.txt](doc/applet.txt).

```text
Composition
  ├── shared provider runtimes
  └── Agent
       ├── Profile, Workspace, and Session ──► storage
       ├── activity ──► Agent Loop
       │                 ├── Model ──► API adapter ──► HTTP transport
       │                 └── execute_tool policy ──► local or sandboxed Tool
       ├── retained processes ──► local or sandbox controller
       └── presentation ──► View ──► Renderer ──► Applet and Panes
```

## Core and execution

The core contains cancellable Runs, transports, API adapters, semantic messages,
file interfaces, and the Agent Loop. It does not depend on configuration,
Sessions, storage, Workspace policy, bundled Tools, Agents, or UI.

A Model exposes streaming inference and its capabilities. API adapters translate
semantic messages into provider protocols using explicit file readers and
copied request state. The shared HTTP client decodes JSON and SSE; the byte
transport owns network I/O and classifies transport failures. Callers own retry
policy and deadlines.

The Agent Loop receives its Model, messages, Tools, executor, steering, context,
and commit function as dependencies. The message owner commits authoritative
state before dependent work begins. Runs propagate cancellation through child
operations. Resource owners retain cleanup and diagnostics after an observer
cancels; completing a coroutine does not end native ownership.

## Agents and composition

An Agent binds one Profile, Workspace, and Session. It owns Tools, Model and
thinking selection, steering, dialogs, retained processes, and one activity at
a time. Closing its UI preserves the Agent; stopping an activity preserves
committed retained processes. Destroying the Agent disposes its resources.
Headless Agents do not load UI modules.

A Profile is an Agent recipe, including eligible Model APIs and execution
policy. `neoagent.new()` creates an independent Agent. `neoagent.setup()` adds
the command-facing Applet, which owns Profile drafts, Agent selection, live
Session claims, shared provider runtimes, and the Provider Shell. A draft
becomes an Agent when its first message is accepted.

Agents publish copied, revisioned semantic state. Session acceptance determines
when a submission is durable; presentation observes that decision. Workspace
trust governs project instructions and skills. Tool authority is a separate
executor policy.

## Provider runtimes

A runtime composes API connections, Authentication, a ModelCatalog, an optional
Provider Service, and transport. The top-level or direct Agent composition owns
runtime sharing. Shared operations receive provider state; copied Agent,
Workspace, and Session identity enters only at request shaping.

ModelCatalog owns selectable inventory. Authentication owns credentials and
login, refresh, logout, and Model wrapping. Services own provider management.
Their leases coordinate concurrent use and exclusive mutations, including
credential changes. Resolved Model operations hold Service use before entering
Authentication; request-scoped file preparation owns independent use.

Sessions retain image bytes. Provider runtimes prepare remote files, and a
Workspace cache retains remote references separately from conversation state.
Credentials stay out of provider state and diagnostics; request and response
bodies stay out of diagnostics. Credential storage is private and atomic.

## Sessions and persistence

A Session owns messages and the active path through a conversation tree. It is
tool-free and can use memory or an injected store. Model context is a projection
of that journal, not a replacement for it.

Workspace storage owns Session documents, immutable attachment blobs, provider
mappings, and a rebuildable index. Attachments use content identity rather than
source paths. Same-workspace derivations share blobs; cross-workspace derivations
import attachments before publishing the destination. Persistence uncertainty
blocks further Store mutations.

The top-level composition owns Session derivation until it can publish an Agent.
Profile compatibility is checked there; Session and storage modules remain
independent of Profiles and UI.

## Request preparation and compaction

Every Model request is prepared from committed messages. Models budget the
complete shaped request, including authentication, Tool schemas, attachments,
and reserved output. A change to request content invalidates that preparation.
Only the final validated preparation authorizes inference and request accounting.

Profiles choose compaction components. Components propose checkpoints; the
Session validates their context projection, the Model checks its budget, and
the Agent publishes against the unchanged source state. Failed preparation
leaves committed messages intact and prevents the next inference request.
Compaction and recovery remain bounded and cancellable.

Local checkpoints contain summaries and retained history. Native checkpoints
contain encrypted context tied to the original API, provider, and Model; local
compaction cannot replace them. Both preserve the conversation journal. Request
reductions operate on copies, while executable Tools remain with the Agent and
Loop.

## Tools and sandbox placement

Tools own schemas, effects, message hooks, and presentation. The composition's
`execute_tool(tool, arguments, ctx)` applies approval, logging, and placement.
Tools do not select where they run. File arguments are resolved and authorized
before execution; bundled file replacement verifies regular-file identity.

Restricted execution runs the same recognized Tool implementation in a sandbox
worker. The worker receives copied execution input, never Agent, Session,
provider, Authentication, or UI state. Results cross as semantic values;
artifact bytes are verified and imported before publication. Tool details and
executor metadata have separate owners.

Sandbox composition resolves authority for both Tool calls and retained process
admissions. Activation or policy failure blocks restricted execution without
host fallback. Explicitly granted parent Tools remain available. Bootstrap
dependencies cannot override filesystem denials. Parent supervision keeps
deadlines enforceable when a worker becomes unresponsive.

RPC owns framing, ordering, bounded delivery, and request cancellation. Tool and
process domains define their own execution lifetimes. A `WorkerLease` owns
native execution and sandbox resources; an `Invocation` owns admission and one
final shutdown outcome. It retains the validated lease before startup and
finishes admission and cleanup independently of a cancelled caller. Closing or
observing the invocation yields the same outcome; native release is separate.
Diagnostic recipients survive until cleanup observation completes.

## Local subprocesses

The local subprocess API is independent of Tools, sandboxing, RPC, Agents, and
UI. Handles own execution and I/O; scopes bind handles to a caller's lifetime,
including resources allocated by failed startup. `run()` uses the same launch
machinery within a private scope. Tools retain output formatting and spill-file
policy.

Drivers own native creation, process identity, streams, signalling, and reaping.
Pipes and PTYs use Neovim/libuv and native FFI helpers without an extra
interpreter or supervisor process. WorkerLeases share pipe mechanics while
keeping their own protocol and shutdown policy.

Process outcome, bounded cleanup observation, and eventual native release are
independent facts. A failed cleanup deadline does not abandon resources or
prove release. Cancelling a waiter removes observation; disposing an owner
requests termination. Native owners remain responsible until release is
established.

POSIX supervision controls the original process group; descendants can escape
through job control or detachment. Windows uses Jobs. Full restricted
containment belongs to sandbox placement. The API reference specifies platform
requirements and limitations.

## Retained process sessions

`ProcessSessions` is Agent-owned, independent of activities, UI, the reusable
Loop, and durable Sessions. It owns in-memory IDs, capacity reservations,
controllers, and bounded output. Local controllers own subprocess scopes;
sandbox controllers own a worker for each target and retain their admitted
authority across sandbox toggles.

The publication owner reserves an admission before asynchronous construction or
startup, then commits or aborts the handoff. Controller construction acquires
no resources; the manager owns it before start. Cancelling startup revokes
publication, while cancelling a later poll preserves the target and unread
output. Model-facing Tools and durable Tool-result acceptance are still separate
integration work.

Target completion, controller cleanup, and native release are distinct. Remote
cleanup includes worker shutdown; capacity stays reserved until release is
proven, including failed starts and uncertain remote cleanup. Worker exit alone
is insufficient unless the native lease also proves descendant termination.
Forgetting a record cannot bypass this requirement. Output collection and
returned history have independent bounds so slow observers do not prevent
native draining.

## Windows sandbox authority

Windows isolation changes shared filesystem permissions, so authority outlives
individual invocations. One machine coordinator and journal admit compatible
policies and own provisioning and recovery. Configuration cannot create an
independent permission inventory over the same files. Native identities and
permission effects are recorded before allocation.

Each invocation has a private identity. The editor and sandbox host retain
independent custody of its authenticated Job. Authority retirement requires
proof that execution never began or that it has ended; a missing Job name or a
termination request is not evidence. Losing both owners leaves uncertain
authority quarantined until trustworthy recovery evidence is available.
Operational constraints and recovery instructions belong in
`:help neoagent-sandbox`.

## Presentation

Views consume copied semantic state; Renderers produce content Trees; Panes own
content and interaction; Applets own native surfaces, layout, and focus.
Publication is transactional and coordinated with native editing. Submitted
state and Trees are immutable borrowed values. The independent `applet` package
depends only on Neovim and its own modules. Image readers are explicit
capabilities, so presentation does not depend on Session or Workspace storage.

## HTTP recording

HTTP recording observes the byte transport without owning request results.
Recording failures cannot change provider outcomes. The recorder owns retention
and storage; Authentication classifies sensitive responses for redaction.
Ordinary bodies remain private user data, and sensitive response content never
enters temporary storage. Sharing precautions are in `:help neoagent-recording`.
