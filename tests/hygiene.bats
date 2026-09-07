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
  #
  # So is any version carrying a suffix. A kernel the README quotes from a
  # real install — 6.18.48-gentoo-dist-bin — is not a claim about this
  # project's version, and reading it as one pushes the documentation towards
  # saying less about what was actually run, which is the opposite of the
  # point. Only a bare N.N.N counts as a claim.
  #
  # And so is SVG path data. docs/index.html carries the GitHub mark as an
  # inline <path d="M12 0C5.37 0 …">, whose coordinates read as five versions
  # this project never had. A drawing is not a document making a claim.
  #
  # And so is a pinned container image. The Makefile names shellcheck 0.11.0,
  # shfmt 3.14.0 and bats 1.14.0 — three other projects' versions, pinned
  # precisely so that CI and a contributor agree on what "formatted" means.
  for file in README.md CHANGELOG.md CONTRIBUTING.md Makefile \
    docs/DESIGN.md docs/index.html .github/workflows/ci.yml \
    .github/workflows/static.yml; do
    [[ -f "${GI_ROOT}/${file}" ]] || continue
    while IFS= read -r found; do
      [[ "$found" == "$version" ]] || wrong+="  ${file}: ${found}"$'\n'
    done < <(sed -E -e 's#https?://[^[:space:])"]*##g' -e 's#\bd="[^"]*"##g' \
      -e 's#[A-Za-z0-9._/-]+:v?[0-9]+\.[0-9]+\.[0-9]+##g' \
      "${GI_ROOT}/${file}" \
      | grep -oE '(^|[^0-9.-])[0-9]+\.[0-9]+\.[0-9]+([^0-9a-zA-Z-]|$)' \
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

@test "every configuration key the code reads is a key the code declares" {
  # Three drifts of this shape shipped before this test existed: --device was
  # declared and read by nobody while lib/disk.sh read `disk`; 95_finalize read
  # `layout` where the setting is `disk_layout`; and 80_boot read
  # `secureboot_keyfile`, which nothing declared — so Secure Boot signing could
  # never be switched on, and the flag was rejected as an unknown setting.
  #
  # Direct CFG[key] reads count too: chroot_target() read CFG[target], which no
  # setting declares, so every run chrooted into /mnt/gentoo whatever --root
  # said. Comment lines are stripped, so prose naming a key is not a reference.
  local declared refd missing
  declared="${BATS_TEST_TMPDIR}/declared"
  refd="${BATS_TEST_TMPDIR}/referenced"

  "$GI_ENTRY" --dump-config 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | awk '/^[a-z_]+ +=/ {print $1}' | sort -u >"$declared"
  [ -s "$declared" ]

  # Comment-only lines are dropped first: this file's own prose names the keys
  # that used to be read under the wrong spelling, and that must not register
  # as a reference.
  grep -rhvE '^[[:space:]]*#' \
    "${GI_ROOT}/lib" "${GI_ROOT}/steps" "${GI_ROOT}/variants" "${GI_ENTRY}" \
    | grep -oE '\$\((cfg|target_fact) [a-z_]+|CFG\[[a-z_]+\]' \
    | sed -E 's/.*\((cfg|target_fact) //; s/CFG\[//; s/\]//' \
    | sort -u >"$refd"

  # And the predicates. cfg_yes and cfg_is read a setting just as cfg does,
  # and were not scanned: `cfg_yes ssh` sat beside the declared sshd, so --ssh
  # came back "Unknown option" and the lookup could only ever answer no.
  grep -rhvE '^[[:space:]]*#' \
    "${GI_ROOT}/lib" "${GI_ROOT}/steps" "${GI_ROOT}/variants" "${GI_ENTRY}" \
    | grep -ohE '\b(cfg_yes|cfg_is) [a-z_]+' \
    | awk '{ print $2 }' | sort -u >>"$refd"
  sort -u -o "$refd" "$refd"

  # And the candidate lists. _sys_cfg and _portage_cfg take a fallback and then
  # every spelling a step is willing to answer to, which is a second way to
  # read a setting and was not scanned: `locales` — the plural, the whole point
  # of a system in more than one language — was read by step 90 and declared by
  # nothing, so `--locales` came back "Unknown option" and a machine could only
  # ever be given one. `lang` and `keyboard` sat in the same lists, dead.
  grep -rhvE '^[[:space:]]*#' \
    "${GI_ROOT}/lib" "${GI_ROOT}/steps" "${GI_ROOT}/variants" "${GI_ENTRY}" \
    | grep -ohE '_(sys|portage)_cfg "[^"]*"( +[a-z_]+)+' \
    | sed -E 's/_(sys|portage)_cfg "[^"]*"//' \
    | tr ' ' '\n' | grep -E '^[a-z_]+$' \
    | sort -u >>"$refd"
  sort -u -o "$refd" "$refd"

  # And the third helper of that shape, which had no fallback argument and so
  # matched neither pattern above: step 10's. Ten of the twelve names it read
  # were declared by nothing. `_pf_cfg_first fs filesystem root_fs` was the one
  # that cost something — the answer was always the ext4 fallback, so mkfs.btrfs,
  # mkfs.xfs and mkfs.f2fs were never required and a btrfs install on a medium
  # without btrfs-progs got a green "Required tools: N present" from the one
  # step whose whole job is to say so before the disk is touched.
  #
  # A key must start with a letter or an underscore, so that the `2` of
  # `2>/dev/null` at the end of the call is not read as a setting name.
  grep -rhvE '^[[:space:]]*#' \
    "${GI_ROOT}/lib" "${GI_ROOT}/steps" "${GI_ROOT}/variants" "${GI_ENTRY}" \
    | grep -ohE '_pf_cfg_first( +[a-z_][a-z_0-9]*)+' \
    | sed -E 's/_pf_cfg_first//' \
    | tr ' ' '\n' | grep -E '^[a-z_][a-z_0-9]*$' \
    | sort -u >>"$refd"
  sort -u -o "$refd" "$refd"
  [ -s "$refd" ]

  missing="$(comm -23 "$refd" "$declared")"
  if [[ -n "$missing" ]]; then
    printf 'read by the code, declared by nothing:\n%s\n' "$missing" >&2
    return 1
  fi
}

@test "every helper that reads a setting by candidate name is one the scan knows" {
  # Three times now the settings scan has been widened after a defect, never
  # before one: cfg_yes and cfg_is, then _fin_recorded one level down, then
  # _pf_cfg_first. Each time the new way of reading a setting was invisible to
  # the test whose whole purpose is to notice exactly that.
  #
  # So the shape is enumerated instead of trusted. A helper that walks a list
  # of candidate names — `for key in "$@"` over `CFG[$key]` — is a way to read
  # a setting, and the scan above has to know its spelling. Adding one is
  # fine; adding one without teaching the scan is what this refuses.
  local found expected
  found="$(awk '
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
      fn = $1; sub(/\(\).*/, "", fn); body = ""; next
    }
    fn != "" { body = body "\n" $0 }
    /^\}/ && fn != "" {
      if (body ~ /for key in "\$@"/ && body ~ /CFG\[\$key\]/) print fn
      fn = ""
    }
  ' "${GI_ROOT}"/lib/*.sh "${GI_ROOT}"/steps/*.sh "${GI_ROOT}"/variants/*/*.sh \
    "$GI_ENTRY" | sort -u)"

  # _sys_cfg_first is reached through _sys_cfg, which is the spelling the scan
  # matches; _portage_cfg and _pf_cfg_first are matched by their own names.
  expected="$(printf '%s\n' _pf_cfg_first _portage_cfg _sys_cfg_first | sort)"

  [[ "$found" == "$expected" ]] || {
    printf 'the helpers that read a setting by candidate name are now:\n%s\n' "$found" >&2
    printf 'the settings scan in this file was written for:\n%s\n' "$expected" >&2
    printf 'teach the scan the new one, then add it to the list here.\n' >&2
    return 1
  }
}

