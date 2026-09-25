.PHONY: check test lint manifest live

check: lint manifest test ## offline checks (what CI runs)

test: ## offline tests against a mock herdr
	./tests/test.sh

lint:
	shellcheck herdr-mark tests/*.sh

manifest:
	python3 -c 'import pathlib, tomllib; tomllib.loads(pathlib.Path("herdr-plugin.toml").read_text())'

live: ## live tests against the running herdr server (scratch workspaces)
	./tests/live.sh
