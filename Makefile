-include local.mk

NVIM ?= nvim
PLENARY_DIR ?= $(CURDIR)/.deps/plenary.nvim
TEST_CMD = $(NVIM) --headless --noplugin -u tests/minimal_init.lua
TEST_ENV = NEOAGENT_NVIM=$(NVIM) PLENARY_DIR=$(PLENARY_DIR)
PLENARY_COMMIT = 1ee0ded0564accb986115039a1798a95917b789c
LUACOV_COMMIT = b1f9eae400da976b93edb7f94cf5d05f538a0655

.PHONY: deps test test-unit test-integration test-ui coverage coverage-report coverage-check clean

.deps/plenary.nvim/.git:
	mkdir -p .deps
	git clone https://github.com/nvim-lua/plenary.nvim.git .deps/plenary.nvim

.deps/luacov/.git:
	mkdir -p .deps
	git clone https://github.com/lunarmodules/luacov.git .deps/luacov

deps: .deps/plenary.nvim/.git .deps/luacov/.git
	git -C .deps/plenary.nvim checkout $(PLENARY_COMMIT)
	git -C .deps/luacov checkout $(LUACOV_COMMIT)

test: test-unit test-integration test-ui

test-unit:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/unit { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true }"

test-integration:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/integration { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true }"

test-ui:
	$(TEST_ENV) $(TEST_CMD) -c "PlenaryBustedDirectory tests/ui { minimal_init = './tests/minimal_init.lua', nvim_cmd = './scripts/nvim', sequential = true }"

coverage:
	rm -rf .coverage
	NEOAGENT_COVERAGE=1 $(MAKE) test
	$(MAKE) coverage-report
	$(MAKE) coverage-check

coverage-report:
	mkdir -p .coverage
	$(NVIM) --headless -u NONE -i NONE -c "set rtp^=. | lua package.path = './.deps/luacov/src/?.lua;./.deps/luacov/src/?/init.lua;' .. package.path; require('luacov.runner').run_report('.luacov')" -c qa

coverage-check:
	python3 scripts/check_coverage.py .coverage/luacov.report.out 90

clean:
	rm -rf .test-data .coverage
