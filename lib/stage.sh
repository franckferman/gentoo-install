#!/usr/bin/env bash
#
# gentoo-install — stage: fetch, verify and unpack a stage3 tarball
# ----------------------------------------------------------------------------
# The trust chain is the whole point of this file. A mirror is a stranger: the
# file that names which tarball to download is signed, the tarball is signed,
# and both signatures are checked against the Gentoo release keys in a
# disposable keyring before a single byte is believed. The .sha256 is verified
# as well — never instead, because the same mirror serves the tarball and its
# checksum, so a checksum alone proves only that the mirror is self-consistent.
#
# Two rules a reader must know before touching anything here:
#   * the payload of a signed file is never read from the file itself, only
#     from what gpg --output writes, so text appended outside the signature
#     cannot be parsed;
#   * a retry is for a transient network error. A 404 or a bad signature is
#     final and is reported at once (DESIGN.md §9).
#
# Nothing runs at source time and nothing calls exit: a step returns a code.
# The engine returns records on stdout, stage_show_* prints and changes
# nothing (DESIGN.md §7).
#
# Usage:  source lib/stage.sh   (needs lib/core.sh, lib/config.sh)
#
set -euo pipefail

if [[ -n "${_GI_STAGE_LOADED:-}" ]]; then
  return 0
fi
_GI_STAGE_LOADED=1

# --------------------------------------------------------------------------- #
#  Constants                                                                  #
# --------------------------------------------------------------------------- #
# Where app-crypt/openpgp-keys-gentoo-release drops the release keys, and the
# places the other distributions that package them use. Checked in this order.
_STAGE_KEYRING_CANDIDATES=(
  "/usr/share/openpgp-keys/gentoo-release.asc"
  "/usr/share/openpgp-keys/gentoo-release.gpg"
  "/usr/share/gnupg/gentoo-release.asc"
  "/etc/portage/gnupg/gentoo-release.asc"
)

_STAGE_ATTEMPTS=4    # total tries for something a retry can fix
_STAGE_BACKOFF=3     # seconds, doubled after each failed attempt
_STAGE_CONNECT=20    # seconds to establish a connection
_STAGE_STALL_TIME=30 # seconds under _STAGE_STALL_RATE before giving up
_STAGE_STALL_RATE=512

# Filled once, by _stage_gpg_prepare() and _stage_scratch(). Nothing else
# assigns them.
_STAGE_GNUPGHOME=""
_STAGE_KEYRING_USED=""
_STAGE_SCRATCH=""
_STAGE_SHOUTED="no" # the unverified warning has already been given in full

# The record the engine returns, in globals rather than on stdout. lib/core.sh
# sets WRITE_RESULT the same way and for the same reason: a function read with
# $( ) runs in a subshell, so a temporary it registered with track_temp is
# never cleaned up and a keyring it built is rebuilt on the next call. Anything
# in this module that creates a temporary or talks to gpg therefore returns a
# code and fills these in; only the pure printers below are safe inside $( ).
STAGE_RELPATH="" # <timestamp>/stage3-<arch>-<variant>-<timestamp>.tar.xz
STAGE_SIZE=""    # the byte count the signed pointer announced
STAGE_POINTER="" # the URL the pointer was read from
STAGE_TARBALL="" # the verified tarball, once it is in the cache

# --------------------------------------------------------------------------- #
#  Settings                                                                   #
# --------------------------------------------------------------------------- #
stage_init_defaults() {
  # The three settings this module adds. Declaring them here rather than in
  # lib/config.sh keeps the module self-contained; the entry point should call
  # this from config_init_defaults() so that --dump-config and a configuration
  # file know the names too.
  #
  # Safe by default: signatures are verified, and the cache lives outside the
  # target root so that unpacking cannot swallow it.
  set_default stage_cache_dir "/var/cache/gentoo-install" # where tarballs live between runs
  set_default keyring ""                                  # empty: look in the usual places
  set_default root "/mnt/gentoo"                          # where the stage is unpacked

  # A stage of one's own. Either a file already on this machine, or a URL that
  # is not the Gentoo autobuilds tree. Both bypass the catalogue: no variant is
  # resolved, no signed pointer is read, and what the operator names is what
  # gets unpacked.
  set_default stage_file ""      # path to an archive already here
  set_default stage_url ""       # direct URL to an archive
  set_default stage_signature "" # a detached .asc to check it against
  set_default stage_checksum ""  # an expected sha256, lowercase hex
}

stage_cache_dir() { printf '%s\n' "${CFG[stage_cache_dir]:-/var/cache/gentoo-install}"; }
stage_root() { printf '%s\n' "${CFG[root]:-/mnt/gentoo}"; }

stage_verifies() {
  # True unless the operator has explicitly turned verification off.
  [[ "${CFG[verify_signatures]:-yes}" != "no" ]]
}

# --------------------------------------------------------------------------- #
#  Catalogue — which variant an (arch, init, flavour) triple names            #
# --------------------------------------------------------------------------- #
_stage_catalogue() {
  # data/stages.tsv is the only place the published variants are named.
  local path="${STAGES_TSV:-${DATA_DIR:-${GI_DATA_DIR:-.}}/stages.tsv}"
  if [[ ! -r "$path" ]]; then
    err "Missing stage catalogue: ${path}"
    err "       data/stages.tsv names every published stage3 variant"
    err "       set GI_DATA_DIR if the data directory is not beside the script"
    return 1
  fi
  printf '%s\n' "$path"
}

_stage_rows() {
  # The seven-column data records, comments and short lines dropped.
  local path
  path="$(_stage_catalogue)" || return 1
  awk -F'\t' '!/^#/ && NF == 7' "$path"
}

stage_known_flavours() {
  # Every flavour published for an architecture. A returned value, so stdout.
  # Args: $1 = arch (default CFG[arch]).
  local arch="${1:-${CFG[arch]:-amd64}}"
  _stage_rows | awk -F'\t' -v a="$arch" '$5 == a { print $4 }' | sort -u
}