@test "every state-journal key the code reads is a key some step writes" {
  # The settings check above has a twin one level down, and this is it. Three
  # drifts lived here: step 20 wrote disk.root/disk.vg/disk.esp while steps 70
  # and 80 read disk.root_device/disk.vg_name/disk.esp_device; the chroot module
  # wrote chroot.target while two steps read chroot.root; and step 30 wrote
  # crypt.name while step 70 read crypt.luks_name. That last one was the worst:
  # an encrypted install created /dev/mapper/gentoo and told the kernel
  # root=/dev/mapper/cryptroot, so the machine could not boot.
  #
  # There is no allowed list, and that is the point. There was one, of eight
  # keys that no step wrote because a declared setting and a fallback carried
  # the value instead — which is exactly a --resume that forgets what the first
  # run chose: the kernel it built binary or from source, the initramfs
  # generator, the key file the initramfs looks for, the logical volume holding
  # root. All eight are journalled now. If this test ever needs an exception
  # again, write down which decision a resumed run is allowed to make
  # differently from the run it is resuming, because that is what is being
  # asked for.
  local allowed written read_keys missing
  written="${BATS_TEST_TMPDIR}/written"
  read_keys="${BATS_TEST_TMPDIR}/read"
  allowed="${BATS_TEST_TMPDIR}/allowed"

  : >"$allowed"

  {
    grep -rhoE 'state_set +["'"'"'\047]?[a-z_]+\.[a-z_]+' \
      "${GI_ROOT}/lib" "${GI_ROOT}/steps" "${GI_ROOT}/variants" \
      | sed -E 's/state_set +["'"'"']?//'
    grep -rhoE '_sys_record +[a-z_]+' "${GI_ROOT}/steps" | sed -E 's/_sys_record +/system./'
    grep -rhoE '_portage_record +[a-z_]+' "${GI_ROOT}/steps" | sed -E 's/_portage_record +/portage./'
    cat "$allowed"
  } | sort -u >"$written"

  grep -rhvE '^[[:space:]]*#' \
    "${GI_ROOT}/lib" "${GI_ROOT}/steps" "${GI_ROOT}/variants" \
    | grep -oE 'state_get +['"'"'"]?[a-z_]+\.[a-z_]+|target_fact +['"'"'"a-z_]+ +[a-z_]+\.[a-z_]+|_fin_recorded +[a-z_]+\.[a-z_]+' \
    | grep -oE '[a-z_]+\.[a-z_]+' | sort -u >"$read_keys"
  [ -s "$read_keys" ]

  missing="$(comm -23 "$read_keys" "$written")"
  if [[ -n "$missing" ]]; then
    printf 'state keys read by a step, written by none:\n%s\n' "$missing" >&2
    return 1
  fi
}

