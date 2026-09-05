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
  boundary; provider operations receive no Agent state.
- Copied semantic state for Views, content Trees from Renderers, Pane-owned
  interaction, Applet-owned native surfaces, and transactional publication.
  Headless Agents do not load UI modules.
- Verified regular-file replacement for bundled file tools.
- Private atomic credential storage; credentials excluded from provider state
  and diagnostics; HTTP and conversation bodies excluded from provider
  diagnostics. Persistence uncertainty blocks later Store mutations.
- HTTP recording as an observer: mask protocol credentials, preserve model
  and ordinary provider bodies, and mask response bodies only when
  Authentication explicitly classifies them as sensitive.

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
`make deps` installs pinned Plenary and LuaCov checkouts in `.deps/`.

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

`make test` (also `make test-fast`) runs all three suites without coverage or
terminal images. Integration tests use a localhost Python mock server and real
curl. UI tests inspect isolated headless Neovim children.

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
- Check documentation against the reader needs above; edit only where needed.
- Preserve aggregate shipped Lua line coverage strictly above 99.60%.
  Every file under `lua/applet/`, `lua/neoagent/`, and `plugin/` must appear
  in the LuaCov report, including files normal tests do not load. Coverage
  under `lua/applet/` must be 100%.
  CI enforces coverage and terminal-image behavior.

### Improving coverage

1. Run `make coverage` for a fresh baseline. It clears `.coverage/`, runs
   the instrumented suites with sandbox checks required, generates the report,
   and checks the thresholds. A threshold failure still leaves the report
   available for inspection. Resolve test failures before using the result.
2. Read `.coverage/luacov.report.out`: its final summary lists hits and misses
   per file; annotated source marks missed lines with `***0` (the number of
   asterisks varies). Find them with:

   ```sh
   rg -n '\*+0' .coverage/luacov.report.out
   ```

   These are report line numbers; locate the corresponding code in the source.
   Choose uncovered behavior worth protecting, such as failure recovery or
   cancellation, and add tests that assert its observable outcome. Keep
   injection internal and restore patched dependencies during cleanup.
3. Iterate with the relevant suite. For example:

   ```sh
   NEOAGENT_COVERAGE=1 make test-unit
   make coverage-report coverage-check
   ```

   Instrumented runs accumulate statistics in `.coverage/luacov.stats.out`.
   The report and check targets do not run tests or clear those statistics.
   Accumulated results help assess progress but can contain stale coverage
   after source edits. Run suites sequentially; they share test state.
4. Finish with `make test` and a fresh `make coverage` to verify the thresholds
   above using only the final code and tests. The displayed percentage is
   rounded; the check uses the unrounded ratio. A requested margin target
   does not change the enforced threshold.

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
