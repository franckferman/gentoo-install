# gentoo-install — development targets
#
# Everything CI runs is runnable here, with the same arguments, so a failure in
# a pull request can be reproduced without reading the workflow file.

SHELL      := /usr/bin/env bash
PREFIX     ?= /usr/local
DESTDIR    ?=
BINDIR      = $(DESTDIR)$(PREFIX)/bin
LIBDIR      = $(DESTDIR)$(PREFIX)/lib/gentoo-install
DATADIR     = $(DESTDIR)$(PREFIX)/share/gentoo-install

ENTRY       = gentoo-install.sh
SHELL_FILES = $(ENTRY) $(wildcard lib/*.sh) $(wildcard steps/*.sh) \
              $(wildcard variants/*/*.sh) $(wildcard tools/*.sh)

# Every check runs natively when the tool is installed and in a container when it
# is not. A lint target that only works on a machine with three extra packages
# is a lint target nobody runs, and the whole point is that a contributor can
# reproduce CI before opening a pull request.
DOCKER           ?= docker
SHELLCHECK_IMAGE ?= koalaman/shellcheck:stable
SHFMT_IMAGE      ?= mvdan/shfmt:latest
BATS_IMAGE       ?= bats/bats:latest
IN_CONTAINER      = $(DOCKER) run --rm -v "$(CURDIR)":/mnt -w /mnt

# The one image that writes into the checkout gets the caller's own id.
# `make format` rewrites every script, and a container doing that as root
# leaves root-owned files in the contributor's own tree — this repository
# collected two that way, and the next edit failed with "Permission denied" on
# a file its author owns. The linters and the test suite are left alone: they
# write nothing here, and bats needs to be root inside its own container to
# exercise the tools' root checks.
DOCKER_USER      ?= $(shell id -u):$(shell id -g)
IN_CONTAINER_RW   = $(DOCKER) run --rm --user "$(DOCKER_USER)" \
                    -v "$(CURDIR)":/mnt -w /mnt

SHELLCHECK := $(shell command -v shellcheck 2>/dev/null || echo '$(IN_CONTAINER) $(SHELLCHECK_IMAGE)')
SHFMT      := $(shell command -v shfmt      2>/dev/null || echo '$(IN_CONTAINER) $(SHFMT_IMAGE)')
SHFMT_RW   := $(shell command -v shfmt      2>/dev/null || echo '$(IN_CONTAINER_RW) $(SHFMT_IMAGE)')
BATS       := $(shell command -v bats       2>/dev/null || echo '$(IN_CONTAINER) $(BATS_IMAGE)')

SHFMT_ARGS = --indent 2 --case-indent --binary-next-line

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@printf 'gentoo-install — make targets\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[1;34m%-10s\033[0m %s\n", $$1, $$2}'
	@printf '\nVersion comes from %s and from nowhere else.\n' '$(ENTRY)'

.PHONY: lint
lint: ## Run shellcheck, check formatting, and parse every script
	$(SHELLCHECK) $(SHELL_FILES)
	$(SHFMT) --diff $(SHFMT_ARGS) $(SHELL_FILES)
	bash -n $(SHELL_FILES)

.PHONY: format
format: ## Rewrite every script in the project style
	$(SHFMT_RW) --write $(SHFMT_ARGS) $(SHELL_FILES)

.PHONY: test
test: ## Run the bats suite
	@if compgen -G 'tests/*.bats' >/dev/null; then \
	  $(BATS) tests; \
	else \
	  echo "no tests yet under tests/"; \
	fi

.PHONY: check
check: lint test ## lint + test

.PHONY: install
install: ## Install into $(PREFIX)
	install -d '$(BINDIR)' '$(LIBDIR)' '$(DATADIR)/data'
	install -m 0755 '$(ENTRY)' '$(BINDIR)/gentoo-install'
	install -m 0644 lib/*.sh '$(LIBDIR)/'
	install -m 0644 data/*.tsv '$(DATADIR)/data/'
	@printf 'Installed. Point GI_LIB_DIR at %s if you move the libraries.\n' '$(LIBDIR)'

.PHONY: uninstall
uninstall: ## Remove what install put down
	rm -f '$(BINDIR)/gentoo-install'
	rm -rf '$(LIBDIR)' '$(DATADIR)'

.PHONY: version
version: ## Print the version the entry point declares
	@./$(ENTRY) --version