stage_select() {
  # Compose init x flavour into the exact suffix Gentoo publishes, and refuse
  # a combination upstream does not build. splitusr is the one that matters:
  # it exists for OpenRC only, and a selector that does not know that walks the
  # operator into a 404 after the disks have been wiped.
  #
  # Args: $1 = arch, $2 = init, $3 = flavour (each defaulting to CFG).
  # Prints "id<TAB>libc<TAB>constraints". Returns 1 and explains; never exits,
  # because a step owns its exit code (DESIGN.md §3).
  local arch="${1:-${CFG[arch]:-amd64}}"
  local init="${2:-${CFG[init]:-openrc}}"
  local flavour="${3:-${CFG[flavour]:-base}}"
  local row
  local -a alternatives=() flavours=()

  row="$(_stage_rows | awk -F'\t' -v a="$arch" -v i="$init" -v f="$flavour" \
    '$5 == a && $2 == i && $4 == f { print $1 "\t" $3 "\t" $6; exit }')" || return 1

  if [[ -n "$row" ]]; then
    printf '%s\n' "$row"
    return 0
  fi

  mapfile -t alternatives < <(_stage_rows | awk -F'\t' -v a="$arch" -v f="$flavour" \
    '$5 == a && $4 == f { print $2 }' | sort -u)

  if ((${#alternatives[@]} > 0)); then
    err "No ${arch} stage3 is published for flavour '${flavour}' with init '${init}'"
    err "       upstream builds '${flavour}' for: ${alternatives[*]}"
    err "       nothing here can invent a tarball that was never published"
    err "       example:  --flavour ${flavour} --init ${alternatives[0]}"
    return 1
  fi

  mapfile -t flavours < <(stage_known_flavours "$arch")
  err "No ${arch} stage3 is published for flavour '${flavour}'"
  err "       known flavours: ${flavours[*]}"
  err "       --list-flavours prints them for the current --arch"
  err "       example:  --flavour base --init openrc"
  return 1
}

stage_constraint_note() {
  # One line saying what a constraint costs. Rendering, so it prints.
  case "$1" in
    none) printf '%s\n' "nothing special" ;;
    openrc-only) printf '%s\n' "no systemd counterpart is published" ;;
    no-multilib) printf '%s\n' "no 32-bit ABI: no wine, no steam, no 32-bit binaries" ;;
    hardened-toolchain) printf '%s\n' "toolchain built with the hardened profile" ;;
    selinux) printf '%s\n' "expects a SELinux policy and a labelled filesystem" ;;
    libcxx-abi) printf '%s\n' "Clang/libc++ userland, ABI-incompatible with libstdc++" ;;
    split-usr) printf '%s\n' "/usr is not merged into /" ;;
    experimental) printf '%s\n' "upstream publishes it as experimental" ;;
    *) printf '%s\n' "no note recorded for this constraint" ;;
  esac
}

# --------------------------------------------------------------------------- #
#  URLs                                                                       #
# --------------------------------------------------------------------------- #
stage_mirror() {
  # The configured mirror with any trailing slash removed, so that joining a
  # path never produces a double slash. A regional mirror is legitimate; it is
  # exactly why the signatures below are not optional.
  local mirror="${CFG[mirror]:-https://distfiles.gentoo.org}"
  printf '%s\n' "${mirror%/}"
}

stage_autobuilds_url() {
  # Args: $1 = arch (default CFG[arch]).
  printf '%s/releases/%s/autobuilds\n' "$(stage_mirror)" "${1:-${CFG[arch]:-amd64}}"
}

stage_latest_url() {
  # Args: $1 = arch, $2 = variant id.
  printf '%s/latest-stage3-%s-%s.txt\n' "$(stage_autobuilds_url "$1")" "$1" "$2"
}

