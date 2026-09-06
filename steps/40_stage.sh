#!/usr/bin/env bash
#
# gentoo-install — step 40: fetch, verify and unpack the stage3 tarball
# ----------------------------------------------------------------------------
# Walks the trust chain in lib/stage.sh from one end to the other: pick the
# variant, prove the signed pointer, prove the tarball, unpack it. Every link
# that fails ends the step; none of them is retried past the point where a
# retry could still help.
#
# The one thing to know before touching this: the refusal to run without the
# Gentoo release keyring is the feature, not an obstacle. Everything after
# step 40 trusts these bytes completely, so this is the last place where a
# substituted tarball can still be caught.
#
# Usage:  ./gentoo-install.sh --steps 40   (--help for the list)
#
set -euo pipefail

if [[ -z "${_GI_STAGE_LOADED:-}" ]]; then
  _gi_step40_self="$(readlink -f -- "${BASH_SOURCE[0]}")"
  _gi_step40_lib="${GI_LIB_DIR:-${LIB_DIR:-${_gi_step40_self%/*/*}/lib}}"
  # shellcheck source=lib/stage.sh
  source "${_gi_step40_lib}/stage.sh"
  unset _gi_step40_self _gi_step40_lib
fi

# --------------------------------------------------------------------------- #
#  The step                                                                   #
# --------------------------------------------------------------------------- #
_step_40_local() {
  # Args: $1 = target root, $2 = "file" or "url".
  local root="$1" kind="$2" tarball

  if [[ "$kind" == "file" ]]; then
    tarball="${CFG[stage_file]}"
    stage_local_check_file "$tarball" || return "$EXIT_FAILURE"
    log "stage of your own: ${tarball}"
  else
    tarball="$(stage_cache_dir)/${CFG[stage_url]##*/}"
    log "stage of your own: ${CFG[stage_url]}"
    log "                   into ${tarball}"
  fi

  if is_explicit flavour || is_explicit stage_variant; then
    warn "flavour and stage_variant are ignored when a stage is named outright"
    warn "       what ${tarball##*/} contains is what gets installed"
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: nothing fetched, nothing unpacked"
    return "$EXIT_SUCCESS"
  fi

  if [[ "$kind" == "url" ]]; then
    mkdir -p -- "$(stage_cache_dir)" || return "$EXIT_FAILURE"
    stage_fetch "${CFG[stage_url]}" "$tarball" || return "$EXIT_FAILURE"
    stage_local_check_file "$tarball" || return "$EXIT_FAILURE"
  fi

  stage_local_verify "$tarball" || return "$EXIT_FAILURE"
  stage_unpack "$tarball" "$root" || return "$EXIT_FAILURE"

  state_set "stage.source" "$kind"
  state_set "stage.tarball" "${tarball##*/}"
  stage_show_result "$tarball" "$root"
  return "$EXIT_SUCCESS"
}

step_40_stage() {
  # The disposable keyring is torn down on every path out, including the ones
  # that failed, so a leftover gpg-agent never outlives the step that made it.
  local rc=0
  _step_40_body || rc=$?
  stage_release_gpg_home
  return "$rc"
}

