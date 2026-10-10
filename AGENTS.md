# Neoagent contributor guide

Read [architecture.md](architecture.md) before changing ownership or data flow.
This guide covers contributor constraints and workflow; keep subsystem contracts
in architecture and implementation details in code.

## Development rules

- Use plain Lua tables, functions, and constructors with explicit dependencies.
  Add abstractions for concrete uses. Prefer a cohesive refactor to patches that
  preserve a flawed ownership boundary.
- Preserve the dependency boundaries in architecture. Keep execution policy in
  the composition and effects in the component that owns them.
- Establish resource ownership before asynchronous work. Cancellation must not
  abandon cleanup or its diagnostic recipient. Use predicate-based, bounded
  waits and prevent stale callbacks from changing newer state.
- Keep test injection internal. Public extension points need a shipped
  composition or concrete integration, not just a test double.
- Maintain one configuration and data shape. Remove superseded formats; add
  migrations or negotiation only for existing user data or independently
  released components. Exact storage and process protocol markers are allowed.
- Runtime code has no Lua plugin dependencies. Resolve executables through
  `PATH`, Make/environment variables, or repo-relative paths. Put machine
  overrides in gitignored `local.mk`.
- Support metered and subscription access where a provider documents a
  third-party integration surface.
- Work in this canonical checkout. Editing or deploying copied installations
  requires an explicit request. Preserve unrelated changes and local config.
- Keep generated `.deps/`, `.coverage/`, `.test-data/`, and `.nvimlog` artifacts
  out of commits. Use `TODO.md` for multi-step tracking when requested.

## Documentation

| Document | Purpose |
| --- | --- |
| `README.md` | Introduction and quick setup |
| `doc/neoagent.txt` | User behavior, configuration, and Lua APIs |
| `doc/applet.txt` | Applet usage and API contracts |
| `architecture.md` | System boundaries, ownership, and data flow |
| `AGENTS.md` | Contributor constraints and workflow |
| `tests/recordings/README.md` | Provider reproduction and replay fixtures |

Update the canonical explanation when a contract changes. Do not append a
narrative for each fix or repeat implementation details across documents.
Keep algorithms and local sequencing in code, regression scenarios in tests,
and examples short and copyable. Code changes alone do not require doc changes.

## Setup and checks

Development requires Neovim 0.10+, curl 7.76+, `rg`, `fd`, Python 3, Git, Make,
and Mike Farah `yq` v4. Image conversion regressions also need ImageMagick's
`magick`; native macOS CI runs them. Install pinned test and checker dependencies:

```sh
make deps
make typecheck-deps
```

Copy `local.mk.example` to `local.mk` for overrides such as `NVIM`,
`PLENARY_DIR`, `EMMYLUA_CHECK`, and `PATH`. The defaults use `nvim` from `PATH`
and dependencies under `.deps/`.

| Command | Checks |
| --- | --- |
| `make test-unit` | Unit behavior |
| `make test-integration` | HTTP replay and composition, without network access |
| `make test-ui` | UI behavior in isolated Neovim children |
| `make test` | All three suites and Lua layout lint |
| `make typecheck` | Every repository Lua file, including tests and scripts |
| `make test-http-live` | Localhost curl and callback transport |
| `make test-native-sandbox` | Native sandbox enforcement on the current host |
| `make test-windows` | Native Windows behavior |

Use the narrowest relevant suite during iteration. Run suites sequentially;
they share test state. Before completing code changes, run relevant suites and
`make test`; run `make typecheck` for Lua or checker changes. Check platform
behavior on its actual host and keep health checks accurate. For documentation
only, verify examples, links, help tags, and `git diff --check`.

`make lint` requires Lua statements and compound bodies on separate lines so
line coverage cannot hide unexecuted statements. StyLua 2.5.2 with
`.stylua.toml` produces this layout; use `--verify` when reformatting.