# --------------------------------------------------------------------------- #
#  Keyring                                                                    #
# --------------------------------------------------------------------------- #
stage_keyring() {
  # The Gentoo release keys. Prints the path, or returns 1 without saying
  # anything: the caller decides whether a missing keyring is fatal, and only
  # the caller knows how to phrase it.
  local candidate configured="${CFG[keyring]:-}"
  if [[ -n "$configured" ]]; then
    if [[ -r "$configured" ]]; then
      printf '%s\n' "$configured"
      return 0
    fi
    return 1
  fi
  for candidate in "${_STAGE_KEYRING_CANDIDATES[@]}"; do
    if [[ -r "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

stage_explain_missing_keyring() {
  # The refusal, in the voice of DESIGN.md §6. Refusing is the default because
  # the alternative is installing whatever the mirror felt like serving.
  local configured="${CFG[keyring]:-}"
  if [[ -n "$configured" ]]; then
    err "Cannot read the keyring named by the 'keyring' setting: ${configured}"
  else
    err "No Gentoo release keyring found; refusing to trust the mirror"
  fi
  err "       the file that names the tarball is signed, and so is the tarball;"
  err "       without the release keys a compromised or hostile mirror decides"
  err "       what gets installed, and nothing downstream would notice"
  err "       looked in: ${_STAGE_KEYRING_CANDIDATES[*]}"
  err "       on Gentoo live media:  emerge --ask app-crypt/openpgp-keys-gentoo-release"
  err "       own copy:              keyring = /path/to/gentoo-release.asc   (--config)"
  err "       fetching the keys over the same untrusted network is not a fix:"
  err "       it moves the trust problem, it does not solve it"
  err "       to install with no signature check at all, knowing the above:"
  err "       verify_signatures = no   (--config)"
}

stage_warn_unverified() {
  # If verification is off it says so at every point where it would have
  # verified something — in full the first time, in one line after that, so
  # that the warning stays loud without turning into wallpaper.
  if [[ "$_STAGE_SHOUTED" == "yes" ]]; then
    warn "unverified: taking the mirror's word for it again"
    return 0
  fi
  _STAGE_SHOUTED="yes"
  warn "SIGNATURE VERIFICATION IS OFF (verify_signatures = no)"
  warn "       nothing that follows proves the tarball came from Gentoo"
  warn "       a mirror, a proxy or anything on the path can substitute it"
  warn "       the result is an installed system of unknown provenance"
  warn "       this warning repeats, in one line, everywhere a check was skipped"
}

_stage_scratch() {
  # One tracked temporary directory for everything this module needs to write
  # down: gpg's status output, a downloader's complaints, the signed pointer.
  # Created once, removed by cleanup(), and never inside a subshell.
  if [[ -n "$_STAGE_SCRATCH" && -d "$_STAGE_SCRATCH" ]]; then
    return 0
  fi
  local dir
  if ! dir="$(mktemp -d "${TMPDIR:-/tmp}/gentoo-install-stage.XXXXXXXX")"; then
    err "cannot create a temporary directory under ${TMPDIR:-/tmp}"
    return 1
  fi
  chmod 0700 -- "$dir"
  track_temp "$dir"
  _STAGE_SCRATCH="$dir"
}

_stage_gpg_prepare() {
  # A disposable keyring in a tracked temporary directory. The operator's own
  # GnuPG home is never read and never written: nothing this run imports
  # outlives it, and nothing it trusts leaks into their configuration.
  #
  # The path lands in _STAGE_GNUPGHOME and is deliberately not printed. A
  # function whose result is read with $( ) runs in a subshell, so the global
  # it sets there dies with that subshell and the keyring would be rebuilt on
  # every call — the same trap the file writers document in lib/core.sh.
  # Returns 0 when _STAGE_GNUPGHOME is usable.
  if [[ -n "$_STAGE_GNUPGHOME" && -d "$_STAGE_GNUPGHOME" ]]; then
    return 0
  fi

  local keyring home imported=0
  if ! keyring="$(stage_keyring)"; then
    stage_explain_missing_keyring
    return 1
  fi
  if ! have gpg; then
    err "gpg not found, and the stage3 signatures cannot be checked without it"
    err "       on Gentoo live media:  emerge --ask app-crypt/gnupg"
    err "       example:  gpg --version"
    return 1
  fi

  _stage_scratch || return 1
  home="${_STAGE_SCRATCH}/gnupg"
  if ! mkdir -p -- "$home"; then
    err "cannot create a temporary GnuPG home under ${_STAGE_SCRATCH}"
    return 1
  fi
  chmod 0700 -- "$home"

  if ! GNUPGHOME="$home" gpg --batch --quiet --no-tty --import -- "$keyring" 2>/dev/null; then
    err "could not import the Gentoo release keys from ${keyring}"
    err "       the file should be an OpenPGP public keyring, armoured or binary"
    err "       example:  gpg --show-keys ${keyring}"
    return 1
  fi
  imported="$(GNUPGHOME="$home" gpg --batch --list-keys --with-colons 2>/dev/null | grep -c '^pub' || true)"
  if ((imported == 0)); then
    err "${keyring} contains no public key"
    err "       an empty keyring would accept nothing, which is not the same as trusting nothing"
    return 1
  fi

  _STAGE_GNUPGHOME="$home"
  _STAGE_KEYRING_USED="$keyring"
  log "${imported} public key(s) imported into a disposable keyring from ${keyring}"
}

stage_release_gpg_home() {
  # Tear the disposable keyring down early, agent included. cleanup() would
  # remove the directory anyway; this also stops the daemons that gpg may have
  # started inside it instead of leaving them holding a deleted socket.
  [[ -n "$_STAGE_GNUPGHOME" ]] || return 0
  if have gpgconf; then
    gpgconf --homedir "$_STAGE_GNUPGHOME" --kill all >/dev/null 2>&1 || true
  fi
  rm -rf -- "$_STAGE_GNUPGHOME" 2>/dev/null || true
  _STAGE_GNUPGHOME=""
  _STAGE_KEYRING_USED=""
}

# --------------------------------------------------------------------------- #
#  Signature verification                                                     #
# --------------------------------------------------------------------------- #
_stage_gpg_verify() {
  # The single door to gpg. Args: $1 = what is being checked (for the message),
  # $2.. = the arguments --verify takes (a detached signature and its file, or
  # one clearsigned file, plus --output).
  #
  # The exit status is not enough on its own: gpg exits 0 for a good signature
  # made by an expired key, and a keyring that happens to be empty would make
  # "no error" mean "nothing checked". The machine-readable status is what
  # decides, which also makes this immune to gpg's locale.
  local what="$1"
  shift
  local status_file err_file rc=0 signer fpr

  _stage_gpg_prepare || return 1
  status_file="${_STAGE_SCRATCH}/gpg.status"
  err_file="${_STAGE_SCRATCH}/gpg.err"
  : >"$status_file"
  : >"$err_file"

  GNUPGHOME="$_STAGE_GNUPGHOME" gpg --batch --quiet --no-tty \
    --status-file "$status_file" --verify "$@" 2>"$err_file" || rc=$?

  if grep -q '^\[GNUPG:\] REVKEYSIG ' "$status_file"; then
    err "${what}: signature made with a REVOKED Gentoo release key"
    err "       a revoked key is a key its owner has disowned; the signature is worthless"
    _stage_show_gpg_error "$err_file"
    return 1
  fi
  if grep -q '^\[GNUPG:\] EXPKEYSIG ' "$status_file"; then
    err "${what}: signature made with an EXPIRED Gentoo release key"
    err "       usually a stale local keyring rather than a stale mirror"
    err "       example:  emerge --sync && emerge --oneshot app-crypt/openpgp-keys-gentoo-release"
    _stage_show_gpg_error "$err_file"
    return 1
  fi
  if grep -q '^\[GNUPG:\] NO_PUBKEY ' "$status_file"; then
    err "${what}: signed by a key that is not in the Gentoo release keyring"
    err "       keyring used: ${_STAGE_KEYRING_USED}"
    err "       either the keyring is out of date, or this file is not from Gentoo"
    _stage_show_gpg_error "$err_file"
    return 1
  fi
  if ! grep -q '^\[GNUPG:\] GOODSIG ' "$status_file" \
    || ! grep -q '^\[GNUPG:\] VALIDSIG ' "$status_file" || ((rc != 0)); then
    err "${what}: BAD SIGNATURE — refusing to go on"
    err "       the bytes do not match what the Gentoo release key signed"
    err "       a truncated download and a substituted file look identical here;"
    err "       both are reasons to stop, so this is not retried"
    _stage_show_gpg_error "$err_file"
    return 1
  fi

  signer="$(sed -n 's/^\[GNUPG:\] GOODSIG [0-9A-Fa-f]* //p' "$status_file" | head -n 1)"
  fpr="$(awk '$2 == "VALIDSIG" { print $3; exit }' "$status_file")"
  ok "${what}: good signature from ${signer}"
  log "       key ${fpr}"
  return 0
}

_stage_show_gpg_error() {
  # gpg's own words, indented, because they usually name the exact problem.
  local file="$1" line
  [[ -s "$file" ]] || return 0
  while IFS= read -r line; do
    err "       ${line#gpg: }"
  done <"$file"
}

stage_verify_clearsigned() {
  # A clearsigned file, verified, with its payload written where the caller
  # asked. Callers must read that output and never the signed file itself:
  # anything outside the signed block is attacker-controlled text.
  # Args: $1 = signed file, $2 = where to write the payload, $3 = description.
  local signed="$1" plain="$2" what="${3:-$1}"
  rm -f -- "$plain"
  _stage_gpg_verify "$what" --output "$plain" -- "$signed"
}

stage_verify_detached() {
  # The strong guarantee: a signature over the tarball's own bytes.
  # Args: $1 = .asc file, $2 = the file it signs, $3 = description.
  local sig="$1" file="$2" what="${3:-$2}"
  _stage_gpg_verify "$what" -- "$sig" "$file"
}

# --------------------------------------------------------------------------- #
#  Corroboration: size and checksum                                           #
# --------------------------------------------------------------------------- #
stage_check_size() {
  # Args: $1 = file, $2 = the size the signed latest-*.txt announced.
  local file="$1" expected="$2" actual
  actual="$(stat -c '%s' -- "$file" 2>/dev/null || printf '0')"
  if [[ "$actual" == "$expected" ]]; then
    ok "size matches the signed announcement: ${actual} bytes"
    return 0
  fi
  err "size does not match the signed announcement"
  err "       announced: ${expected} bytes"
  err "       on disk:   ${actual} bytes"
  err "       the announcement is signed, so the file on disk is the wrong one"
  return 1
}

stage_verify_sha256() {
  # Corroboration, never a substitute: the mirror serves both the tarball and
  # this checksum, so on its own it proves only that the mirror agrees with
  # itself. It is worth having because it catches a corrupted download with a
  # clearer message than a bad signature would.
  # Args: $1 = the verified payload of the .sha256 file, $2 = the tarball.
  local sums="$1" file="$2" base expected actual adjective="signed"
  stage_verifies || adjective="unverified"
  base="${file##*/}"
  expected="$(awk -v b="$base" '$2 == b || $2 == "*" b { print $1; exit }' "$sums")"
  if [[ -z "$expected" ]]; then
    warn "the ${adjective} .sha256 names no digest for ${base}; skipping the checksum cross-check"
    return 0
  fi
  if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
    err "the ${adjective} .sha256 holds something that is not a SHA-256 digest: ${expected}"
    return 1
  fi
  if ! have sha256sum; then
    warn "sha256sum not found; the signature was checked but the checksum was not"
    return 0
  fi
  actual="$(sha256sum -- "$file" | awk '{ print $1 }')"
  if [[ "${actual,,}" == "${expected,,}" ]]; then
    ok "sha256 matches the ${adjective} checksum file"
    return 0
  fi
  err "sha256 does not match the ${adjective} checksum file"
  err "       expected: ${expected}"
  err "       computed: ${actual}"
  return 1
}

# --------------------------------------------------------------------------- #
#  Download                                                                   #
# --------------------------------------------------------------------------- #
_stage_classify_http() {
  # Turn a downloader's exit status into one of the three answers that matter.
  # Args: $1 = curl exit status, $2 = HTTP status code.
  # Prints: ok | transient | permanent | range
  local rc="$1" code="$2"
  case "$rc" in
    0) printf 'ok\n' ;;
    22)
      # --fail was triggered: the HTTP code says whether waiting can help.
      case "$code" in
        408 | 425 | 429 | 500 | 502 | 503 | 504) printf 'transient\n' ;;
        *) printf 'permanent\n' ;;
      esac
      ;;
    # dns, connect, partial transfer, timeout, send/recv, http2, empty reply
    5 | 6 | 7 | 18 | 28 | 52 | 55 | 56 | 92) printf 'transient\n' ;;
    # the mirror refused a ranged request, or the local part is unusable
    33 | 36) printf 'range\n' ;;
    # everything else — TLS failures above all — is not fixed by waiting
    *) printf 'permanent\n' ;;
  esac
}

