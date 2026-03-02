.PHONY: test test-lua test-node lint fmt fmt-check

PLENARY_DIR := .tests/plenary.nvim

$(PLENARY_DIR):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $@

test: test-lua test-node

test-lua: $(PLENARY_DIR)
	nvim --headless --noplugin \
		-u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"

test-node:
	cd node && npm install --silent 2>/dev/null
	cd tests/node && npm install --silent 2>/dev/null
	node tests/node/auth-cookie.test.js
	node tests/node/integration.test.js

lint:
	luacheck lua/ tests/ plugin/

fmt:
	stylua lua/ tests/ plugin/

fmt-check:
	stylua --check lua/ tests/ plugin/
