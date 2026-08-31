-include local.mk

NVIM ?= nvim
PLENARY_DIR ?= $(CURDIR)/.deps/plenary.nvim
TEST_CMD = $(NVIM) --headless --noplugin -u tests/minimal_init.lua
TEST_ENV = PATH=$(dir $(NVIM)):$(PATH) NEOAGENT_NVIM=$(NVIM) PLENARY_DIR=$(PLENARY_DIR)
UI_TEST_TIMEOUT ?= 120000
PLENARY_COMMIT = 74b06c6c75e4eeb3108ec01852001636d85a932b
LUACOV_COMMIT = b1f9eae400da976b93edb7f94cf5d05f538a0655

.PHONY: deps test test-fast test-unit test-integration test-ui test-terminal-images test-windows benchmark-applet coverage coverage-report coverage-check clean

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

test-fast: test-unit test-integration test-ui

test-unit:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/unit { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true }"

test-integration:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/integration { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true }"

test-ui:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/ui { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true, timeout = $(UI_TEST_TIMEOUT) }"

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

coverage:
	rm -rf .coverage
	NEOAGENT_COVERAGE=1 NEOAGENT_REQUIRE_SANDBOX=1 UI_TEST_TIMEOUT=240000 $(MAKE) test-fast
	$(MAKE) coverage-report
	$(MAKE) coverage-check

coverage-report:
	mkdir -p .coverage
	$(NVIM) --headless -u NONE -i NONE -c "set rtp^=. | lua package.path = './.deps/luacov/src/?.lua;./.deps/luacov/src/?/init.lua;' .. package.path; require('luacov.runner').run_report('.luacov')" -c qa

coverage-check:
	python3 scripts/check_coverage.py .coverage/luacov.report.out 99.5

clean:
	rm -rf .test-data .coverage
