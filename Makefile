.PHONY: setup check

setup:
	@echo "docs-only repo: nothing to install (needs python3 and bash)"

check:
	python3 scripts/check-docs.py
	bash tests/agent-merge.test.sh
	bash tests/agent-review.test.sh