_stage_http_get() {
  # One attempt. Args: $1 = url, $2 = destination, $3 = resume (yes|no).
  # Returns 0 ok, 1 transient, 2 permanent, 3 the range was refused.
  local url="$1" dest="$2" resume="${3:-no}"
  local rc=0 code="000" verdict err_file
  local -a cmd=()

  _stage_scratch || return 2
  err_file="${_STAGE_SCRATCH}/http.err"
  : >"$err_file"

  if have curl; then
    cmd=(curl --silent --show-error --fail --location --retry 0
      --connect-timeout "$_STAGE_CONNECT"
      --speed-time "$_STAGE_STALL_TIME" --speed-limit "$_STAGE_STALL_RATE"
      --user-agent "gentoo-install/${VERSION:-0} (+https://github.com)")
    if [[ "$resume" == "yes" ]]; then
      cmd+=(--continue-at -)
    fi
    cmd+=(--write-out '%{http_code}' --output "$dest" -- "$url")
    code="$("${cmd[@]}" 2>"$err_file")" || rc=$?
  elif have wget; then
    cmd=(wget --quiet --tries=1 --timeout="$_STAGE_CONNECT")
    if [[ "$resume" == "yes" ]]; then
      cmd+=(--continue)
    fi
    cmd+=(-O "$dest" -- "$url")
    "${cmd[@]}" 2>"$err_file" || rc=$?
    # wget's statuses do not separate "gone" from "try again", so the message
    # it printed is the only evidence there is.
    if ((rc != 0)); then
      if grep -qE '40[0-9] |41[0-9] |ERROR 4' "$err_file"; then
        rc=22
        code="404"
      else
        rc=7
      fi
    fi
  else
    err "neither curl nor wget is available; nothing can be downloaded"
    err "       example:  emerge --ask net-misc/curl"
    return 2
  fi

  verdict="$(_stage_classify_http "$rc" "$code")"
  case "$verdict" in
    ok) return 0 ;;
    range)
      warn "the mirror refused a ranged request for ${url##*/} (curl ${rc})"
      return 3
      ;;
    transient)
      warn "transient failure fetching ${url##*/} (curl ${rc}, HTTP ${code})"
      _stage_show_http_error "$err_file"
      return 1
      ;;
    *)
      err "cannot fetch ${url}"
      err "       HTTP ${code}, curl exit ${rc} — this is not a transient error"
      if [[ "$code" == "404" ]]; then
        err "       the mirror does not have this file; a retry would only be slower"
        err "       check --arch, --init and --flavour, or try another --config mirror"
      fi
      _stage_show_http_error "$err_file"
      return 2
      ;;
  esac
}

