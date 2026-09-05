#!/usr/bin/env bash
#
# gentoo-install — bats helper: repository paths, fixtures and shared probes
# ----------------------------------------------------------------------------
# Sourced by every suite under tests/. It defines functions and touches nothing
# outside $BATS_TMPDIR, so loading it has no effect on the machine running the
# tests.
#
# Two rules shape everything here. The installer is sourceable — its last lines
# run main() only when it is executed — so a test can call parse_step_selection
# or target_fact directly instead of asserting against a whole run's output.
# And stdout is reserved for values (DESIGN.md §3), so every capture keeps
# stdout and stderr apart: a test that merged them could not tell a returned
# value from a diagnostic.
#
# Usage:  load helper   (from a .bats file)
#

# The suite uses `run --separate-stderr`, which bats gained in 1.5.0. Declaring
# it here turns "flags on run require 1.5.0" from a warning printed after every
# test into a single, early, readable failure.
bats_require_minimum_version 1.5.0

# Absolute, because a bats test's working directory is not promised.
GI_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd)"
GI_ENTRY="${GI_ROOT}/gentoo-install.sh"
export GI_ROOT GI_ENTRY

gi_tmp() {
  # A directory this test owns. Nothing in the suite writes anywhere else.
  local dir="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/gi"
  mkdir -p -- "$dir"
  printf '%s\n' "$dir"
}

gi_shell_files() {
  # The same set the Makefile lints, in the same order, one path per line.
  # Kept as globs rather than a find so that a suite failure names the same
  # files `make lint` names.
  local f
  for f in "${GI_ROOT}"/gentoo-install.sh \
    "${GI_ROOT}"/lib/*.sh \
    "${GI_ROOT}"/steps/*.sh \
    "${GI_ROOT}"/variants/*/*.sh \
    "${GI_ROOT}"/tools/*.sh; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

gi_bash() {
  # Run a snippet with the installer sourced, through bats' `run`, so $status,
  # $output (stdout) and $stderr are all available and an exit inside the
  # snippet cannot take the test with it.
  # Args: $1 = snippet, $2.. = its positional arguments ($1, $2, ... inside it).
  local snippet="$1"
  shift
  # SC2016: the single quotes are the point. $GI_ENTRY must expand in the child
  # shell, which inherits it from the environment, not in this one.
  # shellcheck disable=SC2016
  run --separate-stderr bash -c 'source "$GI_ENTRY"; '"$snippet" bash "$@"
}

gi_capture() {
  # Same, but for the cases that want the value rather than the status: prints
  # whatever the snippet prints on stdout, and lets stderr through to the log.
  # Args: $1 = snippet, $2.. = its positional arguments.
  local snippet="$1"
  shift
  # shellcheck disable=SC2016  # see gi_bash above
  bash -c 'source "$GI_ENTRY"; '"$snippet" bash "$@"
}

gi_run() {
  # Run the installer as an operator would, with the log and the resume journal
  # pointed inside $BATS_TMPDIR. Without this the container writes a real
  # /var/log/gentoo-install.log, because it runs as root.
  local tmp
  tmp="$(gi_tmp)"
  run --separate-stderr "$GI_ENTRY" \
    --log-file "${tmp}/install.log" --state-dir "${tmp}/state" "$@"
}

gi_conf() {
  # Write a configuration file under $BATS_TMPDIR and print its path.
  # Args: $@ = the lines of the file.
  local tmp file
  tmp="$(gi_tmp)"
  file="${tmp}/gentoo-install.conf"
  printf '%s\n' "$@" >"$file"
  printf '%s\n' "$file"
}

gi_enum_comments() {
  # Print "file<TAB>key<TAB>enumeration" for every setting whose declaration
  # carries an enumeration in its trailing comment:
  #
  #     set_default bootloader "grub" # grub|efistub|systemd-boot
  #
  # The rule is the one a human reader applies — the first word of the comment
  # contains a pipe — so a declaration a reader would call an enumeration is one
  # this function reports, whatever the prose that follows on the same line.
  local file
  while IFS= read -r file; do
    awk -v f="$file" '
      /^[[:space:]]*set_default[[:space:]]/ && /#/ {
        key = $2
        comment = substr($0, index($0, "#") + 1)
        first = ""
        n = split(comment, words, /[ \t]+/)
        for (i = 1; i <= n; i++) {
          if (words[i] != "") { first = words[i]; break }
        }
        if (first ~ /\|/) { print f "\t" key "\t" first }
      }
    ' "$file"
  done < <(gi_shell_files)
}

gi_enum_is_exempt() {
  # Settings deliberately outside CFG_ENUM. A name belongs here only with a
  # reason, and every reason below is held to account by a test of its own, so
  # that an exemption cannot quietly outlive the fact that justified it.
  case "$1" in
    disk_swap)
      # An open set: auto, none, or a free-form size such as 8G. There is no
      # closed list to check it against, and lib/config.sh says so in the
      # comment above CFG_ENUM. The test "disk_swap has no closed set ..."
      # pins that its enumeration really does carry a placeholder.
      return 0
      ;;
  esac
  return 1
}

gi_scan_files() {
  # Every file that ships, one path per line, minus the three exclusions the
  # hygiene suite documents where it uses them.
  find "$GI_ROOT" -type f \
    -not -path "${GI_ROOT}/.git/*" \
    -not -path "${GI_ROOT}/tests/*" \
    -not -path "${GI_ROOT}/docs/research/*" \
    -not -path "${GI_ROOT}/docs/REPRISE.md" \
    | sort
}

gi_setting() {
  # A setting's value out of a --dump-config listing, which reads
  # "key = value  # origin". Args: $1 = key, $2 = the listing.
  printf '%s\n' "$2" | awk -v k="$1" '$1 == k && $2 == "=" { print $3; exit }'
}

gi_origin() {
  # Where --dump-config says that value came from: explicit or default.
  # Args: $1 = key, $2 = the listing.
  printf '%s\n' "$2" | awk -v k="$1" '$1 == k && $2 == "=" { print $NF; exit }'
}
