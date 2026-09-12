# Neoagent contributor guide

Read [architecture.md](architecture.md) before changing ownership or data flow.
Update this guide when the development workflow or a hard invariant changes.

## Design rules

- Use plain Lua tables, functions, and constructors with explicit dependencies.
  Add abstractions only for concrete shipped use cases. Fix problems at their
  ownership boundary, including cohesive refactors when they simplify it.
- Keep the LLM API and Agent Loop reusable without configuration, Sessions,
  storage, Workspace, bundled tools, Agents, or UI.
- Keep test injection internal. Public extension points need a shipped
  composition or concrete integration, not just a test double.
- Before the project has users, maintain one configuration and data shape. Remove
  superseded formats. Add versions, negotiation, or migrations only for
  independently released components or existing user data. Exact markers for
  safe storage validation and separate runtime processes are allowed.
- Put approval, logging, sandbox delegation, and other execution policy in
  `execute_tool(tool, arguments, ctx)`; the core has no permission policy.
- Support metered and subscription access when the provider documents a
  third-party integration surface for that mode.
- Runtime code has no Lua plugin dependencies. Resolve executables and test
  dependencies through `PATH`, Make/environment variables, or repo-relative
  paths. Keep machine-specific overrides in gitignored `local.mk`.

## Invariants

Architecture is the canonical ownership reference. Changes must preserve:

- Complete, validated dependencies for Models and the Agent Loop; message
  commits precede dependent work.
- Cancellation through Models, tools, child Runs, provider leases, and
  deferred destruction; completion and disposal once; stale callbacks unable
  to mutate newer state.
- Tool-free Sessions and fixed Profile, Workspace, and Session identity per
  Agent, with one independent activity lifecycle.
- Top-level Applet ownership of drafts, Agent registration and selection,
  Session claims, shared provider runtimes, and the Provider Shell.
- Explicit runtime sharing and coordination at the Service or Authentication
  boundary; request shaping receives copied request identity from the owning
  composition, and shared provider operations receive no Agent state.
- Request-scoped file preparation uses independent shared Service leases and
  content-key coordination. Credential changes and mutating management remain
  exclusive. Sessions retain image bytes; remote references stay in request
  copies and the separate provider cache.
- Copied semantic state for Views, content Trees from Renderers, Pane-owned
  interaction, Applet-owned native surfaces, and transactional publication.
  Headless Agents do not load UI modules.
- Verified regular-file replacement for bundled file tools.
- RegularFile relinquishes descriptor ownership before native close; a close
  error must not authorize retrying a potentially recycled descriptor.
  Preserve the error independently of resource ownership.
- Tool execution blocked when requested sandbox activation fails; host
  execution requires explicitly disabling sandboxing.
- Private atomic credential storage; credentials excluded from provider state
  and diagnostics; HTTP and conversation bodies excluded from provider
  diagnostics. Persistence uncertainty blocks later Store mutations.
- HTTP recording as an observer: mask protocol credentials, preserve model
  and ordinary provider bodies, and mask response bodies only when
  Authentication explicitly classifies them as sensitive.
  Bound response buffering and never spool classified sensitive bodies.

## Repository and documentation

- Work in this canonical checkout. Deployment or edits to copied
  installations require an explicit request.
- Preserve unrelated changes and generated local configuration.
- Track multi-step implementation in `TODO.md` when requested.
- Keep generated artifacts out of source changes: `.deps/`, `.coverage/`,
  `.test-data/`, and `.nvimlog`.

Each document has one job:

| Document | Purpose |
| --- | --- |
| `README.md` | Project introduction and concise setup |
| `doc/neoagent.txt` | Configuration, behavior, and APIs needed to use or extend Neoagent |
| `doc/applet.txt` | Applet package usage and API contracts |
| `architecture.md` | Stable ownership, lifecycle, and data flow needed to reason about system boundaries |
| `AGENTS.md` | Contributor constraints and development workflow |

Change documentation when existing guidance becomes incorrect or a reader
needs missing information to perform the document's stated task. A code change
alone does not require a documentation change. Routine fixes and refactors
that preserve documented contracts usually need no documentation edits.

Keep implementation mechanics in code and regression scenarios in tests.
Architecture should explain responsibilities, boundaries, and interactions
that guide future changes; omit local call ordering, guards, and bookkeeping
unless they are necessary to understand a system-wide contract. User and API
docs should explain what readers can do and rely on. Describe development
workflow and enforceable contributor constraints in this guide.

Revise the canonical explanation rather than appending a note for each fix.
Remove obsolete or duplicate guidance. Keep copyable examples and use real
provider/model names where helpful. Omit inventories available in the UI,
incidental styling, test mechanics, and narratives of fixed bugs or discarded
alternatives. Repeat facts only when needed to make a section usable on its
own; otherwise link. Use direct language; negative wording is appropriate for
guarantees, prohibitions, and errors.

## Dependencies and tests

