# Neoagent contributor guide

This file is the operational guide for agents working in this repository. Keep
it concise and update it whenever the development workflow or a hard invariant
changes.

## Product principles

- Keep it simple. Prefer a small explicit composition over a framework.
- Less is more. Do not add an abstraction until a concrete use case requires
  it.
- Fix problems at their ownership boundary. When a cohesive refactor or
  rewrite produces a simpler foundation, choose it and leave the surrounding
  design simpler as part of the same change.
- Neoagent's foundation is an LLM and agent API. Sessions, persistence,
  Workspace, bundled tools, configuration, and UI are optional higher-level
  compositions.
- Keep reusable layers callable directly from ordinary Lua. Add a public
  replacement boundary only when a shipped composition or concrete integration
  uses it. Test injection alone does not justify a public extension contract.
- Prefer plain tables, functions, and constructors over registries, discovery,
  inheritance hierarchies, generic hook buses, or extension frameworks.
- Before the project has users, keep one current data and configuration shape.
  Remove superseded formats and migrations as part of the change that replaces
  them. Do not preserve compatibility for unreleased behavior.
- Add semantic versions, API versions, capability negotiation, or schema
  migrations only when independently released components or existing user data
  require them. Exact format markers used to reject unsafe persisted state or
  coordinate separate runtime processes are allowed.
- Keep test seams internal to the owning constructor or module. Do not publish
  configuration, documentation, or nominal replacement APIs solely for test
  doubles.
- Do not introduce built-in approval or permission policy. Approval prompts,
  logging, sandbox delegation, and similar policy belong in an
  `execute_tool(tool, arguments, ctx)` decorator.
- Support metered API and subscription or coding-plan compositions when the
  provider documents a third-party integration surface for each access mode.
- Do not hardcode machine-specific paths. Executables and test dependencies
  must come from `PATH`, Make variables, environment variables, or
  repository-relative dependency directories.

## Architectural invariants

`architecture.md` is the canonical ownership and data-flow reference. Keep
these cross-cutting constraints in mind while changing code:

- `neoagent.api.*`, `neoagent.transport.*`, `neoagent.async`,
  `neoagent.semantic_message`, and `neoagent.agent_loop` form the reusable
  core. They must not import configuration, Sessions, storage, Workspace,
  bundled tools, Agents, or UI.
- Models and the Agent Loop receive complete validated dependencies explicitly.
  The loop does not resolve configuration defaults or depend on Sessions.
  Generated messages commit before dependent work.
- Cancellation propagates through Models, tools, child Runs, provider leases,
  and deferred destruction. Completion and resource disposal occur once, and
  stale callbacks cannot mutate newer state.
- A Session is a tool-free message owner with optional injected persistence.
  Each Agent has fixed Profile, Workspace, and Session identity and owns one
  independent activity lifecycle.
- The top-level Neoagent Applet owns Profile drafts, Agent registration and
  selection, live Session claims, shared provider runtimes, and the Provider
  Shell. Direct Agents remain independent from that composition.
- Views consume copied semantic state; Renderers produce content Trees; Panes
  own buffer content and interaction; Applets own layout and native surfaces.
  UI publication is transactional, and headless Agents do not load UI modules.
- Provider runtimes share Authentication, ModelCatalog, Provider Service, and
  transport values explicitly. Coordination occurs at the shared service or
  Authentication boundary, and provider operations receive no Agent state.
- `execute_tool(tool, arguments, ctx)` owns execution policy. Bundled file
  tools operate on disk through verified regular-file replacement. Workspace
  trust, sandboxing, resources, persistence, and UI remain optional layers.
- Credentials use private atomic storage and never enter provider state or
  diagnostics. Provider diagnostics exclude HTTP and conversation bodies.
  Persistence uncertainty makes the affected Store reject later mutations.
- HTTP recording is an observer: it cannot change provider results. It masks
  protocol credentials, preserves model and ordinary provider bodies, and
  masks response bodies only when Authentication explicitly classifies them as
  sensitive.
- Runtime code has no Lua plugin dependencies. Curl, `rg`, and `fd` are
  runtime executables.

## Working in the repository

- Treat this repository as the canonical source. Do not edit or deploy a copied
  plugin installation unless the user explicitly asks for deployment.
- Write documentation and comments as a direct description of the current
  design. Do not preserve implementation history or discarded alternatives
  with phrases such as "not a ...", "rather than ...", "instead of ...",
  "still ...", or "no longer ...". Use positive statements about ownership,
  behavior, and composition. Negative wording is appropriate only when it
  defines a current API guarantee, safety boundary, prohibition, or error.
- Preserve unrelated user changes and generated local configuration.
- Keep `README.md` focused on project presentation and concise setup.
  `doc/neoagent.txt` documents public configuration, APIs, and behavior needed
  to use or extend the plugin; `doc/applet.txt` does the same for the Applet
  package. `architecture.md` documents stable ownership, lifecycle, extension,
  and data-flow boundaries.
- Give each passage a reader-facing purpose. Keep concrete, copyable examples,
  and prefer real provider and model names when that makes an example useful.
  Omit exhaustive inventories that merely mirror live data, incidental visual
  styling, test implementation details, and repetition that adds no local
  context. Repeat a fact when it makes a section self-contained; otherwise
  link to its canonical reference.
- Track multi-step implementation work in `TODO.md` when requested.
- Do not weaken validation, cancellation, or coverage collection merely to
  make a test pass.
- Tests must exercise observable behavior or protect a concrete regression.
  Do not add tests that merely require modules or verify conditions that the
  behavioral suite necessarily exercises already.
- Do not test test-only helpers, fixtures, mock servers, runners, or coverage
  infrastructure. Validate them only through the product behavior they enable.