_step_40_body() {
  # The engine's answers arrive in STAGE_RELPATH, STAGE_SIZE, STAGE_POINTER and
  # STAGE_TARBALL rather than on stdout, so none of the calls below may be
  # wrapped in $( ): a subshell would lose the tracked temporaries and the
  # disposable keyring along with the value. lib/stage.sh says why.
  local arch variant libc constraints row root

  stage_init_defaults
  arch="${CFG[arch]:-amd64}"
  root="$(stage_root)"

  # Here rather than in step 60, because everything from the decompression of
  # the archive onwards is CPU-bound and this is the first of it. What it
  # changes belongs to the machine running the installer; it is announced, it
  # is recorded in the journal, and step 95 and cleanup() put it back.
  cpu_apply_governor

  # ------------------------------------------------------------------- #
  #  1. Tools                                                           #
  # ------------------------------------------------------------------- #
  # Named now, all of them at once, rather than one 404 at a time later.
  # What is needed depends on which of the two paths this run takes. Asking for
  # gpg and xz before knowing that is how `--stage-file mine.tar` came to be
  # refused on a machine with neither, for a download it was not going to make
  # and a signature it was not going to check.
  local -a needed=(tar)
  local local_kind
  local_kind="$(stage_local_source)" || return "$EXIT_FAILURE"

  if [[ -z "$local_kind" ]]; then
    # The catalogue path: always fetches, always .tar.xz, and verifies unless
    # told otherwise.
    needed+=(xz)
    if ! have curl && ! have wget; then
      err "Neither curl nor wget is installed; there is no way to fetch a stage3"
      err "       curl  what this module prefers: it reports the HTTP status, so a"
      err "             404 can be told apart from a timeout and is not retried"
      err "       wget  works, with a coarser idea of why a transfer failed"
      err "       example:  emerge --ask net-misc/curl"
      return "$EXIT_FAILURE"
    fi
    if stage_verifies; then
      needed+=(gpg)
    fi
  else
    # A stage of one's own: the compressor follows the archive's own suffix, a
    # fetcher is only needed for a URL, and gpg only if a signature was brought.
    case "${CFG[stage_file]:-${CFG[stage_url]}}" in
      *.xz | *.txz) needed+=(xz) ;;
      *.bz2 | *.tbz2) needed+=(bzip2) ;;
      *.zst) needed+=(zstd) ;;
    esac
    if [[ "$local_kind" == "url" ]] && ! have curl && ! have wget; then
      err "stage_url needs curl or wget, and neither is installed"
      err "       example:  emerge --ask net-misc/curl"
      return "$EXIT_FAILURE"
    fi
    if [[ -n "${CFG[stage_signature]:-}" ]]; then
      needed+=(gpg)
    fi
    if [[ -n "${CFG[stage_checksum]:-}" ]]; then
      needed+=(sha256sum)
    fi
  fi
  require_cmds "${needed[@]}" || return "$EXIT_FAILURE"

  # ------------------------------------------------------------------- #
  #  1b. A stage of one's own, which skips everything below              #
  # ------------------------------------------------------------------- #
  # No catalogue, no signed pointer, no variant: the operator named an
  # archive and that archive is what gets unpacked. Verification becomes
  # opt-in, because there is nothing this project can check on its own.
  if [[ -n "$local_kind" ]]; then
    _step_40_local "$root" "$local_kind"
    return $?
  fi

  # ------------------------------------------------------------------- #
  #  2. Which variant                                                   #
  # ------------------------------------------------------------------- #
  # An impossible init x flavour combination has already died at parse time.
  # Doing it again here costs nothing and keeps the step usable on its own.
  if is_explicit stage_variant && [[ -n "${CFG[stage_variant]:-}" ]]; then
    variant="${CFG[stage_variant]}"
    libc="${CFG[libc]:-glibc}"
    constraints="${CFG[stage_constraints]:-}"
    log "using the stage3 variant the configuration names outright: ${variant}"
  else
    row="$(stage_select "$arch" "${CFG[init]:-openrc}" "${CFG[flavour]:-base}")" \
      || return "$EXIT_FAILURE"
    IFS=$'\t' read -r variant libc constraints <<<"$row"
    CFG[stage_variant]="$variant"
    CFG[libc]="$libc"
    CFG[stage_constraints]="$constraints"
  fi
  stage_show_selection "$variant" "$libc" "$constraints"

  # ------------------------------------------------------------------- #
  #  3. The keyring, before anything is downloaded                      #
  # ------------------------------------------------------------------- #
  # Refusing here rather than after a 300 MB download is the whole difference
  # between a clear error and a wasted twenty minutes.
  if stage_verifies; then
    if ! stage_keyring >/dev/null; then
      stage_explain_missing_keyring
      return "$EXIT_FAILURE"
    fi
  else
    stage_warn_unverified
    warn "       this is what --config verify_signatures = no bought you"
  fi

  # ------------------------------------------------------------------- #
  #  4. and 5. The signed pointer, and what it names                    #
  # ------------------------------------------------------------------- #
  stage_resolve_latest "$arch" "$variant" || return "$EXIT_FAILURE"
  stage_show_plan "$arch" "$variant" "$STAGE_RELPATH" "$STAGE_SIZE" "$STAGE_POINTER"

  # --dry-run stops here: the plan is complete — the resolved URL, the variant,
  # the exact tarball and its announced size — and nothing has been written.
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "dry-run: nothing downloaded, nothing unpacked"
    return "$EXIT_SUCCESS"
  fi

  # ------------------------------------------------------------------- #
  #  6. and 7. Download, verify, cross-check the size                   #
  # ------------------------------------------------------------------- #
  stage_acquire "$arch" "$STAGE_RELPATH" "$STAGE_SIZE" || return "$EXIT_FAILURE"
  if [[ -z "$STAGE_TARBALL" || ! -f "$STAGE_TARBALL" ]]; then
    err "the stage3 was reported as ready but ${STAGE_TARBALL:-<nothing>} is not there"
    return "$EXIT_FAILURE"
  fi

  # ------------------------------------------------------------------- #
  #  8. Unpack                                                          #
  # ------------------------------------------------------------------- #
  stage_unpack "$STAGE_TARBALL" "$root" || return "$EXIT_FAILURE"

  # What was done, never with what: the journal carries names, not secrets.
  state_set "stage.variant" "$variant"
  state_set "stage.tarball" "${STAGE_TARBALL##*/}"
  if stage_verifies; then
    state_set "stage.verified" "pgp-signature+sha256+size"
  else
    state_set "stage.verified" "size+unverified-sha256"
  fi

  stage_show_result "$STAGE_TARBALL" "$root"
  return "$EXIT_SUCCESS"
}