Minimum: Neovim 0.10, curl 7.76, `rg`, `fd`, Python 3, Git, and Make.
Tests also require Mike Farah `yq` v4 on `PATH` to read YAML fixtures.
`make deps` installs pinned Plenary and LuaCov checkouts in `.deps/`.
Coverage also builds pinned CLuaCov with a C compiler (`CC`, or
`cc`) on Linux or macOS; `make coverage-deps` installs it separately. Native
Windows collection uses LuaCov alone, and CI generates the merged report on
Linux. CLuaCov accelerates collection and filters non-executable lines using
bytecode; LuaCov still measures line coverage.
`yq` remains optional for runtime recording; JSON recording needs no `yq`.
The large inline-image integration regressions require ImageMagick's `magick`
on `PATH`; they are skipped when it is unavailable. Native macOS CI installs
ImageMagick and runs them; the default image budget is also tested without it.

`make typecheck-deps` installs pinned EmmyLua checker/language-server binaries
and Neovim, libuv, and luassert definitions in `.deps/`. Run `make typecheck`
for static checking; it needs no network or running Neovim after setup. CI runs
the same target. `EMMYLUA_CHECK` in `local.mk` can override the checker executable.
Editors can use `.deps/emmylua/bin/emmylua_ls` with `.emmyrc.json`.

Every repository Lua file is checked, including tests, helpers, platform code,
and development scripts. New files are checked by default. All configured
warning/error diagnostics fail the gate; the full report is written to
`.test-data/typecheck/diagnostics.json`. Keep type contracts at their ownership
boundary, preserve runtime validation, and fix inaccurate contracts rather
than spreading `any`, casts, or diagnostic suppressions.
Redundant-condition diagnostics remain hints because typed entrypoints still
validate callers at runtime.

Typed tests import their assertions with `local assert = require("luassert")`.
The test declarations describe Plenary's Busted interface; production keeps
Lua's standard `assert` contract. Type existing behavioral tests without adding
tests of annotations or of the third-party checker itself.

`NVIM` defaults to `nvim` and `PLENARY_DIR` to `.deps/plenary.nvim`.
Copy `local.mk.example` to `local.mk` for machine-specific executable,
dependency, and `PATH` overrides.

Use the narrowest relevant suite during iteration:

```sh
make test-unit
make test-integration
make test-ui
make test
```

`make lint` checks shipped Lua statement layout with Neovim's bundled Lua
parser. Statements, including compound bodies, occupy separate lines from
surrounding code. LuaCov counts lines, so inline bodies can hide unexecuted
statements. Comments, string contents, and empty function bodies are allowed.
`make test` and CI run this check. StyLua 2.5.2 with `.stylua.toml` produces
the required layout; use `--verify` when reformatting shipped Lua.

`make test` (also `make test-fast`) runs all three suites without coverage or
terminal images. Integration tests replay HTTP recordings through the real
HTTP decoder and use in-memory browser callback connections, so they need no
network access. UI tests inspect isolated headless Neovim children.
`make test-http-live` runs the small localhost curl/callback suite;
`make test-native-sandbox` runs native enforcement tests and requires working
platform isolation. Neither is part of `make test`.
Windows CI also runs portable core, API, and storage tests alongside its
native platform suite.

`make benchmark-applet` checks container update budgets.
`make benchmark-transcript` measures streaming updates with a long response and
400 prior messages, checking latency, retained memory, and native mutations.
`make benchmark-submission` checks resume, durable acceptance, native transcript
publication, and request startup in a large persisted coding conversation with
retained images, using the real DeepSeek composition and a local HTTP backend.
Run benchmarks separately from other suites for useful timings. Linux stable
CI runs all three targets.

Coverage and terminal-image tests run in CI. Run `make coverage` or
`make test-terminal-images` locally only when the user requests those checks.
An explicit request to improve coverage authorizes coverage runs.
Terminal-image CI uses Kitty and Konsole under Xvfb, including selected tmux
paths; local runs skip missing terminal dependencies.

For every bug report, add a focused behavioral regression and verify that it
fails against the unmodified implementation for the reported reason. Then
implement the fix and verify the same test passes.

Tests must exercise product behavior or protect a concrete regression. Do not
test test-only helpers, fixtures, mock servers, runners, or coverage
infrastructure, or add module-loading assertions already implied by behavior.
Do not weaken validation, cancellation, or coverage collection to pass tests.

All waits must be predicate-based and bounded. Teardown must clean up
processes, timers, temporary directories, buffers, and windows.

Before completion:

- Run the relevant fast suites and `make test`; keep health behavior valid.
- Run `make typecheck` when changing Lua code or type-check configuration.
- Check documentation against the reader needs above; edit only where needed.
- Require 100% shipped Lua line coverage, with zero missed lines rather
  than a rounded percentage. Every file under `lua/applet/`, `lua/neoagent/`,
  and `plugin/` must appear, including files normal tests do not load.
  CI merges native Linux, macOS, and Windows counters before enforcing the
  requirement; run platform-specific tests on their actual host.
  CI also enforces terminal-image behavior.

