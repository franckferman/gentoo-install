# Design contract

Every file in this repository follows this document. It is not advice. An agent
or a contributor who reads only this page must be able to write code that is
indistinguishable from the rest.

The contract is drawn from four sources: the author's public repositories
(`ubuntu-post-install`, `debian-server-post-install`, `proxmox-hetzner`,
`fix_wsl2_networking`), and an internal Gentoo installer that has run on real
machines. Where they disagree, the reason for the choice is written down.

---

## 1. Language and licence

**English.** Code, comments, messages, help text, documentation, commit
messages. No exceptions. The author's public repositories contain no French,
and a public project that mixes the two reads as unfinished.

**AGPL-3.0.** The `LICENSE` file exists and the README states the same licence.
Two of the author's repositories declare a licence in the README without
shipping the file; that is a defect, not a precedent.

---

## 2. Script header

Every executable script and every library starts exactly like this:

```bash
#!/usr/bin/env bash
#
# gentoo-install — <one line, what this file is>
# ----------------------------------------------------------------------------
# <two to five lines of prose: what it does, and the one thing a reader needs
# to know before touching it>
#
# Usage:  ./gentoo-install.sh [--flag value ...]   (--help for the list)
#
set -euo pipefail
```

`set -euo pipefail` is mandatory. None of the author's public post-install
scripts have it; all of them have bugs it would have caught. This is the single
most important place where this project departs from them.

Libraries under `lib/` are sourced, not executed. They still declare
`set -euo pipefail` so that running them directly for a syntax check behaves,
and they end with nothing — no top-level side effect, no auto-init.

---

## 3. Output

### Colours

Only when the stream that carries them is a terminal, and never when
`NO_COLOR` is set. That stream is **stderr**, not stdout — every coloured byte
in this project goes to stderr, so testing `-t 1` would drop colour the moment
someone runs `| tee install.log` or `--json > plan.json`, which is exactly when
they still want it:

```bash
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
  C_B=$'\033[1;34m'; C_D=$'\033[2m';    C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi
```

### The five helpers

```bash
log()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit "${EXIT_FAILURE}"; }
```

One glyph per level, never two. **Everything goes to stderr.** Standard output
is reserved for values a function returns to its caller, and for `--json`.
A helper that prints to stdout and is called in `$( )` will otherwise poison
the value.

`skip()` exists as a sixth helper and matters more than it looks: it makes
idempotence visible. A run that says `[=] already done` five times is a run the
operator trusts.

```bash
skip() { printf '%s[=]%s %s\n' "$C_D" "$C_0" "$*" >&2; }
```

### Exit codes

```bash
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_USAGE=2
readonly EXIT_INTERRUPTED=130
```

Nothing else. A step returns a code; it does not call `exit`. Only
`gentoo-install.sh` exits.

---

## 4. The step registry

This is the core of the project's modularity, taken from `ubuntu-post-install`
and fixed where `debian-server-post-install` regressed.

```bash
declare -A STEP_MAP=(
  [10]=step_10_preflight
  [20]=step_20_disk
  [30]=step_30_crypt
  ...
)
```

The **number is the public API**. It appears in `--steps`, in the README and in
the operator's notes. The function name is the implementation and may be
renamed freely.

Rules:

- Disabling a step means `unset 'STEP_MAP[80]'`. Never an `if` inside the
  execution loop, never a hardcoded `case`. `debian-server-post-install`
  dispatches with a hardcoded `case` and therefore has four points of truth per
  step; adding one means editing four places and forgetting one.
- Every step function returns a code. The runner accumulates failures:

```bash
_failed=()
for n in $(printf '%s\n' "${!STEP_MAP[@]}" | sort -n); do
  if ! "${STEP_MAP[$n]}"; then _failed+=("$n ${STEP_MAP[$n]}"); fi
done
```

- The final summary lists `_failed` and the run exits non-zero if it is not
  empty. `debian-server-post-install` prints "completed successfully" after a
  failed step. A script that always succeeds tells you nothing.