@test "no step after 30 decides the encryption from the settings alone" {
  # Steps 20 and 30 decide: they read CFG because CFG is the operator asking.
  # Every step after them reads back a decision already made, and the run that
  # reads it back is very often the one launched without the configuration
  # file, where CFG holds only the built-in defaults — crypt = luks-passphrase
  # and crypt_name = gentoo. Both cost a real failure. Step 50 tried to open a
  # LUKS container on an install the operator had asked to leave plain, and
  # step 75 loaded the passphrase variant on a luks-tpm machine, found it has
  # nothing to seal, and returned success. target_fact is the reader that puts
  # the journal ahead of a default.
  local file base bad=""
  for file in "${GI_ROOT}"/steps/*.sh; do
    base="$(basename -- "$file")"
    case "$base" in
      [12][0-9]_* | 30_*) continue ;;
    esac
    if grep -nE 'CFG\[crypt\]|CFG\[crypt_name\]' "$file" | grep -vE '^\s*[0-9]+:\s*#'; then
      bad="${bad} ${base}"
    fi
  done
  [[ -z "$bad" ]] || {
    printf 'these steps run after the encryption was decided and journalled,\n' >&2
    printf 'and read it from CFG anyway:%s\n' "$bad" >&2
    printf 'use target_fact crypt crypt.variant / target_fact crypt_name crypt.name\n' >&2
    return 1
  }
}

@test "every flag an error message offers as an example must exist" {
  # An error that ends "example: --layout minimal" is worse than no example when
  # the setting is called disk_layout: the operator types what they were told,
  # gets "Unknown option", and now doubts the diagnosis as well. Five messages
  # said --layout, --filesystem or --target, none of which this program accepts.
  #
  # Only `example:` lines are read, because messages also quote gpg, curl and
  # grub-install, whose flags are none of this test's business.
  local declared offered flag key bad=""
  declared="${BATS_TEST_TMPDIR}/declared"
  "$GI_ENTRY" --dump-config 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | awk '/^[a-z_]+ +=/ {print $1}' | sort -u >"$declared"
  [ -s "$declared" ]

  offered="$(grep -rhoE '"[^"]*example:[^"]*"' \
    "${GI_ROOT}/lib" "${GI_ROOT}/steps" "${GI_ROOT}/variants" "${GI_ENTRY}" \
    | grep -oE '(^|[^a-z-])--[a-z][a-z0-9-]+' \
    | grep -oE '\-\-[a-z][a-z0-9-]+' | sed 's/^--//' | sort -u)"

  for flag in $offered; do
    case "$flag" in
      # The behaviour flags, which are not settings, and the flags of the
      # commands an example tells the operator to run by hand.
      help | version | dry-run | yes | force | non-interactive | resume | \
        restart | json | no-color | steps | skip-steps | list-steps | config | \
        profile | dump-config | on-conflict | log-file | state-dir | \
        list-flavours | list-disks) continue ;;
      ask | oneshot | show-keys | sync | deep | newuse | update | quiet) continue ;;
    esac
    key="${flag//-/_}"
    grep -qx "$key" "$declared" || bad+="  --${flag} (no setting named ${key})"$'\n'
  done

  if [[ -n "$bad" ]]; then
    printf 'error messages offer flags this program does not accept:\n%s' "$bad" >&2
    return 1
  fi
}

# --------------------------------------------------------------------------- #
#  Comparing two files on a medium that has almost nothing                    #
# --------------------------------------------------------------------------- #
@test "two files are compared with whatever the medium carries" {
  # backup_file() used cmp to avoid stacking a second identical backup. cmp
  # comes from diffutils, and the Gentoo minimal ISO — the medium this
  # installer is written for — does not have it, so every write during an
  # install printed "cmp: command not found" and then took a backup it did not
  # need, a failed comparison reading as "different".
  local dir
  dir="$(gi_tmp)/identical"
  mkdir -p "$dir"
  printf 'same\n' >"${dir}/a"
  printf 'same\n' >"${dir}/b"
  printf 'other\n' >"${dir}/c"

  gi_bash 'files_identical "$1/a" "$1/b"' "$dir"
  [ "$status" -eq 0 ]
  gi_bash 'files_identical "$1/a" "$1/c"' "$dir"
  [ "$status" -ne 0 ]

  # The medium of the day: no cmp anywhere.
  gi_bash 'have() { [[ "$1" != cmp ]] && command -v "$1" >/dev/null 2>&1; }
           files_identical "$1/a" "$1/b"' "$dir"
  [ "$status" -eq 0 ]
  gi_bash 'have() { [[ "$1" != cmp ]] && command -v "$1" >/dev/null 2>&1; }
           files_identical "$1/a" "$1/c"' "$dir"
  [ "$status" -ne 0 ]
}

@test "a medium with no way to compare is told they differ, not that they match" {
  # One backup too many is a wasted copy; one too few is a lost original.
  local dir
  dir="$(gi_tmp)/nocompare"
  mkdir -p "$dir"
  printf 'same\n' >"${dir}/a"
  printf 'same\n' >"${dir}/b"
  gi_bash 'have() { return 1; }; files_identical "$1/a" "$1/b"' "$dir"
  [ "$status" -ne 0 ]
}

@test "backup_file asks that question instead of running cmp itself" {
  local dir
  dir="$(gi_tmp)/backups"
  mkdir -p "$dir"
  printf 'content\n' >"${dir}/f"
  gi_bash '
    DRY_RUN=no
    files_identical() { printf "ASKED\n"; return 0; }
    _GI_BACKUP_OF["$1/f"]="$1/f"
    backup_file "$1/f"
  ' "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ASKED"* ]]
}

# --------------------------------------------------------------------------- #
#  The site says what the project is                                          #
# --------------------------------------------------------------------------- #
@test "the site lists exactly the steps the registry has" {
  # docs/index.html is the public face, and a page that says ten steps when
  # there are eleven is the same class of drift as a README section that no
  # longer matches its step: nobody notices, and everybody reads it.
  local missing="" extra="" n
  for n in $(gi_bash 'printf "%s\n" "${!STEP_MAP[@]}" | sort -n' && printf '%s' "$output"); do
    grep -q "<div class=\"step-num\">${n}</div>" "${GI_ROOT}/docs/index.html" \
      || missing+=" $n"
  done
  while read -r n; do
    gi_bash 'printf "%s\n" "${!STEP_MAP[@]}"' >/dev/null
    [[ "$output" == *"$n"* ]] || extra+=" $n"
  done < <(grep -oE '<div class="step-num">[0-9]+</div>' "${GI_ROOT}/docs/index.html" \
    | grep -oE '[0-9]+')
  if [[ -n "$missing" || -n "$extra" ]]; then
    printf 'steps missing from the site:%s\nsteps on the site that do not exist:%s\n' \
      "$missing" "$extra" >&2
    return 1
  fi
}

@test "the site's headline numbers are the project's own" {
  # Counted here, not copied: the stats bar claims a number of steps, of
  # rescue scripts and of tests, and every one of them is a fact this
  # repository can produce.
  local page steps tools stages choices
  page="${GI_ROOT}/docs/index.html"
  steps="$(find "${GI_ROOT}/steps" -maxdepth 1 -name '*.sh' | wc -l)"
  tools="$(find "${GI_ROOT}/tools" -maxdepth 1 -name '*.sh' | wc -l)"
  # The catalogue, minus its comment header and its blank lines.
  stages="$(grep -cvE '^[[:space:]]*(#|$)' "${GI_ROOT}/data/stages.tsv")"
  choices="$(find "${GI_ROOT}/variants" -mindepth 1 -maxdepth 1 -type d | wc -l)"

  grep -q "<div class=\"stat-num\">${steps}</div><div class=\"stat-label\">Numbered steps" "$page"
  grep -q "<div class=\"stat-num\">${tools}</div><div class=\"stat-label\">Rescue scripts" "$page"

  # The two that had drifted, and the one that could. The page said 51 stage3
  # variants where the catalogue holds 19, and 199 tests where the suite holds
  # far more — the most-read numbers on the page, neither of them counted.
  grep -q "<div class=\"stat-num\">${stages}</div><div class=\"stat-label\">Stage3 variants" "$page" || {
    printf 'the catalogue holds %s variants; the page says otherwise:\n%s\n' "$stages" \
      "$(grep -o '<div class="stat-num">[0-9]*</div><div class="stat-label">Stage3 variants' "$page")" >&2
    return 1
  }
  grep -q "<div class=\"stat-num\">${choices}</div><div class=\"stat-label\">Choices to make" "$page"

  # The test count perishes every time a test is added, which is the point:
  # a number on the public page that nothing counts is a number that drifts,
  # and this one had drifted by most of its own value.
  local suite
  suite="$(grep -hc '^@test' "${GI_ROOT}"/tests/*.bats | paste -sd+ | bc)"
  grep -q "<div class=\"stat-num\">${suite}</div><div class=\"stat-label\">Tests" "$page" || {
    printf 'the suite holds %s tests; the page says:\n%s\n' "$suite" \
      "$(grep -o '<div class="stat-num">[0-9]*</div><div class="stat-label">Tests' "$page")" >&2
    return 1
  }

  # And the version, which appears three times and must be the one the entry
  # point declares.
  local version
  version="$(grep -oE '^readonly VERSION="[^"]+"' "${GI_ROOT}/gentoo-install.sh" | cut -d'"' -f2)"
  [ -n "$version" ]
  grep -q "v${version}" "$page"
}

@test "the site calls a bootloader booted only where TESTING.md says so" {
  # The two documents disagreed for several days and the page was the one that
  # was wrong: it said systemd-boot had been booted "as far as the passphrase
  # prompt", and docs/TESTING.md said "all four pass" over a table with no
  # evidence column. Nothing had ever been quoted for systemd-boot — no boot
  # log, no bootctl list. The claim was written from the shape of the matrix.
  #
  # docs/TESTING.md now carries the status of record, one row per bootloader
  # with a Result of exactly "booted" or "not booted", and the page carries the
  # same four as data attributes. This compares them.
  local record page_status name result line
  record="${BATS_TEST_TMPDIR}/record"
  page_status="${BATS_TEST_TMPDIR}/page"

  grep -oE '^\| 3[a-z] \| `[a-z-]+` \| (not booted|booted) \|' "${GI_ROOT}/docs/TESTING.md" \
    | sed -E 's/^\| 3[a-z] \| `([a-z-]+)` \| (not booted|booted) \|$/\1=\2/' \
    | sort >"$record"
  [ -s "$record" ] || {
    printf 'docs/TESTING.md carries no bootloader status table any more.\n' >&2
    return 1
  }

  grep -oE 'data-bootloader="[a-z-]+" data-status="(not booted|booted)"' \
    "${GI_ROOT}/docs/index.html" \
    | sed -E 's/data-bootloader="([a-z-]+)" data-status="(not booted|booted)"/\1=\2/' \
    | sort >"$page_status"
  [ -s "$page_status" ] || {
    printf 'docs/index.html states no bootloader status any more.\n' >&2
    return 1
  }

  if ! diff -u "$record" "$page_status" >/dev/null; then
    printf 'the page and the record disagree about what has been booted:\n' >&2
    diff -u --label 'docs/TESTING.md' --label 'docs/index.html' \
      "$record" "$page_status" >&2 || true
    printf 'the record wins; a boot with no log behind it is not a boot.\n' >&2
    return 1
  fi

  # The README is the third document that makes this claim, and it made it too:
  # "systemd-boot has been booted too, on the same encrypted disk … through to
  # the passphrase prompt", with the evidence of another run behind it.
  while IFS= read -r line; do
    name="${line%%=*}"
    result="${line#*=}"
    [[ "$result" == "not booted" ]] || continue
    if grep -qE "\`${name}\` has been booted" "${GI_ROOT}/README.md"; then
      printf 'the README says `%s` has been booted; the record says it has not.\n' \
        "$name" >&2
      return 1
    fi
  done <"$record"

  # And every bootloader the project ships has to appear in both.
  local shipped
  shipped="$(find "${GI_ROOT}/variants/boot" -name '*.sh' \
    | sed -e 's#.*/##' -e 's/\.sh$//' | sort)"
  [ "$(cut -d= -f1 <"$record")" = "$shipped" ] || {
    printf 'the status table does not cover every bootloader the project ships:\n' >&2
    printf 'shipped: %s\ntable:   %s\n' "$(printf '%s' "$shipped" | paste -sd,)" \
      "$(cut -d= -f1 <"$record" | paste -sd,)" >&2
    return 1
  }
}

