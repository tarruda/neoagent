-include local.mk

NVIM ?= nvim
EMMYLUA_CHECK ?= $(CURDIR)/.deps/emmylua/bin/emmylua_check
PLENARY_DIR ?= $(CURDIR)/.deps/plenary.nvim
TEST_CMD = $(NVIM) --headless --noplugin -u tests/minimal_init.lua
TEST_ENV = PATH=$(dir $(NVIM)):$(PATH) NEOAGENT_NVIM=$(NVIM) PLENARY_DIR=$(PLENARY_DIR)
UI_TEST_TIMEOUT ?= 120000
PLENARY_COMMIT = 74b06c6c75e4eeb3108ec01852001636d85a932b
LUACOV_COMMIT = b1f9eae400da976b93edb7f94cf5d05f538a0655

.PHONY: deps typecheck-deps typecheck lint test test-fast test-unit test-integration test-ui test-terminal-images test-http-live test-native-sandbox test-windows benchmark-applet benchmark-transcript benchmark-submission coverage-deps coverage coverage-ci coverage-collect coverage-report coverage-render coverage-check clean

typecheck-deps:
	python3 scripts/typecheck_deps.py

typecheck:
	python3 scripts/typecheck.py --checker "$(EMMYLUA_CHECK)"

lint:
	$(NVIM) --headless -u NONE -i NONE -l scripts/check_statement_layout.lua

.deps/plenary.nvim/.git:
	mkdir -p .deps
	git clone https://github.com/nvim-lua/plenary.nvim.git .deps/plenary.nvim

.deps/luacov/.git:
	mkdir -p .deps
	git clone https://github.com/lunarmodules/luacov.git .deps/luacov

deps: .deps/plenary.nvim/.git .deps/luacov/.git
	git -C .deps/plenary.nvim checkout $(PLENARY_COMMIT)
	git -C .deps/luacov checkout $(LUACOV_COMMIT)

test: test-fast

test-fast: lint test-unit test-integration test-ui

test-unit:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/unit { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true }"

test-integration:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/integration { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true }"

test-ui:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/ui { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true, timeout = $(UI_TEST_TIMEOUT) }"

test-http-live:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/http_live { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true }"

test-native-sandbox:
	$(TEST_ENV) NEOAGENT_REQUIRE_SANDBOX=1 $(TEST_CMD) -c "PlenaryBustedDirectory tests/native_sandbox { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true }"

test-terminal-images:
	$(TEST_ENV) python3 tests/terminal/image_resume.py
	$(TEST_ENV) python3 tests/terminal/image_smoke.py
	$(TEST_ENV) python3 tests/terminal/image_harness.py

# Fresh sandbox identities cold-start PowerShell on hosted Windows runners.
# This timeout covers the complete spec file, including that startup.
test-windows:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/windows { minimal_init = './tests/minimal_init.lua', sequential = true, timeout = 240000 }"

benchmark-applet:
	$(TEST_ENV) APPLET_BENCH_ENFORCE=1 APPLET_BENCH_ITERATIONS=1000 \
		$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-l scripts/benchmark-applet-containers.lua

benchmark-transcript:
	$(TEST_ENV) NEOAGENT_TRANSCRIPT_BENCH_ENFORCE=1 \
		$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-l scripts/benchmark-transcript.lua

benchmark-submission:
	$(TEST_ENV) NEOAGENT_SUBMISSION_BENCH_ENFORCE=1 \
		$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-l scripts/benchmark-submission.lua

coverage: coverage-deps
	python3 scripts/coverage.py start
	NEOAGENT_COVERAGE=1 UI_TEST_TIMEOUT=240000 $(MAKE) test-fast
	$(MAKE) coverage-report
	$(MAKE) coverage-check

coverage-ci: coverage-collect
	$(MAKE) coverage-report
	$(MAKE) coverage-check

coverage-collect: coverage-deps
	python3 scripts/coverage.py start
	NEOAGENT_COVERAGE=1 UI_TEST_TIMEOUT=240000 $(MAKE) test-fast test-http-live test-native-sandbox
	python3 scripts/coverage.py export

coverage-report:
	python3 scripts/coverage.py export
	python3 scripts/coverage.py merge .coverage/collection.json
	$(MAKE) coverage-render

.deps/coverage-native/lib/cluacov/deepactivelines.so: scripts/coverage_deps.py
	CC="$(CC)" python3 scripts/coverage_deps.py

.deps/coverage-native/lib/cluacov/hook.so: .deps/coverage-native/lib/cluacov/deepactivelines.so
	CC="$(CC)" python3 scripts/coverage_deps.py

coverage-deps: .deps/coverage-native/lib/cluacov/deepactivelines.so .deps/coverage-native/lib/cluacov/hook.so

coverage-render: coverage-deps
	$(NVIM) --headless -u NONE -i NONE -l scripts/coverage_report.lua

coverage-check:
	python3 scripts/check_coverage.py .coverage/luacov.report.out

clean:
	rm -rf .test-data .coverage