- `parse_step_selection` accepts `1,3-7,15` and expands it. Reject an
  unknown step number at parse time, not in the middle of an `emerge`.

---

## 5. Configuration precedence

**default < profile < explicit flag.** Never any other order.

The mechanism is a sentinel per setting, and it is generalised rather than
written by hand for a handful of settings:

```bash
# Declared once, used for every setting.
set_default()  { local k="$1" v="$2"; [[ -n "${_EXPLICIT[$k]:-}" ]] || CFG[$k]="$v"; }
set_explicit() { local k="$1" v="$2"; CFG[$k]="$v"; _EXPLICIT[$k]=1; }
```

`parse_args` calls `set_explicit`. A profile calls `set_default`. The profile
therefore applies *after* parsing and can never overwrite an intention.

`debian-server-post-install` implements this by hand and only for 7 settings
out of roughly 50; the other 43 are silently overridden by the profile. Doing
it once, generically, is the fix.

### The four axes of choice

A regular grammar, so that an operator who learns one axis knows the others:

| Form | Meaning |
|---|---|
| `--<thing>-profile NAME` | sets a coherent group of defaults |
| `--steps 1,3-7` | selects what runs |
| `--skip-<thing> A,B` | removes from a set |
| `--extra-<thing> A,B` | adds to a set |
| `--no-<thing>` / `--<thing>` | flips a boolean, polarity follows the default |

### Tri-state for anything dangerous

From `proxmox-hetzner`. A boolean cannot express "ask me":

```bash
CFG[wipe_foreign]="ask"     # ask|yes|no
CFG[reboot]="ask"           # ask|yes|no
```

`ask` is the default whenever the wrong answer destroys something.

### Validation happens in three stages

1. **At parse time**, against an enumeration. Dies in ten milliseconds, never
   in the middle of a compile. The message lists the valid values.
2. **Against the machine**, at pre-flight. The value is legal but is it
   available here?
3. **Degradation**, at use. Something disappeared between the two.

---

## 6. The error voice

Invariant across the whole project, from `debian-server-post-install`:

```
what is wrong
       valid values, each with one line saying what it means
       a copyable example
```

```bash
err "Unknown init system: ${want}"
err "       openrc    the default on Gentoo, no systemd anywhere"
err "       systemd   pulls the systemd stage and profile"
err "       example:  --init systemd"
```

Seven spaces of indentation on the continuation lines. An error that names the
problem without naming the way out costs a web search.

---

## 7. Engine and rendering are separate

From `Win-PostInstall`, and it is the reason `--dry-run`, `--json` and quiet
mode can exist without rewriting a single module.

A function that acts **returns a record and says nothing**. A function that
displays **prints and changes nothing**.

```bash
ensure_portage_var()  { ...; printf '%s\n' "$old|$new|$changed"; }
show_portage_var()    { ...; }
```

A module that mixes the two cannot be dry-run, cannot be tested, and cannot
report.

---

## 8. Every write to a file

Three obligations, no exceptions.

**Marked blocks**, so a rerun replaces its own work and nothing else:

```
# >>> gentoo-install: portage make.conf >>>
...
# <<< gentoo-install: portage make.conf <<<
```

**A timestamped backup before the write**, kept only if the run failed. A
backup directory that fills up with identical copies is a backup directory
nobody reads.

**`--on-conflict`**, validated against `overwrite|skip|prompt|backup`.

And where the file has a checker, **validate then roll back**:

```bash
write_config "$tmp" && if ! validator "$tmp"; then restore_backup; die "..."; fi
```

`sshd -t`, `visudo -c`, `grub-script-check`, `emerge --info` — each of these
turns a silent brick into a caught error. This is the best pattern in
`debian-server-post-install` and it generalises to `fstab`, `make.conf` and the
bootloader.

---

## 9. Idempotence and resume

**Idempotence by state check.** Read, compare, write only if different, and say
which of the three happened:

