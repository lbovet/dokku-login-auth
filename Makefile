SHELL := /bin/bash

PLUGIN_FILES := install commands nginx-pre-reload post-delete functions command-functions help-functions
SUBCOMMAND_FILES := $(wildcard subcommands/*)

.PHONY: test lint

test:
	bats tests/

lint:
	shellcheck -x $(PLUGIN_FILES) $(SUBCOMMAND_FILES)
	shellcheck -x tests/smoke.sh