_stage_show_http_error() {
  local file="$1" line
  [[ -s "$file" ]] || return 0
  while IFS= read -r line; do
    warn "       ${line}"
  done <"$file"
}

stage_fetch() {
  # The dry-run-aware door. Args: $1 = url, $2 = destination, $3 = resume.
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would fetch ${1} -> ${2}"
    return 0
  fi
  _stage_fetch_now "$@"
}

_stage_fetch_now() {
  # Retry what a retry can fix, and only that. A blind loop around a 404 turns
  # a clear failure into a slow one (DESIGN.md §9).
  #
  # This one downloads even under --dry-run, and exactly one caller uses it:
  # resolving the signed pointer reads a remote file and changes nothing here,
  # which is what lets --dry-run print the real path and the real size.
  # Args: $1 = url, $2 = destination, $3 = resume (yes|no).
  local url="$1" dest="$2" resume="${3:-no}"
  local attempt=1 status delay="$_STAGE_BACKOFF" dir

  dir="${dest%/*}"
  [[ "$dir" != "$dest" ]] || dir="."
  mkdir -p -- "$dir" || {
    err "cannot create ${dir}"
    return 1
  }

  while ((attempt <= _STAGE_ATTEMPTS)); do
    status=0
    _stage_http_get "$url" "$dest" "$resume" || status=$?
    case "$status" in
      0) return 0 ;;
      2)
        return 1
        ;; # permanent: _stage_http_get has already explained it
      3)
        # Start over without a Range header, once, rather than retrying a
        # request the mirror will refuse identically.
        rm -f -- "$dest"
        resume="no"
        ;;
      *)
        if ((attempt < _STAGE_ATTEMPTS)); then
          log "retrying in ${delay}s (attempt $((attempt + 1)) of ${_STAGE_ATTEMPTS})"
          sleep "$delay"
          delay=$((delay * 2))
        fi
        ;;
    esac
    attempt=$((attempt + 1))
  done

  err "gave up on ${url} after ${_STAGE_ATTEMPTS} attempts"
  err "       every attempt failed for a reason that could have been temporary"
  err "       an interrupted download is kept, so a rerun resumes it"
  return 1
}

