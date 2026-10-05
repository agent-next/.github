.PHONY: setup check

setup:
	@echo "docs-only repo: nothing to install (needs bash and jq)"

check:
	bash tests/agent-merge.test.sh
	bash tests/agent-review.test.sh
