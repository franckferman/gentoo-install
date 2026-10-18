# The stage3 (fetch, verify, unpack)

> Download a stage3 tarball, prove cryptographically that it is the one Gentoo
> published, and unpack it into the target root. This mirrors `steps/40_stage.sh`
> and `lib/stage.sh`, and it is the last point in the install where a substituted
> tarball can still be caught.

## What the installer does

`step_40_stage` walks a trust chain from one end to the other and then unpacks
the result. In order: it picks the stage3 variant that matches your `--arch`,
`--init` and `--flavour`; imports the Gentoo release keys into a throwaway
keyring; downloads the signed pointer file `latest-stage3-<arch>-<variant>.txt`
and verifies its signature; reads the exact tarball name and byte count out of
the verified payload; downloads that tarball with its detached `.asc` signature
and its `.sha256`; verifies the signature over the tarball's own bytes,
cross-checks the signed checksum, and confirms the byte count; then unpacks it
into `/mnt/gentoo` with the extended-attribute and numeric-owner flags a Gentoo
stage3 needs.

The end state is an unpacked base system under the target root: `/bin`, `/usr`,
`/etc/gentoo-release` and everything else a chroot needs, but nothing configured
yet. Everything after this step trusts these bytes completely, which is why the
verification here is not optional and the step refuses to run without the
release keyring.

This step runs on the **live medium**, against the target mounted at
`/mnt/gentoo`. You have not entered the chroot yet; that is the next chapter.

## Concepts

**A mirror is a stranger.** You download the tarball over HTTP(S) from
`distfiles.gentoo.org` or a regional mirror. A regional mirror is a legitimate,
encouraged thing to use, which is exactly why you cannot trust the bytes it
serves on the strength of where they came from. The proof has to travel with the
file, not with the connection.

**Two signatures, checked against the real Gentoo keys.** Gentoo signs two
things with its release keys: the small text file that says *which* tarball is
current, and the tarball itself. The installer imports
`app-crypt/openpgp-keys-gentoo-release` (shipped on the Gentoo live media, at
`/usr/share/openpgp-keys/gentoo-release.asc`) into a disposable keyring and
checks both signatures against it. Your own GnuPG keyring is never read or
written, so nothing this run trusts leaks into your configuration.

**Why the signed pointer exists.** `latest-stage3-<arch>-<variant>.txt` is a
clearsigned file whose body is one line, `<path> <size>`. It decides which
tarball gets installed. If you took the path from an unsigned file, the mirror
would choose your stage3 for you, and nothing downstream would notice. So its
signature is verified first, and the path is read only from what `gpg --output`
wrote, never from the file on disk: text appended outside the signed block is
attacker-controlled and must not be parsed.

**Why the detached signature is the strong link.** The `.asc` beside the tarball
is a signature over the tarball's own bytes. A good signature here means the
bytes you have are the bytes Gentoo signed. This is the guarantee; everything
else corroborates it.

**Why the checksum is checked as well, never instead.** The same mirror serves
the tarball and its `.sha256`. On its own, a matching checksum proves only that
the mirror is self-consistent, which a hostile mirror trivially is. It is still
worth having, because it catches a corrupted or truncated download with a
clearer message than a broken signature would.

**Why the byte count is cross-checked.** The size comes from the *signed*
pointer. If the file on disk is a different size, it is the wrong file, full
stop, and the installer stops before unpacking it.

**gpg's exit code is not enough.** `gpg` exits 0 for a good signature made by an
expired or revoked key, and an empty keyring would turn "no error" into "nothing
checked". The installer reads the machine-readable status output and insists on
seeing both `GOODSIG` and `VALIDSIG`, rejecting `EXPKEYSIG`, `REVKEYSIG` and
`NO_PUBKEY` by name.

## Do it by hand

Everything here runs as root on the live medium. The target is mounted at
`/mnt/gentoo` (chapters 04 and 05).