# --------------------------------------------------------------------------- #
#  The chain                                                                  #
# --------------------------------------------------------------------------- #
stage_resolve_latest() {
  # Step one and two of the chain: fetch latest-stage3-<arch>-<variant>.txt,
  # verify its clear signature, and read the path and byte count out of what
  # gpg wrote — not out of the file, which also carries unsigned text.
  #
  # The result is never cached: the freshest signed pointer is the whole point,
  # and a stale one on disk would be a stale one used.
  #
  # Args: $1 = arch, $2 = variant id.
  # Fills STAGE_RELPATH, STAGE_SIZE and STAGE_POINTER. Returns 1 and explains.
  # Not to be called inside $( ): see the note on the result globals above.
  local arch="$1" variant="$2"
  local url signed plain line relpath size expected_prefix

  STAGE_RELPATH=""
  STAGE_SIZE=""
  STAGE_POINTER=""

  url="$(stage_latest_url "$arch" "$variant")"
  log "resolving ${url}"

  _stage_scratch || return 1
  signed="${_STAGE_SCRATCH}/latest.txt"
  plain="${_STAGE_SCRATCH}/latest.plain"
  rm -f -- "$signed" "$plain"

  # _stage_fetch_now, not stage_fetch: reading a signed pointer into a
  # temporary directory changes nothing on this machine, and --dry-run has to
  # be able to print the real path and the real size. The caller stops before
  # anything is written anywhere that matters.
  _stage_fetch_now "$url" "$signed" "no" || return 1

  if stage_verifies; then
    if ! stage_verify_clearsigned "$signed" "$plain" "latest-stage3-${arch}-${variant}.txt"; then
      err "       this file decides which tarball gets installed"
      err "       an unverified one lets the mirror choose; that is the attack"
      return 1
    fi
  else
    stage_warn_unverified
    # Strip the clearsign envelope by hand, which is exactly the parsing this
    # module refuses to do when verification is on.
    sed -e '1,/^$/d' -e '/^-----BEGIN PGP SIGNATURE-----/,$d' "$signed" >"$plain"
  fi

  # Only the signed payload is parsed, and only lines that are not comments.
  line="$(awk '!/^#/ && NF == 2 { print; exit }' "$plain")"
  if [[ -z "$line" ]]; then
    err "the signed pointer holds no '<path> <size>' line"
    err "       expected something like: 20260830T151604Z/stage3-${arch}-${variant}-....tar.xz 277751876"
    err "       the mirror served ${url}"
    return 1
  fi
  relpath="${line%% *}"
  size="${line##* }"

  # The path is joined into a URL and into a local filename, so its shape is
  # checked before it is used anywhere. A signed file is still parsed input.
  if [[ ! "$relpath" =~ ^[0-9]{8}T[0-9]{6}Z/stage3-[A-Za-z0-9_]+-[A-Za-z0-9._+-]+\.tar\.(xz|bz2)$ ]]; then
    err "the signed pointer names a path of an unexpected shape: ${relpath}"
    err "       expected <timestamp>/stage3-<arch>-<variant>-<timestamp>.tar.xz"
    return 1
  fi
  if [[ ! "$size" =~ ^[1-9][0-9]{5,}$ ]]; then
    err "the signed pointer announces an implausible size: ${size}"
    err "       a stage3 is hundreds of megabytes; this is not one"
    return 1
  fi
  expected_prefix="stage3-${arch}-${variant}-"
  if [[ "${relpath##*/}" != "${expected_prefix}"* ]]; then
    err "the signed pointer names a tarball for something else: ${relpath##*/}"
    err "       asked for ${arch} / ${variant}, so the name should start with ${expected_prefix}"
    return 1
  fi

  # The record. Grouped so that one directive covers all three: shellcheck
  # cannot see steps/40_stage.sh reading them.
  # shellcheck disable=SC2034
  {
    STAGE_RELPATH="$relpath"
    STAGE_SIZE="$size"
    STAGE_POINTER="$url"
  }
}

stage_acquire() {
  # Steps five to seven: download the tarball and its detached signature,
  # verify the signature over the tarball's own bytes, cross-check the signed
  # checksum and the announced size. A tarball already in the cache is
  # re-verified, not re-downloaded.
  #
  # Args: $1 = arch, $2 = relpath (from the signed pointer), $3 = size.
  # Fills STAGE_TARBALL with the local path of the verified tarball.
  # Not to be called inside $( ): see the note on the result globals above.
  local arch="$1" relpath="$2" size="$3"
  local base url cache tarball asc sums plain have_bytes free

  STAGE_TARBALL=""
  base="${relpath##*/}"
  url="$(stage_autobuilds_url "$arch")/${relpath}"
  cache="$(stage_cache_dir)"
  tarball="${cache}/${base}"
  asc="${tarball}.asc"
  sums="${tarball}.sha256"
  plain="${tarball}.sha256.verified"

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: would download ${url} (${size} bytes) into ${cache}"
    log "dry-run: would verify ${base}.asc, ${base}.sha256 and the byte count"
    return 0
  fi

  if ! mkdir -p -- "$cache"; then
    err "cannot create the stage cache ${cache}"
    err "       example:  stage_cache_dir = /var/tmp/gentoo-install   (--config)"
    return 1
  fi

  # The small signed files are always fetched fresh: they are a few hundred
  # bytes, and a stale one from a previous timestamp would be the wrong one.
  if stage_verifies; then
    stage_fetch "${url}.asc" "$asc" "no" || return 1
  fi
  if stage_fetch "${url}.sha256" "$sums" "no"; then
    if stage_verifies; then
      stage_verify_clearsigned "$sums" "$plain" "${base}.sha256" || return 1
    else
      sed -e '1,/^$/d' -e '/^-----BEGIN PGP SIGNATURE-----/,$d' "$sums" >"$plain"
    fi
  else
    warn "no .sha256 beside the tarball; the detached signature remains the guarantee"
    rm -f -- "$plain"
  fi

  # Already here? Say so rather than spending 300 MB of somebody's bandwidth
  # proving it again — but prove it is the right file first (DESIGN.md §9).
  if [[ -f "$tarball" ]]; then
    have_bytes="$(stat -c '%s' -- "$tarball" 2>/dev/null || printf '0')"
    if ((have_bytes == size)); then
      log "${base} is already in ${cache}; verifying it instead of downloading it"
      if _stage_verify_all "$tarball" "$asc" "$plain" "$size" "$base"; then
        skip "${base}: already downloaded and verified, not fetched again"
        STAGE_TARBALL="$tarball"
        return 0
      fi
      err "the cached copy of ${base} does not verify; removing it"
      rm -f -- "$tarball"
    elif ((have_bytes > size)); then
      warn "the cached ${base} is larger than the signed size; starting over"
      rm -f -- "$tarball"
    else
      log "resuming ${base} at ${have_bytes} of ${size} bytes"
    fi
  fi

  free="$(_stage_free_bytes "$cache")"
  if ((free > 0 && free < size)); then
    err "not enough room in ${cache} for ${base}"
    err "       needed: ${size} bytes"
    err "       free:   ${free} bytes"
    err "       example:  stage_cache_dir = /mnt/gentoo/var/tmp   (--config)"
    return 1
  fi

  log "downloading ${base} ($(stage_human_size "$size"))"
  stage_fetch "$url" "$tarball" "yes" || return 1

  if ! _stage_verify_all "$tarball" "$asc" "$plain" "$size" "$base"; then
    err "removing ${tarball} so that a rerun does not resume from bytes that failed"
    rm -f -- "$tarball"
    return 1
  fi

  # shellcheck disable=SC2034  # read by steps/40_stage.sh
  STAGE_TARBALL="$tarball"
}

