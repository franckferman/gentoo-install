#!/usr/bin/env bats
#
# gentoo-install — repository hygiene
# ----------------------------------------------------------------------------
# This project was extracted from a private installer that ran on named
# machines inside one company. Nothing of that provenance may ship, and the
# checks that catch it have to be mechanical: a reviewer reading a 650-line
# README will not spot one hostname.
#
# The rest of this file holds DESIGN.md §2 and §14 to account: one shebang, one
# `set -euo pipefail`, one declared version, and every shell file covered by the
# same globs `make lint` uses.
#

bats_require_minimum_version 1.5.0

load helper

# --------------------------------------------------------------------------- #
#  Provenance                                                                 #
# --------------------------------------------------------------------------- #
# The tokens are the names, the abbreviations and the identifier prefixes that
# belonged to the private repository. GPS_ was a variable prefix, matric a
# personnel identifier, the rest are host and company names.
GI_INTERNAL_TOKENS='trinity|cagip|ca-gip|matric|gundabad|thrain|keepass|gps_'

@test "no internal reference from the private repository may ship" {
  local file hits=""

  # gi_scan_files covers every file in the repository except three, and each
  # exclusion has a reason:
  #   tests/            this suite has to spell the tokens in order to look for
  #                     them, so scanning itself would always fail.
  #   docs/REPRISE.md   the French working memory. Its own to-do list quotes
  #   docs/research/    three of these tokens as the thing to check for, and
  #                     "matric" is a substring of the French "matrice"
  #                     (matrix), which the research reports use throughout.
  #                     The next test scans both with the tokens that do not
  #                     collide.
  while IFS= read -r file; do
    if grep -I -qniE -- "$GI_INTERNAL_TOKENS" "$file" 2>/dev/null; then
      hits+="$(grep -I -niE -- "$GI_INTERNAL_TOKENS" "$file" | sed "s#^#  ${file#"${GI_ROOT}/"}:#")"$'\n'
    fi
  done < <(gi_scan_files)

  if [[ -n "$hits" ]]; then
    printf 'internal references found in files that ship:\n%s' "$hits" >&2
    return 1
  fi
}

@test "the French working notes may name an internal system only where they ask for the check" {
  # Everything the previous test cannot scan, scanned with the tokens that do
  # not collide with the prose of those two documents — including matricule,
  # the full form that "matric" was shortened from.
  local tokens='gundabad|thrain|ca-gip|keepass|matricule'
  local file hits=""

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    if grep -I -qniE -- "$tokens" "$file" 2>/dev/null; then
      hits+="$(grep -I -niE -- "$tokens" "$file" | sed "s#^#  ${file#"${GI_ROOT}/"}:#")"$'\n'
    fi
  done < <(find "${GI_ROOT}/docs/research" "${GI_ROOT}/docs/REPRISE.md" -type f 2>/dev/null | sort)

  if [[ -n "$hits" ]]; then
    printf 'internal references found in the working notes:\n%s' "$hits" >&2
    return 1
  fi
}

# --------------------------------------------------------------------------- #
#  One version, in one file (DESIGN.md §14)                                   #
# --------------------------------------------------------------------------- #
@test "exactly one file may declare VERSION" {
  # Three of the author's repositories carry one version in the script and
  # another in the README, and nothing ever tells them apart.
  local file declarers=""

  while IFS= read -r file; do
    if grep -qE '^[[:space:]]*(readonly[[:space:]]+|export[[:space:]]+|declare[[:space:]]+-[a-zA-Z]+[[:space:]]+)?VERSION=' "$file"; then
      declarers+="${file#"${GI_ROOT}/"} "
    fi
  done < <(gi_shell_files)

  [ "$declarers" = "gentoo-install.sh " ] || {
    printf 'VERSION is declared in: %s\n' "$declarers" >&2
    printf 'DESIGN.md §14: once, in gentoo-install.sh, and read from there.\n' >&2
    return 1
  }
}