### 1. Pick the variant

The variant is the suffix Gentoo puts in the filename. It is `init` and
`flavour` composed: `openrc`, `systemd`, `desktop-openrc`, `hardened-systemd`,
and so on. `data/stages.tsv` is the full catalogue. For the common case:

```bash
# live
arch=amd64            # --arch
init=openrc           # --init   (openrc or systemd)
flavour=base          # --flavour
variant=openrc        # base+openrc; base+systemd would be "systemd"
```

**Warning:** Not every combination exists upstream. `splitusr` is published for OpenRC
only; asking for `--flavour splitusr --init systemd` would walk you into a 404
after the disks are already wiped. The installer refuses that pairing at parse
time from the catalogue; by hand, check that
`latest-stage3-<arch>-<variant>.txt` actually exists before you commit.

### 2. Have the release keyring ready

```bash
# live
emerge --ask app-crypt/openpgp-keys-gentoo-release   # if not already present
ls /usr/share/openpgp-keys/gentoo-release.asc
```

**Warning:** Do not fetch the keys over the same untrusted network that serves the
tarball. That moves the trust problem, it does not solve it. The keys come from
the signed live media or a copy you already trust.

Import them into a *temporary* keyring so you do not pollute your own:

```bash
# live
export GNUPGHOME="$(mktemp -d)"
gpg --import /usr/share/openpgp-keys/gentoo-release.asc
```

### 3. Fetch and verify the signed pointer

```bash
# live
base=https://distfiles.gentoo.org/releases/${arch}/autobuilds
curl -fL -o latest.txt "${base}/latest-stage3-${arch}-${variant}.txt"
gpg --verify latest.txt && gpg -o latest.plain -d latest.txt
```

`gpg --verify` proves the signature; `gpg -o latest.plain -d` writes the signed
payload to `latest.plain`. Read the path and size out of `latest.plain`, not out
of `latest.txt`:

```bash
# live
read -r relpath size < <(grep -v '^#' latest.plain | awk 'NF==2{print;exit}')
echo "$relpath"   # e.g. 20260830T170201Z/stage3-amd64-openrc-20260830T170201Z.tar.xz
echo "$size"      # e.g. 277751876
```

### 4. Download the tarball and its proofs

```bash
# live
curl -fL -O "${base}/${relpath}"          # the tarball
curl -fL -O "${base}/${relpath}.asc"      # detached signature over its bytes
curl -fL -O "${base}/${relpath}.sha256"   # signed checksum (corroboration)
```

### 5. Verify, in order of what each proof is worth

```bash
# live
tarball="$(basename "$relpath")"

# a) the detached signature over the tarball's own bytes - the guarantee
gpg --verify "${tarball}.asc" "${tarball}"

# b) the byte count the SIGNED pointer announced
test "$(stat -c %s "$tarball")" = "$size" && echo "size OK"

# c) the signed checksum, verified then compared (corroboration, not a substitute)
gpg -o sha.plain -d "${tarball}.sha256"
grep "$tarball" sha.plain | sha256sum -c -
```

If any of these fails, stop. A bad signature and a truncated download look
identical here, and both are reasons not to proceed. The installer does not
retry a bad signature or a 404; it only retries transient network errors.

### 6. Unpack into the target

**Warning:** Confirm the target filesystem is actually mounted first. If `/mnt/gentoo` is
an empty, unmounted directory, the stage lands on the live medium's own disk and
vanishes under the real filesystem the next time it is mounted.

```bash
# live
findmnt /mnt/gentoo                        # must show your root device
tar xpf "$tarball" --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
```

- `--xattrs-include='*.*'` keeps file capabilities and SELinux labels; without
  it a hardened or SELinux stage unpacks broken.
- `--numeric-owner` takes uids and gids from the tarball, not from the live
  medium's `/etc/passwd`, which has different users.