_stage_verify_all() {
  # Size, then the detached signature, then the checksum. The order is the
  # order of cost, and the signature is the one that decides.
  # Args: $1 = tarball, $2 = .asc, $3 = verified checksum payload, $4 = size,
  #       $5 = base name.
  local tarball="$1" asc="$2" plain="$3" size="$4" base="$5"
  stage_check_size "$tarball" "$size" || return 1
  if stage_verifies; then
    if [[ ! -s "$asc" ]]; then
      err "no detached signature for ${base}"
      return 1
    fi
    log "verifying the detached signature over ${base} (this reads the whole file)"
    stage_verify_detached "$asc" "$tarball" "$base" || return 1
  else
    stage_warn_unverified
  fi
  if [[ -s "$plain" ]]; then
    stage_verify_sha256 "$plain" "$tarball" || return 1
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  A stage of one's own                                                       #
# --------------------------------------------------------------------------- #
stage_local_source() {
  # Prints "file", "url" or nothing. Refuses both at once: they name two
  # different archives, and guessing which one wins is how an operator installs
  # a system he did not choose.
  local f="${CFG[stage_file]:-}" u="${CFG[stage_url]:-}"

  if [[ -n "$f" && -n "$u" ]]; then
    err "stage_file and stage_url both name a stage"
    err "       stage_file  an archive already on this machine"
    err "       stage_url   an archive to fetch from somewhere else"
    err "       example:  --stage-file /srv/stage3-custom.tar.xz"
    return 1
  fi
  if [[ -n "$f" ]]; then
    printf 'file\n'
  elif [[ -n "$u" ]]; then
    printf 'url\n'
  fi
  return 0
}

stage_local_check_file() {
  # Args: $1 = path. The archive has to exist, be readable, and look like a tar
  # of a kind tar can open. Everything else is the operator's business.
  local path="$1"

  if [[ ! -f "$path" ]]; then
    err "No such stage archive: ${path}"
    err "       stage_file names an archive that is already on this machine"
    err "       example:  --stage-file /srv/stage3-amd64-openrc.tar.xz"
    return 1
  fi
  if [[ ! -r "$path" ]]; then
    err "Cannot read the stage archive: ${path}"
    err "       check its permissions, or run this as root"
    return 1
  fi
  case "$path" in
    *.tar | *.tar.xz | *.tar.gz | *.tar.bz2 | *.tar.zst | *.txz | *.tgz | *.tbz2) ;;
    *)
      warn "${path##*/} does not end in a tar suffix this project recognises"
      warn "       tar will be asked to open it anyway; it decides, not the name"
      ;;
  esac
  return 0
}

stage_local_verify() {
  # Args: $1 = the archive on disk.
  #
  # A stage of one's own carries no promise. The catalogue path verifies a
  # signed pointer and then a detached signature, because Gentoo signs both;
  # here there is nothing to check against unless the operator brings it. So
  # verification is opt-in, and its absence is said out loud rather than
  # implied by silence.
  local tarball="$1" sig="${CFG[stage_signature]:-}" want="${CFG[stage_checksum]:-}"
  local checked=0 got

  if [[ -z "$sig" && -f "${tarball}.asc" ]]; then
    sig="${tarball}.asc"
    log "found ${sig##*/} beside the archive"
  fi

  if [[ -n "$sig" ]]; then
    if [[ ! -r "$sig" ]]; then
      err "Cannot read the signature: ${sig}"
      return 1
    fi
    if ! stage_verify_detached "$sig" "$tarball"; then
      err "the signature does not match ${tarball##*/}"
      err "       this archive is not what whoever signed it signed"
      return 1
    fi
    ok "signature verified against ${sig##*/}"
    checked=1
  fi

  if [[ -n "$want" ]]; then
    if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
      err "Invalid sha256: ${want}"
      err "       sixty-four lowercase hexadecimal characters"
      err "       example:  --stage-checksum $(printf 'a%.0s' {1..64})"
      return 1
    fi
    got="$(sha256sum -- "$tarball" 2>/dev/null | cut -d" " -f1)"
    if [[ "$got" != "$want" ]]; then
      err "sha256 mismatch on ${tarball##*/}"
      err "       expected  ${want}"
      err "       got       ${got:-<unreadable>}"
      return 1
    fi
    ok "sha256 matches"
    checked=1
  fi

  if ((checked == 0)); then
    warn "nothing verified this archive"
    warn "       a stage of one's own carries no signature this project can"
    warn "       check on its own. Bring one and it will be used:"
    warn "         --stage-signature FILE   a detached .asc"
    warn "         --stage-checksum  SHA    an expected sha256"
    warn "       Unpacking it anyway, because that is what was asked."
  fi
  return 0
}