- Keep generated artifacts out of source changes: `.deps/`, `.coverage/`,
  `.test-data/`, and `.nvimlog` are disposable.

## Commit messages

- Use Conventional Commit subjects: `<type>(<scope>): <summary>`. Omit the
  scope when the change does not have one clear subsystem.
- Use the types that describe the change directly, such as `feat`, `fix`,
  `test`, `docs`, `refactor`, or `chore`.
- Write the summary in the imperative mood, start it with lowercase unless it
  begins with a proper name, and do not end it with a period.
- For a non-trivial commit, follow the subject with a blank line and a concise
  overview paragraph. Explain the architectural shape of the change and how
  its major components relate.
- Follow the overview with a blank line and `-` bullets describing the
  concrete behavior and coverage. Start each bullet with an imperative verb
  and end it with a period.
- Wrap every commit body line at 72 columns.
- Keep each commit focused. The subject and body must describe only the staged
  changes.

For example:

```text
feat(session): add session trees and context compaction

Session and storage own an append-only tree. Chat projects the active
path into model context, and Agents compose navigation, forks, and
compaction while the reusable Agent Loop remains independent.

- Support Neoagent message, selection, compaction, and leaf entries.
- Add branch and fork APIs, commands, selectors, and input
  restoration.
- Compact context automatically, manually, and after provider
  overflows.
- Preserve tool-call boundaries, repeated summaries, cancellation,
  and retry.
- Document configuration and cover storage, lifecycle, and UI
  behavior.
```

## Dependencies

The supported minimum is Neovim 0.10. Required test/runtime commands are:

- `nvim`
- curl 7.76 or newer
- `rg`
- `fd`
- Python 3
- Git and Make for fetching and running test dependencies

Run `make deps` to install the pinned Plenary and LuaCov checkouts under
`.deps/`. `NVIM` and `PLENARY_DIR` may override the executable and Plenary
checkout. Otherwise they default to `nvim` on `PATH` and
`.deps/plenary.nvim`. The Makefile also reads an optional, gitignored
`local.mk`; keep machine-specific `NVIM`, `PLENARY_DIR`, and `PATH` overrides
there rather than in tracked files. Copy `local.mk.example` to get started.

## Test workflow

Use the narrowest relevant suite while iterating:

```sh
make test-unit
make test-integration
make test-ui
```

Run the combined default suite during broader iteration and before completion:

```sh
make test
```

`make test` and `make test-fast` run the unit, integration, and UI suites
without coverage or terminal-image tests. Integration tests start a Python
mock OpenAI server on an ephemeral localhost port and exercise the real curl
process. UI tests run isolated headless Neovim children and inspect buffers,
windows, mappings, extmarks, modes, and callbacks rather than screenshots.

Coverage and terminal-image tests run in CI. Run them locally only when the
user explicitly requests them:

```sh
make coverage
make test-terminal-images
```

The Linux terminal-image CI job renders a real Applet through Kitty and
Konsole under Xvfb. It inspects captured pixels for supported renderers and
exercises selected tmux-hosted paths. It skips terminals whose Kitty graphics,
tmux, or Xvfb/ImageMagick dependencies are absent; CI installs the complete
set.

All waits must be predicate-based and bounded. Clean up processes, timers,
temporary directories, buffers, and windows in teardown paths.

## Interactive UI debugging

Headless UI tests are the primary regression suite, but a real terminal is
useful while developing or diagnosing visual behavior, focus, mappings,
streaming, and colors. Use a disposable tmux session so Neovim can keep running
between commands and its terminal output can be inspected non-interactively.

Start Neovim from the repository with this checkout prepended to
`runtimepath`:

```sh
tmux new-session -d -s neoagent-debug -c "$PWD" \
  "nvim -n -i NONE --cmd 'set runtimepath^=$PWD' README.md"
```

Use `nvim` from `PATH`, or use the current machine's `NVIM` override from
`local.mk` when invoking the command. Never put that resolved path in a tracked
file. `-n -i NONE` avoids swap and ShaDa side effects. The normal user config
is intentionally loaded so provider settings, colors, and mappings can be
tested; use a separate disposable config when isolation is the behavior under
test.

Useful tmux operations:

```sh
tmux send-keys -t neoagent-debug Escape ':Neoagent' Enter
tmux send-keys -t neoagent-debug -l 'Inspect this project'
tmux send-keys -t neoagent-debug C-s
tmux capture-pane -p -e -t neoagent-debug -S -100
tmux attach-session -t neoagent-debug
tmux kill-session -t neoagent-debug
```

Send literal prompt text with `send-keys -l`; send control keys and `Enter`
separately. Use the configured submit mapping if it differs from the default
`<C-s>`. Keep ANSI escapes with `capture-pane -e` when checking foregrounds,
backgrounds, or font attributes. Capture the UI both during streaming and
after completion when debugging state transitions. Do not submit prompts to a
metered or external model unless the user explicitly authorizes it. Always
close the disposable session when inspection is complete.

## Coverage and completion

- Every shipped Lua file under `lua/applet/`, `lua/neoagent/`, and `plugin/`
  must appear in the LuaCov report, including modules that normal tests would
  not otherwise load.
- Aggregate shipped-plugin Lua line coverage must remain strictly greater than
  99.60%.
- For every bug report, first add a focused regression test and verify that it
  fails against the unmodified implementation for the reported reason. Then
  implement the fix and verify that the same test passes.
- Add focused tests for behavior changes and regressions. Prefer meaningful
  protocol, lifecycle, and boundary tests over coverage-only assertions.
- Do not claim completion until the relevant fast suites pass, health behavior
  remains valid, and documentation affected by a public-contract or stable
  architecture change is current. CI enforces the coverage thresholds and
  terminal-image behavior.
