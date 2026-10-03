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
                     └── execute_tool policy ──► Tool
                           ├── parent-only/host ──► local implementation
                           └── restricted ──► sandbox interceptor
                                  ├── native WorkerLease
                                  └── RPC proxy ──► RpcConnection
                                                       └── Tool worker
                                                            └── same implementation
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
Detached resource cleanup retains diagnostic forwarding through awaiting Runs
until cleanup is observed, independently of coroutine completion. It releases
those reporting links after its final diagnostic.
Before a cancelled activity finishes, the Agent reconciles committed Tool
results with its Views, message hooks, and file-buffer refreshes.

## Agents and the top-level composition

An Agent has fixed Profile, Workspace, and Session identity. It owns model and
thinking selection, tools, steering, dialogs, and one activity lifecycle.
Closing its UI does not transfer or end that ownership.

Profiles declare eligible Model APIs. Selectors filter by this declaration;
request selection enforces it whenever a Model binds, including default and
lazy selections. An active encrypted checkpoint also requires its original
API, provider, and Model, and supplies that Model selection when resuming.

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
use. Each resolved Model operation acquires a shared Service lease before
Authentication and holds it until the child operation settles. This applies to
estimation, inference, and native compaction, with or without attachments.

Provider runtimes own remote file preparation and upload protocols. Sessions
retain local image bytes, while the workspace provider cache owns remote
references. A Workspace supplies file and cache capabilities explicitly;
semantic request state never owns either. Request-scoped preparation uses
Service leases independent of the calling Agent's lifecycle.

## Tools and Workspace policy

Tools own their schemas, implementations, message hooks, and presentation.
The Agent Loop delegates validated calls to `execute_tool(tool, arguments,
ctx)`, where the composition applies approval, logging, and sandbox policy.

The sandbox interceptor substitutes an RPC proxy for a recognized bundled
implementation and passes it through the configured executor. The worker runs
the same implementation used locally. Host execution and explicitly granted
parent Tools run directly. Unsupported restricted Tools fail closed.

The worker receives copied Workspace input and has no Agent, Session,
provider, or UI state. Results and updates cross as semantic values; artifact
bytes are verified and imported into parent storage before publication.
Sandbox denial evidence is consumed by the interceptor, outside Session data.
Tool-owned `details` and executor-owned `execution` metadata remain separate
in results and committed messages. Sandbox policy owns `execution.sandbox`.

`RpcConnection` owns communication with the worker. `WorkerLease` owns the
worker process and native sandbox resources. Their lifetimes are independent
of individual requests. Process WorkerLeases and local handles share the pipe
driver's native creation, stream handling, signalling, and reaping. The lease
owns protocol delivery, its cooperative shutdown grace, and cleanup observation.
Worker request validation precedes native ownership. After native startup is
attempted, the caller always receives a lease: readiness reports startup failure,
and completion observes cleanup independently. Sandbox relays own their staging
resources until that completion, including failed startup. Adapters clean staging
directly only when the request is rejected before native ownership begins.
Lease completion reports operation and cleanup errors as independent fields;
readiness keeps the original startup or admission failure. Relays preserve host
cleanup errors alongside their own staging cleanup failures. The interceptor
retains the invocation before awaiting admission, so failed startup and completed
Tool results both receive cleanup notices. Diagnostic forwarding remains alive
until detached cleanup completes, even when its observing Run is cancelled.
Both owners share drain-deadline enforcement. Delayed editor delivery can grant
one final drain interval; continuing output cannot renew cleanup indefinitely.
The lease publishes completion after output drains; native exit status remains
absent when cleanup fails before exit can be observed.
The interceptor owns both for each invocation and
completes cleanup independently of Run cancellation. Received results still
undergo validation when observation is cancelled. The worker closes and settles
each request's local process scope before acknowledging completion or
cancellation. Local process controls have the pipe/PTY limits described below;
complete descendant containment belongs to the native lease.
Reusing a Tool connection does not establish that earlier descendants have
stopped. The one-shot interceptor ends the connection and retains the native
lease until cleanup settles, including detached cleanup after cancellation.
Channel failure stops progress publication and starts lease disposal
independently of pending result validation. Invocation deadlines also bound
parent artifact import and can revoke pending validation without publishing
unchecked results. Finite shell deadlines have an independent parent watchdog
so stopping the restricted worker cannot disable its timeout.
Cancellation of a cleanup wait records an unobserved
cleanup outcome; detached cleanup retains ownership of the lease.
Shutdown validation continues through the worker's final output.

File arguments are resolved and authorized in the parent before execution.

Native isolation enforces filesystem, process, and network policy. Parent
preflight checks concrete paths, including worker bootstrap dependencies;
it never overrides explicit filesystem denials. Profiles are resolved per
invocation, while activation status reports native platform availability.

Project instructions and skills are Agent inputs governed by Workspace trust.

## Local subprocesses

`neoagent.subprocess_common` supplies local process scopes and synchronous runs.
It depends on local pipe/PTY drivers and their native ownership,
independently of Tools, sandboxing, RPC, Agents, Sessions, providers, and UI.
Targets inherit the authority of their execution process. Placement remains
with the composition that invokes the Tool.