_stage_assert_target_mounted() {
  # The runner accumulates failures rather than stopping (DESIGN.md §4), which
  # is deliberate: one broken step must not hide the state of the rest. But it
  # leaves a hole this guard closes. When step 20 fails, the target filesystem
  # is never mounted, and step 40 then unpacks the stage into what is still an
  # ordinary directory on the machine running the installer. That happened:
  # 1.3 GB of stage3 landed on the installer's own disk, invisible afterwards
  # because the next successful run mounted the real filesystem on top of it.
  #
  # The check only bites when step 20 recorded a mountpoint. Installing into a
  # plain directory with --root, with no disk plan at all, stays a supported
  # thing to do.
  #
  # It used to bite only when the recorded mountpoint was the very path about
  # to be written, and that let the case it exists for walk straight past: when
  # the two disagree, nothing is mounted on this root either, and the stage
  # goes to the installer's own disk just the same. They disagree whenever
  # --root changed between the run that partitioned and the run that unpacks.
  # Args: $1 = the root about to be unpacked into. Returns 1 to refuse.
  local root="$1" planned=""
  planned="$(state_get disk.mountpoint 2>/dev/null || true)"
  [[ -n "$planned" ]] || return 0
  if findmnt -rno TARGET --mountpoint "$root" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$planned" != "$root" ]]; then
    err "the disk plan mounted the target on ${planned}, and this would unpack into ${root}"
    err "       nothing is mounted on ${root}, so the stage would land on the disk"
    err "       of the machine running the installer, not on the target"
    err "       run:  ./gentoo-install.sh --root ${planned} --steps 40"
    return 1
  fi
  err "nothing is mounted on ${root}, but the disk plan says step 20 mounted the target there"
  err "       step 20 failed or has not run, so this would unpack the stage onto"
  err "       the disk of the machine running the installer, not onto the target"
  err "       run:  ./gentoo-install.sh --steps 20 --resume"
  return 1
}

stage_unpack() {
  # The last step, with the options the Gentoo handbook requires:
  #   --xattrs-include='*.*'  capabilities and SELinux labels survive; without
  #                           it a hardened or SELinux stage unpacks broken
  #   --numeric-owner         uids come from the tarball, not from this host's
  #                           /etc/passwd, which has different users
  # Args: $1 = tarball, $2 = the root to unpack into.
  local tarball="$1" root="$2" free
  local -a options=(--xattrs-include='*.*' --numeric-owner)

  if [[ ! -d "$root" ]]; then
    err "the target root ${root} does not exist"
    err "       step 20 partitions and step 50 mounts; run them first"
    err "       example:  --steps 20,40"
    return 1
  fi

  _stage_assert_target_mounted "$root" || return 1

  if [[ -e "${root}/etc/gentoo-release" ]]; then
    skip "${root} already holds an unpacked stage (etc/gentoo-release exists)"
    return 0
  fi

  free="$(_stage_free_bytes "$root")"
  if ((free > 0 && free < 3221225472)); then
    warn "${root} has $(stage_human_size "$free") free; a stage3 unpacks to roughly 1.5 GiB"
    warn "       and portage needs several more before anything is built"
  fi

  log "unpacking ${tarball##*/} into ${root}"
  if ! run_cmd tar xpf "$tarball" "${options[@]}" -C "$root"; then
    err "tar refused to unpack ${tarball}"
    err "       the signature was good, so this is the filesystem, not the file"
    err "       a target that cannot store extended attributes is the usual cause"
    return 1
  fi
  ok "stage unpacked into ${root}"
}

# --------------------------------------------------------------------------- #
#  Small helpers                                                              #
# --------------------------------------------------------------------------- #
_stage_free_bytes() {
  # Prints free bytes, or 0 when it cannot tell. Never fails the caller.
  local path="$1" out
  [[ -d "$path" ]] || path="${path%/*}"
  out="$(df -P -B1 -- "$path" 2>/dev/null | awk 'NR == 2 { print $4 }')" || out=""
  if [[ "$out" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$out"
  else
    printf '0\n'
  fi
}

stage_human_size() {
  # Bytes as MiB or GiB, one decimal. A returned value, so stdout.
  local b="${1:-0}"
  if ((b >= 1073741824)); then
    printf '%d.%d GiB\n' $((b / 1073741824)) $((b % 1073741824 * 10 / 1073741824))
  elif ((b >= 1048576)); then
    printf '%d.%d MiB\n' $((b / 1048576)) $((b % 1048576 * 10 / 1048576))
  else
    printf '%d bytes\n' "$b"
  fi
}

# --------------------------------------------------------------------------- #
#  Rendering — prints, changes nothing                                        #
# --------------------------------------------------------------------------- #
stage_show_selection() {
  # Args: $1 = variant, $2 = libc, $3 = comma-separated constraints.
  local variant="$1" libc="$2" constraints="${3:-}" item
  local -a list=()
  log "stage3 variant  ${variant}"
  log "  init          ${CFG[init]:-openrc}"
  log "  flavour       ${CFG[flavour]:-base}"
  log "  libc          ${libc}"
  if [[ -z "$constraints" || "$constraints" == "none" ]]; then
    log "  constraints   none"
    return 0
  fi
  IFS=',' read -ra list <<<"$constraints"
  log "  constraints"
  for item in "${list[@]}"; do
    log "$(printf '    %-20s %s' "$item" "$(stage_constraint_note "$item")")"
  done
}

stage_show_plan() {
  # What the chain resolved to, before anything is downloaded. This is what
  # --dry-run exists to print.
  # Args: $1 = arch, $2 = variant, $3 = relpath, $4 = size, $5 = pointer url.
  local arch="$1" variant="$2" relpath="$3" size="$4" pointer="$5"
  local keyring="${_STAGE_KEYRING_USED:-}"
  if [[ -z "$keyring" ]]; then
    keyring="$(stage_keyring)" || keyring="none — verification would refuse"
  fi
  log "stage3 plan"
  log "  mirror        $(stage_mirror)"
  log "  pointer       ${pointer}"
  log "  tarball       $(stage_autobuilds_url "$arch")/${relpath}"
  log "  signature     $(stage_autobuilds_url "$arch")/${relpath}.asc"
  log "  size          ${size} bytes ($(stage_human_size "$size"))"
  log "  cache         $(stage_cache_dir)/${relpath##*/}"
  log "  unpack into   $(stage_root)"
  if stage_verifies; then
    log "  verification  clearsigned pointer, detached .asc, signed .sha256, byte count"
    log "  keyring       ${keyring}"
  else
    log "  verification  OFF (verify_signatures = no)"
  fi
}

stage_show_result() {
  # Args: $1 = tarball path, $2 = root.
  ok "stage3 ready"
  log "  tarball       ${1}"
  log "  unpacked into ${2}"
}
