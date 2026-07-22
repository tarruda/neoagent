# Neoagent contributor guide

This file is the operational guide for agents working in this repository. Keep
it concise and update it whenever the development workflow or a hard invariant
changes.

## Product principles

- Keep it simple. Prefer a small explicit composition over a framework.
- Less is more. Do not add an abstraction until a concrete use case requires
  it.
- Neoagent's foundation is an LLM and agent API. Sessions, persistence,
  Workspace, bundled tools, configuration, and UI are optional higher-level
  compositions.
- Make every layer usable directly from ordinary Lua. Third-party plugins must
  be able to replace Models, tools, executors, message owners, and UI without
  patching global state.
- Prefer plain tables, functions, and constructors over registries, discovery,
  inheritance hierarchies, generic hook buses, or extension frameworks.
- Do not introduce built-in approval or permission policy. Approval prompts,
  logging, sandbox delegation, and similar policy belong in an
  `execute_tool(tool, arguments, ctx)` decorator.
- Do not hardcode machine-specific paths. Executables and test dependencies
  must come from `PATH`, Make variables, environment variables, or
  repository-relative dependency directories.

## Architectural invariants

- `neoagent.api.*`, `neoagent.transport.*`, `neoagent.async`, and
  `neoagent.agent` form the reusable core. They must not import configuration,
  Sessions, storage, Workspace, bundled tools, the controller, or UI.
- A Model is an explicit value with `model:stream(opts)`. It uses named
  `on_event` and `on_done` options and returns a cancellable Run.
- `agent.run(opts)` receives its Model, messages, exact tools, executor, and
  context explicitly. It does not mutate input messages or resolve defaults.
- Steering enters the core through an explicit `get_steering_messages`
  callback and is consumed between assistant/tool turns. Each Controller owns
  its pending steering queue; the Window restores queued text for editing.
- `Session.new()` remains a no-argument, tool-free in-memory message owner. A
  store is optional and injected.
- The passive View consumes messages and events. A Window owns one View,
  selects an active Controller, and retains one input draft per Controller.
  Attached Controllers have unique, non-empty names. Transient status and
  spinner updates use decoration and preserve transcript text and Normal-mode
  command state.
- Controllers are independent compositions of configuration, model selection,
  Session, Workspace, and Run. They publish compaction-aware transcript
  snapshots and updates so Windows and other consumers can attach without
  owning the agent loop; the Session retains the complete active branch.
- Controller Runs remain independent when a shared Window selects another
  Controller. The command-facing default Window is replaceable; custom
  Controllers and Windows must not mutate or depend on it.
- The bundled default Window starts with `Neo` and `Chat`. `Neo` uses the
  configured coding composition. `Chat` has an empty system prompt and tool
  list, with AGENTS.md and skill discovery disabled.
- AGENTS.md and skill discovery are optional higher-level resource modules.
  The built-in Neo Controller injects complete AGENTS.md files
  broad-to-specific, but only skill metadata; complete skill instructions are
  read on demand.
- Self-awareness is provided by an on-demand bundled documentation tool. Its
  description guides when it should be called; its result summarizes
  composition and points to installed source and config.
- Bundled file tools operate only on disk. Loaded Neovim buffers are not a tool
  storage layer; the built-in Neo Controller may refresh an unmodified matching
  buffer after a successful disk mutation.
- Default coding tools are exactly `read_file`, `write_file`, `edit_file`,
  `shell`, and `read_agent_documentation`. The read-only preset is exactly
  `read_file`, `grep`, and `find`.
- `request_opts` is the sole built-in request customization mechanism. It may
  be a table or callback and recursively merges provider, model, then call
  layers across `url`, `headers`, and `body`.
- Thinking levels are model-declared request-option layers. The default
  controller selects and displays a level; Models and `agent.run()` do not
  interpret thinking semantics.
- Provider login methods are plain Lua values with `login`, `refresh`, and
  `request_opts`. Credential resolution wraps a Model at stream time; OAuth
  flows and Models must not import or assume the command/UI adapter.
- The final provider/model registry composes built-in defaults with the user
  `providers` table. User entries override defaults; `false` removes a default
  provider or model. Model selection filters the composition by configured
  OAuth credentials or API keys without affecting direct Model constructors.
- Persist credentials atomically outside user configuration. Credential
  directories created by the store use mode `0700`; files use mode `0600`.
  Never log access or refresh tokens.
- Persistence uses the full Pi v3 append-only JSONL tree format. Sessions expose
  active-branch projection, leaf movement, branch summaries, labels, names, and
  linked forks. Opening Neovim or creating an empty Session must not create a
  session file; persistence starts with the first accepted message.
- Compaction consumes a Session path and Model explicitly, writes Pi compaction
  entries, retains safe turn boundaries, and supports repeated summaries.
  Controllers own automatic thresholds, overflow recovery, and UI events.
- Codex Models classify provider failures and retry transient requests that
  produced no output. Controllers replay explicitly retryable failed turns,
  removing any failed assistant message from the active branch first.
- Configured Codex diagnostics contain bounded error and request-correlation
  metadata. They never contain credential values, request or response bodies,
  or conversation content.
- Bundled persistence uses one cwd-hashed workspace namespace for
  `settings.json`, `input-history.jsonl`, and `sessions/`. Model and thinking
  preferences are scoped by Controller name; UI position, input history, and
  the session pool are shared. Every Controller can resume every workspace
  Session. Reads must not create files.
- Cancellation must propagate through active Models, tools, and nested Runs,
  complete exactly once, preserve meaningful partial output, and prevent stale
  callbacks from mutating newer controller state.
- Runtime code has no Lua plugin dependencies. Curl, `rg`, and `fd` are runtime
  executables; ImageMagick's `magick` is optional.

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
- Keep public behavior documented in `README.md` and `doc/neoagent.txt`.
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
feat(session): add Pi trees and context compaction

Session and storage now own a Pi v3 append-only tree. Chat projects the
active path into model context, and Controllers compose navigation,
forks, and compaction while the reusable agent core remains independent.

- Support every Pi v3 entry type, active leaves, labels, and linked
  forks.
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

Before completing a runtime change, run:

```sh
make coverage
```

`make test` runs all three suites without generating a report. Integration
tests start a Python mock OpenAI server on an ephemeral localhost port and
exercise the real curl process. UI tests run isolated headless Neovim children
and inspect buffers, windows, mappings, extmarks, modes, and callbacks rather
than screenshots.

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

- Every shipped Lua file under `lua/neoagent/` and `plugin/` must appear in the
  LuaCov report, including modules that normal tests would not otherwise load.
- Aggregate shipped-plugin Lua line coverage must remain strictly greater than
  98%.
- For every bug report, first add a focused regression test and verify that it
  fails against the unmodified implementation for the reported reason. Then
  implement the fix and verify that the same test passes.
- Add focused tests for behavior changes and regressions. Prefer meaningful
  protocol, lifecycle, and boundary tests over coverage-only assertions.
- Do not claim completion until the full suite passes, the coverage checker
  passes, health behavior remains valid, and public documentation matches the
  implementation.