@test "the four choice groups on the site list exactly the variants that exist" {
  # Each choice is a directory of variants, and the page names them one by one.
  # A variant added without a line here is one nobody knows they can ask for;
  # a line here without a file is a flag that fails at parse time.
  local dir group name missing="" extra=""
  local page="${GI_ROOT}/docs/index.html"
  for dir in "${GI_ROOT}"/variants/*/; do
    group="$(basename -- "${dir%/}")"
    while IFS= read -r name; do
      grep -q "<div class=\"opt-flag\">${name}</div>" "$page" \
        || missing+=" ${group}/${name}"
    done < <(find "$dir" -name '*.sh' | sed -e 's#.*/##' -e 's/\.sh$//')
  done
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    find "${GI_ROOT}/variants" -name "${name}.sh" | grep -q . || extra+=" ${name}"
  done < <(grep -oE '<div class="opt-flag">[a-z0-9-]+</div>' "$page" \
    | sed -E 's/.*>([a-z0-9-]+)<.*/\1/')

  if [[ -n "$missing" || -n "$extra" ]]; then
    printf 'variants the site does not name:%s\n' "$missing" >&2
    printf 'names on the site with no variant behind them:%s\n' "$extra" >&2
    return 1
  fi
}

@test "no file asks whether there is a terminal by reading a permission bit" {
  # `[[ -r /dev/tty ]]` is true on a process with no controlling terminal:
  # the node is mode 0666, and the permission bits are not the question. Eight
  # guards asked it that way, and every one of them reported the wrong reason
  # when the open then failed. core_have_tty() opens the thing instead.
  local hits
  hits="$(gi_shell_files | xargs grep -n -- '-r /dev/tty' \
    | grep -v 'lib/core.sh:.*#' || true)"
  if [[ -n "$hits" ]]; then
    printf 'a terminal is not a permission bit:\n%s\n' "$hits" >&2
    return 1
  fi
}