(The official Gentoo Handbook writes the same intent as
`tar xpvf stage3-*.tar.xz --xattrs-numeric-owner`; the installer's two flags are
the equivalent split out.)

### A stage of your own

If you pass `--stage-file FILE` or `--stage-url URL`, the installer skips the
catalogue and the signed pointer entirely: it unpacks the archive you named.
Nothing can be verified automatically, because there is no published pointer to
check against, so verification becomes opt-in. Bring a proof and it is used:
`--stage-signature FILE` (a detached `.asc`) or `--stage-checksum SHA256`. An
`.asc` sitting beside the archive is picked up on its own. If you bring neither,
the installer unpacks it anyway and says plainly that **nothing verified this
archive**, and records that fact so the closing recap can repeat it.

## Verify

```bash
# live
cat /mnt/gentoo/etc/gentoo-release        # names the profile the stage shipped
ls /mnt/gentoo/usr/bin/ | head            # a populated userland, not an empty tree
ls -la /mnt/gentoo/bin/bash               # must exist and be executable
```

A good `gpg --verify` prints `Good signature from "Gentoo ..."`. The installer
goes further and requires the `GOODSIG` and `VALIDSIG` status lines, so a
signature from an expired or revoked key is refused even though plain `gpg`
would still say "Good signature". If you ran the full installer, step 95's recap
prints the recorded `stage.verified` value (`pgp-signature+sha256+size` when
verification was on).

## Pitfalls and rollback

- **No keyring found.** The installer refuses before downloading anything,
  rather than after a 300 MB transfer. Install
  `app-crypt/openpgp-keys-gentoo-release`, or point `keyring = /path/...` at your
  own copy. To install with no signature check at all, knowing the risk, set
  `verify_signatures = no`; the warning then repeats at every skipped check.
- **`EXPKEYSIG` (expired key).** Almost always a stale local keyring, not a
  stale mirror. Refresh it:
  `emerge --sync && emerge --oneshot app-crypt/openpgp-keys-gentoo-release`.
- **404 on the tarball.** The mirror does not have that file. Re-check `--arch`,
  `--init` and `--flavour`, or try another `mirror`. A retry only makes it
  slower; the installer does not retry a 404.
- **`tar` refuses to unpack.** If the signature was good, the problem is the
  filesystem, not the file, usually a target that cannot store extended
  attributes. Reformat the target with a filesystem that can.
- **Unpacked onto the wrong disk.** If `/mnt/gentoo` was not mounted, the stage
  landed on the live medium. The installer guards against this when step 20
  recorded a mountpoint; by hand, always check `findmnt /mnt/gentoo` first.
- **Rollback.** The stage3 is fetched and unpacked, not an edit to a running
  system. To redo it, remove the unpacked tree (or reformat the target, chapter
  04) and run step 40 again. A completed download is kept in the cache
  (`/var/cache/gentoo-install` by default) and re-verified rather than
  re-fetched on a `--resume`; the installer skips unpacking entirely if
  `etc/gentoo-release` is already present.

## Reference

- **Step:** `40` - `steps/40_stage.sh`
- **Uses:** `lib/stage.sh` (catalogue, keyring, download, verification, unpack)
- **Flags/settings:** `--arch`, `--init`, `--flavour` (compose the variant);
  `--list-flavours`; `mirror`, `keyring`, `verify_signatures`, `stage_cache_dir`,
  `root`; and for a stage of your own `stage_file`, `stage_url`,
  `stage_signature`, `stage_checksum`
- **Writes:** the unpacked stage3 into `root` (default `/mnt/gentoo`); the
  tarball, `.asc` and `.sha256` into `stage_cache_dir`; state-journal entries
  `stage.variant`, `stage.tarball`, `stage.verified`

---
[← Previous: Encryption (LUKS, GPG, TPM)](05-encryption.md) · [Handbook index](README.md) · [Next: Entering the chroot →](07-chroot.md)
