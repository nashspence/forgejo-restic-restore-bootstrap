.DEFAULT_GOAL := help
.PHONY: help

help:
	@printf '%s\n' \
		'Install test dependencies: python -m pip install --require-hashes --only-binary=:all: -r requirements-test.txt' \
		'Run offline recovery tests: python -m pytest -q tests' \
		'For recovery with a private profile, see README.md.'