@test "every transcript in the README is what the command still prints" {
  # The README shows what this installer says, in ```console blocks with a
  # `$ ./gentoo-install.sh …` line at the top. Those are claims about the
  # program, and they drift silently: the --dump-config example listed arch,
  # assume_yes, boot_device, boot_disk, boot_label, which stopped being the
  # first five settings the day `accounts` and `accounts_file` were declared.
  # Nobody reruns a transcript.
  #
  # Blocks that name a file the repository does not carry are skipped and
  # counted: they show a run against something the reader supplies.
  local block cmd expected actual checked=0 skipped=0 bad=""
  local tmp="${BATS_TEST_TMPDIR}/blocks"
  mkdir -p "$tmp"

  awk -v dir="$tmp" '
    /^```console/ { n++; inb = 1; next }
    /^```/        { inb = 0; next }
    inb           { print > (dir "/" n) }
  ' "${GI_ROOT}/README.md"

  for block in "$tmp"/*; do
    [[ -f "$block" ]] || continue
    cmd="$(head -n 1 "$block")"
    [[ "$cmd" == '$ ./gentoo-install.sh '* ]] || continue
    cmd="${cmd#$ }"

    # A --config that names a file the repo does not have is the reader's own.
    if [[ "$cmd" == *--config* ]]; then
      local named
      named="$(printf '%s\n' "$cmd" | grep -oE -- '--config +[^ ]+' | awk '{print $2}')"
      if [[ ! -e "${GI_ROOT}/${named}" ]]; then
        skipped=$((skipped + 1))
        continue
      fi
    fi

    expected="$(tail -n +2 "$block")"
    actual="$(cd "$GI_ROOT" && eval "$cmd" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
    checked=$((checked + 1))

    # The block has to be a prefix of what the command prints: a transcript may
    # stop early, it may not say something the program does not.
    local head_of_actual
    head_of_actual="$(printf '%s\n' "$actual" | head -n "$(printf '%s\n' "$expected" | wc -l)")"
    if [[ "$head_of_actual" != "$expected" ]]; then
      bad+="  ${cmd}"$'\n'
      bad+="$(diff -u --label README --label 'what it prints now' \
        <(printf '%s\n' "$expected") <(printf '%s\n' "$head_of_actual") || true)"$'\n'
    fi
  done

  ((checked > 0)) || {
    printf 'no README transcript was checked; the block scan found nothing.\n' >&2
    return 1
  }
  [[ -z "$bad" ]] || {
    printf 'README transcripts that no longer match:\n%s\n' "$bad" >&2
    return 1
  }
}

@test "every PCR value the README shows is one the validator accepts" {
  # The table has a name in one column and its registers in the other, and
  # three of its four rows print a list an operator can type. The fourth said
  # `0-7`, which reads like the same kind of value and is not one:
  #
  #     [x] Invalid PCR list: 0-7
  #
  # A column that is a value three times and a description once is a column
  # that will be typed. Both halves of every row are checked here.
  local name registers bad=""
  while IFS='|' read -r _ name registers _; do
    name="$(printf '%s' "$name" | tr -d ' `')"
    registers="$(printf '%s' "$registers" | tr -d ' `')"
    [[ -n "$name" && -n "$registers" ]] || continue
    [[ "$name" != "name" ]] || continue

    # The name has to be one the code knows, and it has to expand to exactly
    # the registers the table prints beside it.
    local expanded
    expanded="$(gi_capture 'config_init_defaults >/dev/null 2>&1; crypt_pcr_named "$1"' "$name")"
    [[ "$expanded" == "$registers" ]] \
      || bad+="  ${name}: the table says ${registers}, the code says ${expanded}"$'\n'

    # And the registers, typed as they are printed, have to be accepted.
    gi_bash 'config_init_defaults >/dev/null 2>&1; crypt_validate_pcrs "$1"' "$registers"
    [ "$status" -eq 0 ] \
      || bad+="  ${registers}: refused when typed as crypt_pcrs"$'\n'
  done < <(grep -E '^\| `[a-z+]+` \| `[0-9,-]+` \|' "${GI_ROOT}/README.md")

  [[ -z "$bad" ]] || {
    printf 'the PCR table does not match the code:\n%s\n' "$bad" >&2
    return 1
  }
}