A handle owns input, output delivery, its lifetime deadline, termination,
completion, and cleanup. Retained spawning requires a scope created before
startup. That scope owns handles for the caller's lifetime and retains cleanup
failures even when startup returns no handle. The Tool RPC server supplies a
request-owned scope. Cancelling a handle waiter only removes that observer.
Cancelling a synchronous run or closing a scope disposes its targets, while
internal ownership retains cleanup until settlement.
Operation failure, disposal, and cleanup failure remain separately observable.
Completed handle state retains any observed exit status even when cleanup fails.
Completion follows output delivery and native resource settlement.
Observing native exit begins bounded cleanup independently of exit-status
delivery. The status may arrive while output drains; an unavailable status
cannot leave cleanup unbounded or become a fabricated process outcome.

`run()` uses a private scope and composes the same spawn operation with initial
input, bounded or disabled capture, and waiting. Bundled Tools own their text
conversion, truncation, spill files, progress updates, and result formatting.
Drivers own startup acknowledgement, native identity, signalling, reaping, and
non-waiting state observation. Root exit, output drain, and native finalization
are distinct facts. A drained driver still requires disposal to release retained
child identity; finalization can fail independently of the operation outcome.
The native owner retains an unreaped child after reporting a cleanup failure.

Pipes and native PTYs share bounded pending writes and output delivery. PTYs
use platform APIs through LuaJIT FFI, without a terminal UI, interpreter
dependency, or supervisor process. POSIX drivers retain a waitable child until
the final original-group signal. Windows PTYs assign a Job atomically during
creation and retain native process identity. Owners arbitrate deadlines and
results; drivers observe exit independently of stream or console cleanup.
Blocking Windows console resize and release run serially on a libuv worker.
The driver coalesces pending resize requests, prioritizes release, and retains
ownership through completion or beyond a reported cleanup deadline.
Platform requirements, terminal behavior, and the remaining POSIX descendant
containment boundary are documented in the [API reference](doc/neoagent.txt).

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
Agent. The Profile Session boundary rejects derivations whose target Profile
cannot preserve the active encrypted checkpoint. Session and storage modules
remain independent of Profiles and UI.

## Request preparation and compaction

Profiles choose compaction components. The Agent's private checkpoint
operation owns planning, acceptance, and journal publication; its activity
lifecycle owns provider leases, child Runs, and events. Components receive
request inputs and return checkpoint candidates. All Model calls, including
compaction and recovery, receive copied Tool definitions; executable Tools
stay with the Agent and Loop.

The Loop prepares requests from committed messages before each Model call,
including Tool follow-ups and continuations. The Agent persists any required
checkpoint at this gate. Steering can require another preparation pass; only
the final validated pass is acknowledged and counted as a request attempt.
Preparation failure blocks inference. A provider recovery proposal also passes
through this gate: the Loop commits the partial response and recovery prompt
before one bounded follow-up. Usage stays with each response rather than being
added across requests as a context-size observation.

Models estimate the complete request after configured and authenticated
shaping. Estimation resolves credentials within a cancellable activity but
performs no inference or file preparation. The request owner keeps the
estimated candidate separate from later rebuilt candidates. Copies of request
options share this preparation; Models and Services never retain it. Reuse
requires matching credentials, inputs, and operation. Execution revalidates
credentials and checks content against the estimate before preparing files or
sending a request. Credential-only header changes are allowed; changed content
or operations require fresh estimation and otherwise fail locally without
transient retries.

Component evaluation decides whether compaction is needed. Semantic estimates
select journal cuts, while Models budget complete candidate requests with
output reserved for each generated part. Observed usage from the active
context supplies a conservative floor. Strategies own generation inputs and
retention policy; API adapters enforce per-call output and thinking budgets
after shaping.

The Session validates and projects candidates without changing the journal.
Shared checkpoint acceptance budgets that projection through the Model; the
Agent publishes it only while the source leaf and activity remain current. The
request gate then checks the published context's budget. The Codex component
fits retained users around the returned encrypted item, shortening boundary
text or dropping messages while preserving that item exactly. Acceptance
validates this result without changing the component's retention policy.

Local checkpoints retain a contiguous suffix, omitting superseded checkpoints,
or consume the whole active context when necessary. They cannot replace
encrypted context. Native checkpoints project selected user messages, with
optional text prefix limits, before the encrypted item and omit consumed
assistant and Tool history. The Session keeps the full conversation tree;
native transcripts show the complete journal path with a checkpoint marker.

Candidate searches and request reductions are bounded and cancellable;
reductions change request copies only. If a provider rejects the estimated
context size, bounded recovery can compact the active projection again. Local
strategies consume the retained suffix with less summary output; native
recovery removes retained users and recompacts the encrypted item. Neither
restores consumed history. Length continuations are limited per checkpoint and
counted when the prepared request is acknowledged. At the limit, a budget-only
check determines whether another checkpoint is needed. Successful final
answers do not start maintenance compaction.

Each retry owner reports exhaustion so outer recovery cannot repeat it. The
Agent contains compaction failures from planning through publication and
publishes one completion result while the activity remains current. These
failures are tagged as compaction errors and cannot restart inference
recovery. Failed overflow recovery preserves the original provider error
unless cancelled; estimation errors before compaction is needed retain their
normal classification.

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
