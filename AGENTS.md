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
- `Session.new()` remains a no-argument, tool-free in-memory message owner. A
  store is optional and injected.
- The passive View consumes messages and events. It does not own or invoke the
  agent loop.
- Bundled file tools operate only on disk. Loaded Neovim buffers are not a tool
  storage layer; the default controller may refresh an unmodified matching
  buffer after a successful disk mutation.
- Default coding tools are exactly `read_file`, `write_file`, `edit_file`, and
  `shell`. The read-only preset is exactly `read_file`, `grep`, and `find`.
- `request_opts` is the sole built-in request customization mechanism. It may
  be a table or callback and recursively merges provider, model, then call
  layers across `url`, `headers`, and `body`.
- Persistence uses the supported Pi v3 linear JSONL subset. Opening Neovim or
  creating an empty Session must not create a session file; persistence starts
  with the first accepted message.
- Cancellation must propagate through active Models, tools, and nested Runs,
  complete exactly once, preserve meaningful partial output, and prevent stale
  callbacks from mutating newer controller state.
- Runtime code has no Lua plugin dependencies. Curl, `rg`, and `fd` are runtime
  executables; ImageMagick's `magick` is optional.

## Working in the repository

- Treat this repository as the canonical source. Do not edit or deploy a copied
  plugin installation unless the user explicitly asks for deployment.
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

## Coverage and completion

- Every shipped Lua file under `lua/neoagent/` and `plugin/` must appear in the
  LuaCov report, including modules that normal tests would not otherwise load.
- Aggregate shipped-plugin Lua line coverage must remain strictly greater than
  98%.
- Add focused tests for behavior changes and regressions. Prefer meaningful
  protocol, lifecycle, and boundary tests over coverage-only assertions.
- Do not claim completion until the full suite passes, the coverage checker
  passes, health behavior remains valid, and public documentation matches the
  implementation.
