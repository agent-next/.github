.PHONY: setup check

setup:
	@echo "nothing to install (check needs bash and jq)"

check:
	bash tests/agent-merge.test.sh
	bash tests/agent-review.test.sh
	bash tests/repo-baseline.test.sh
