.PHONY: setup check

setup:
	@echo "nothing to install (check needs bash)"

# The merge-gate scripts were removed from the public tree (G6 scrub). With no scripts or
# tests left, check runs the cheapest real validation: the required files of the repo
# baseline are present and non-empty.
check:
	@bash -eu -c 'for f in AGENT-STANDARD.md AGENTS.md CLAUDE.md Makefile CODEOWNERS \
	  CODE_OF_CONDUCT.md CONTRIBUTING.md SECURITY.md FUNDING.yml PULL_REQUEST_TEMPLATE.md \
	  ROADMAP.md profile/README.md ISSUE_TEMPLATE/config.yml ISSUE_TEMPLATE/bug_report.md \
	  ISSUE_TEMPLATE/feature_request.md; do \
	  [ -s "$$f" ] || { echo "missing or empty: $$f"; exit 1; }; done; echo "baseline docs present"'