```
[+] make.conf: MAKEOPTS set to -j8
[=] make.conf: MAKEOPTS already -j8
```

`debian-server-post-install` appends its network hardening with sixty
`tee -a` calls onto a file it never truncates. Run it twice and the file has
everything twice.

**A state journal**, because a Gentoo install compiles a kernel and an
interruption must not start over:

```
/var/lib/gentoo-install/state          key=value, one per line, mode 600
```

`--resume` reads it and skips what completed. `--restart` ignores it. The
journal records what was done, never with what: no passphrase, no key, ever.

**Discriminating retry.** Retry a transient network error. Abort immediately on
a real one. A blind retry loop turns a clear failure into a slow one.

---

## 10. Data lives in data files

Package lists, USE flags, stage variants, portage profiles: `data/`, one record
per line, never a literal inside a function.

`Win-PostInstall` carries two hundred package names on a single six-thousand
character line. Nobody can review that, and a diff on it is unreadable.

```
data/stages.tsv        variant, init, libc, flavour, arch, constraints
data/profiles.tsv      portage profiles per init and flavour
data/packages/*.list   one package per line, # for comments
```

Package sets inherit cumulatively, and the inheritance table appears in the
README. A reader must be able to answer "what does `desktop` add over
`minimal`" without opening a script.

---

## 11. Lifecycle

Every entry point installs the same lifecycle, from
`debian-server-post-install`:

```bash
cleanup()          { ... }                 # on EXIT, idempotent
handle_interrupt() { warn "Interrupted"; exit "$EXIT_INTERRUPTED"; }
trap cleanup EXIT
trap handle_interrupt INT TERM
```

`cleanup` unmounts only what this run mounted, removes only what this run
created. Ownership is recorded, not guessed.

---

## 12. Safety doctrine

Stated in the README, and every default classified:

- **Safe by default** — the choice a careful operator would make.
- **Conservative by default** — off, because turning it on breaks something
  named.

Every disabled default says what it would break. A generated configuration file
ships its own disabled lines, commented, next to the flag that enables them.

Destructive operations are never reached without a proof:

- Nothing is erased before another way in has been shown to work.
- The confirmation for an irreversible act is a **typed value** — a disk name,
  a UUID, a slot number — never `y`. A reflex `y` is what this guards against.
- `--force` lifts confirmations. It does not lift proofs.

---

## 13. Argument parsing

```bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit "$EXIT_SUCCESS" ;;
    --version)    printf '%s\n' "$VERSION"; exit "$EXIT_SUCCESS" ;;
    --steps)      [[ $# -ge 2 ]] || die "--steps requires a value"; ... ;;
    *)            err "Unknown option: $1"; err "       --help lists them all"
                  exit "$EXIT_USAGE" ;;
  esac
done
```

Never `if [[ "$*" == *"-h"* ]]`. In `debian-server-post-install` that line
swallows at least eight documented flags, because `--no-ssh-hardening`
contains `-h`. Match arguments one at a time, exactly.

Never `"${arr[@]/$item}"` to remove an element from an array. That is substring
substitution: removing `telnet` from a list containing `telnet-server` leaves
`-server`. Filter with a loop and an exact comparison.

---

## 14. Repository quality

Present from the first commit, not added later:

```
LICENSE                 AGPL-3.0, and the README says the same
README.md               badges, table of contents, the inheritance tables,
                        one section per orchestration category — the table of
                        contents of the doc is the table of the steps
CHANGELOG.md            Keep a Changelog, SemVer
CONTRIBUTING.md
Makefile                lint, format, test, install
.github/workflows/      shellcheck + shfmt + bats, on every push
.shellcheckrc
.editorconfig
tests/                  bats, and they run in CI
```

The version is declared **once**, in one file, and read from there. Three of
the author's repositories carry a different version in the script and in the
README.

---

## 15. What this project does not do

It does not vendor binaries. It does not recommend `curl | bash`. It does not
promote personal taste to a default. It does not reboot without being told to.
It does not ship a step that runs by default and cannot be reviewed first.