@test "no document may quote a version other than the one the entry point declares" {
  local version file line found wrong=""

  version="$(gi_capture 'printf "%s\n" "$VERSION"')"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]

  # URLs are stripped first: a link to keepachangelog.com/en/1.1.0/ or to a
  # release tag names somebody else's version, or the same one twice.
  for file in README.md CHANGELOG.md CONTRIBUTING.md Makefile \
    docs/DESIGN.md docs/index.html .github/workflows/ci.yml \
    .github/workflows/static.yml; do
    [[ -f "${GI_ROOT}/${file}" ]] || continue
    while IFS= read -r found; do
      [[ "$found" == "$version" ]] || wrong+="  ${file}: ${found}"$'\n'
    done < <(sed -E 's#https?://[^[:space:])"]*##g' "${GI_ROOT}/${file}" \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  done

  if [[ -n "$wrong" ]]; then
    printf 'gentoo-install.sh declares %s; these say otherwise:\n%s' "$version" "$wrong" >&2
    return 1
  fi
}

@test "the licence file must exist and the README must name the same licence" {
  [ -f "${GI_ROOT}/LICENSE" ]
  grep -q 'GNU AFFERO GENERAL PUBLIC LICENSE' "${GI_ROOT}/LICENSE"
  grep -qi 'AGPL' "${GI_ROOT}/README.md"
}

# --------------------------------------------------------------------------- #
#  The header every file carries (DESIGN.md §2)                               #
# --------------------------------------------------------------------------- #
@test "every shell file must parse" {
  local file complaint broken=""

  while IFS= read -r file; do
    complaint="$(bash -n "$file" 2>&1)" && continue
    broken+="  ${file#"${GI_ROOT}/"}: ${complaint}"$'\n'
  done < <(gi_shell_files)

  if [[ -n "$broken" ]]; then
    printf 'bash -n rejects:\n%s' "$broken" >&2
    return 1
  fi
}

@test "every shell file must declare set -euo pipefail" {
  # DESIGN.md §2: none of the author's public post-install scripts have it, and
  # all of them have bugs it would have caught.
  local file missing=""

  while IFS= read -r file; do
    grep -qx 'set -euo pipefail' "$file" || missing+="  ${file#"${GI_ROOT}/"}"$'\n'
  done < <(gi_shell_files)

  [ -z "$missing" ] || {
    printf 'no set -euo pipefail in:\n%s' "$missing" >&2
    return 1
  }
}

@test "every shell file must start with the same shebang" {
  local file wrong=""

  while IFS= read -r file; do
    [[ "$(head -n 1 "$file")" == '#!/usr/bin/env bash' ]] \
      || wrong+="  ${file#"${GI_ROOT}/"}: $(head -n 1 "$file")"$'\n'
  done < <(gi_shell_files)

  [ -z "$wrong" ] || {
    printf 'unexpected shebang:\n%s' "$wrong" >&2
    return 1
  }
}

@test "a shell file the lint globs miss is a file nobody checks" {
  # The Makefile lints entry, lib/*.sh, steps/*.sh, variants/*/*.sh and
  # tools/*.sh. A new directory of scripts would be linted by nothing, tested by
  # nothing, and nobody would notice until it broke.
  local listed found
  listed="$(gi_shell_files | sort)"
  found="$(find "$GI_ROOT" -name '*.sh' -type f \
    -not -path "${GI_ROOT}/.git/*" -not -path "${GI_ROOT}/tests/*" | sort)"

  [ "$listed" = "$found" ] || {
    printf 'shell files outside the lint globs:\n' >&2
    printf '%s\n' "$found" | grep -vxF -- "$listed" >&2 || true
    return 1
  }
}

# --------------------------------------------------------------------------- #
#  Exit codes (DESIGN.md §3)                                                  #
# --------------------------------------------------------------------------- #
@test "the four exit codes must keep the values every caller assumes" {
  gi_bash 'printf "%s %s %s %s\n" "$EXIT_SUCCESS" "$EXIT_FAILURE" "$EXIT_USAGE" "$EXIT_INTERRUPTED"'
  [ "$status" -eq 0 ]
  [ "$output" = "0 1 2 130" ]
}