Fix type contracts at their owner. Preserve runtime validation; do not spread
`any`, casts, or diagnostic suppressions to pass the checker. Its report is
`.test-data/typecheck/diagnostics.json`. Typed tests use
`local assert = require("luassert")`; production uses Lua's standard assertion.

For bug fixes, first add a focused behavioral regression and verify that it
fails against the unmodified implementation for the reported reason. Then
verify it passes with the fix. Test product behavior, not test helpers,
fixtures, annotations, or third-party infrastructure. Do not weaken validation,
cancellation, or coverage collection to pass tests. Restore injected
dependencies and clean up processes, timers, files, buffers, and windows.

Run benchmarks separately from suites for useful timings:
`make benchmark-applet`, `make benchmark-transcript`,
`make benchmark-submission`, and `make benchmark-compaction`. CI enforces
their budgets.

## Coverage

CI requires zero missed shipped Lua lines, including every file under
`lua/applet/`, `lua/neoagent/`, and `plugin/`. The authoritative report merges
Linux, macOS, and Windows execution. The sole approved exception is marked in
[fork_exec.lua](lua/neoagent/subprocess/fork_exec.lua); preserve its native
behavioral tests. Do not expand exclusions to pass the gate.

Run coverage and `make test-terminal-images` locally only when requested.
A request to improve coverage authorizes coverage runs. CI runs both.
Linux and macOS coverage need a C compiler (`CC`, or `cc`);
`make coverage-deps` installs CLuaCov. Windows uses LuaCov.

When improving coverage:

1. Run `make coverage` for a fresh baseline. Resolve test failures before using
   `.coverage/luacov.report.out`; find missed lines with
   `rg -n '\*+0' .coverage/luacov.report.out`.
2. Add behavioral coverage for the missing paths. Prefer real native execution
   over simulating another platform. With only test changes, accumulate runs:

   ```sh
   NEOAGENT_COVERAGE=1 make test-integration
   make coverage-report coverage-check
   ```

   Shipped-source changes require fresh collection. Finish with `make test`
   and a fresh `make coverage`.
3. CI collects all three native platforms; `make coverage-collect` covers Linux
   and macOS. Reproduce the combined report from downloaded artifacts:

   ```sh
   python3 scripts/coverage.py merge .coverage/native/*/collection.json \
     --require-platforms Linux Darwin Windows
   make coverage-render coverage-check
   ```

   Sources must match and every shipped file must be present. Do not exclude
   foreign-platform code to make a local report pass.

## Reproducing issues

For provider issues, inspect relevant recordings under
`~/.local/state/nvim/neoagent` before inventing responses. Follow the
[recording workflow](tests/recordings/README.md): inspect metadata first,
preserve originals, and use wholly synthetic content in regression fixtures.
Do not call live APIs merely to create test data.

For real-terminal UI debugging, use a disposable tmux session with this checkout
first on `runtimepath`:

```sh
tmux new-session -d -s neoagent-debug -c "$PWD" \
  "nvim -n -i NONE --cmd 'set runtimepath^=$PWD' README.md"
tmux send-keys -t neoagent-debug Escape ':Neoagent' Enter
tmux capture-pane -p -e -t neoagent-debug -S -100
tmux attach-session -t neoagent-debug
tmux kill-session -t neoagent-debug
```

Use the configured `NVIM` executable when applicable. This loads the user's
config; use a disposable config when isolation is needed. Send text with
`tmux send-keys -l`, then control keys separately. Capture streaming and final
states with ANSI colors. Always close the session. Do not submit to an external
or metered Model without explicit user authorization.

## Commits

Use Conventional Commit subjects: `<type>(<scope>): <summary>`. Choose `feat`,
`fix`, `test`, `docs`, `refactor`, or `chore`; omit scope when none fits. Use an
imperative, lowercase summary without a final period; retain proper-name case.

For non-trivial changes, add a concise paragraph and bullets describing behavior
and validation. Start bullets with imperative verbs, end them with periods,
and wrap body lines at 72 columns. Keep commits focused on their staged changes.