### Improving coverage

1. Run `make coverage` for a fresh local baseline. It clears `.coverage/`,
   records source hashes, runs the instrumented unit, replay integration and
   UI suites, generates the LuaCov report, and checks for missed lines.
   A threshold failure leaves the report available; resolve test failures
   before using it. `make coverage-ci` additionally runs live HTTP and native
   sandbox tests. A single host's report can still miss foreign-platform
   behavior; the authoritative gate uses the union of all three native hosts.
2. Read `.coverage/luacov.report.out`: its final summary lists hits and misses
   per file; annotated source marks missed lines with `***0` (the number of
   asterisks varies). Find them with:

   ```sh
   rg -n '\*+0' .coverage/luacov.report.out
   ```

   These are report line numbers; locate the corresponding source. Choose
   uncovered behavior worth protecting, such as failure recovery or
   cancellation, and assert its observable outcome. Keep injection internal
   and restore patched dependencies during cleanup. Prefer replay integration
   and real native platform tests to simulated environments.
3. Iterate with the relevant suite. For example, after a fresh baseline:

   ```sh
   NEOAGENT_COVERAGE=1 make test-integration
   make coverage-report coverage-check
   ```

   Instrumented processes write independent LuaCov files in `.coverage/raw/`.
   Reporting combines their counters without losing overlapping child-process
   writes. Runs can accumulate when only tests change; shipped-source changes
   require a fresh collection. Source hashes prevent using stale counters.
   Run suites sequentially because they share other test state.
4. Finish with `make test` and a fresh `make coverage`. CI uses
   `make coverage-collect` on Linux and macOS, and the native and portable
   Windows suites with LuaCov enabled. Each exports `.coverage/collection.json`.
   To reproduce the matrix report from downloaded collections:

   ```sh
   python3 scripts/coverage.py merge .coverage/native/*/collection.json \
     --require-platforms Linux Darwin Windows
   make coverage-render coverage-check
   ```

   Merging requires identical shipped sources and a complete file inventory.
   It normalizes checkout paths and CRLF line endings, then sums ordinary
   LuaCov counters. A foreign platform is never excluded to pass the gate.

## Reproducing provider issues

Look for the user's relevant recordings under `~/.local/state/nvim/neoagent`
(or their configured recording directory) before inventing provider responses.
If evidence is missing, ask them to enable recording, restart and
reproduce the interaction. Start with default rolling retention; use
`retention = "all"` only when the last exchange cannot explain the issue.
Inspect metadata first and read only the content needed to understand the
failure. Originals are local evidence only: never use personal conversation
data in reproduction inputs, regression fixtures, test assertions, or docs.
Create a synthetic adaptation that preserves the relevant protocol structure
and failure. Replace all conversation content, including prompts, responses,
thinking, tool arguments/results, code and attachments, plus private metadata
and credentials. Trimming a conversation or masking secrets is not sufficient.
Keep user recordings unchanged; see the adaptation workflow below.
Keep real Authentication and HTTP decoding in the regression. Do not invoke a
live API merely to create test data.

See [HTTP regression recordings](tests/recordings/README.md) for the capture,
validation and promotion workflow, scenario matching/dependencies, and the
provider/API inventory with missing real captures. Run regression scenarios
with `make test-integration`; curl parsing belongs in `make test-http-live`.

## Interactive UI debugging

Use a disposable tmux session for visual behavior that needs a real terminal.
Start from this checkout with it prepended to `runtimepath`:

```sh
tmux new-session -d -s neoagent-debug -c "$PWD" \
  "nvim -n -i NONE --cmd 'set runtimepath^=$PWD' README.md"
tmux send-keys -t neoagent-debug Escape ':Neoagent' Enter
tmux capture-pane -p -e -t neoagent-debug -S -100
tmux attach-session -t neoagent-debug
tmux kill-session -t neoagent-debug
```

Use `nvim` from `PATH` or the machine's `NVIM` override in `local.mk`.
The normal user config loads intentionally; use a disposable config when
isolation is required. `-n -i NONE` avoids swap and ShaDa side effects.

Send prompt text with `tmux send-keys -l`, then send control keys separately.
The default submit key is Enter. Do not submit to a metered or external Model
without explicit user authorization. Capture both streaming and completed
states, retaining ANSI escapes (`capture-pane -e`) when inspecting colors.
Always close the disposable session.

## Commits

Use Conventional Commit subjects: `<type>(<scope>): <summary>`. Omit scope
when there is no single subsystem. Choose the direct type: `feat`, `fix`,
`test`, `docs`, `refactor`, or `chore`. Use an imperative, lowercase summary
with no final period; proper names retain capitalization.

For non-trivial commits, follow the subject with a blank line, a concise
paragraph explaining the change's structure, another blank line, and bullets
describing behavior and coverage. Start bullets with imperative verbs, end
them with periods, and wrap every body line at 72 columns. Keep commits
focused and describe only staged changes.
