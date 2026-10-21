# Configuration & the CLI

> Every setting is a flag, every flag is a setting, and four layers decide which
> value wins. This chapter is how you choose and record those values before the
> install touches anything. It maps to `parse_args()` and `lib/config.sh`, not to
> a numbered step.

## What the installer does

Configuration is resolved once, in `main()`, before step 10 runs. The order is
the whole contract:

1. `config_init_defaults()` declares every setting the installer knows and gives
   each a built-in default (`lib/config.sh`, plus each module's own
   `*_init_defaults`).
2. `parse_args()` reads the command line, one argument at a time, and records
   each flag as *explicit*.
3. `config_load_file()` reads a `--config FILE` of `key = value` lines, if given.
4. `apply_profile()` fills in whatever a `--profile` implies.
5. The validators run (`config_validate_enums`, the crypt and CPU checks), so a
   bad value dies here, in milliseconds, not two hours into a kernel build.
6. `config_export_runtime()` copies the handful of hot-path switches (`DRY_RUN`,
   `ASSUME_YES`, `FORCE`, `NON_INTERACTIVE`, `ON_CONFLICT`, color) into the
   globals the rest of the code reads.

The end state is one fully resolved settings table (`CFG`). Nothing on disk
changes: the only output is to the log, to `--dump-config`, or to `--json`.

## Concepts

### Every setting is also a flag

The installer declares each setting once, in `config_init_defaults()`. A few
flags have hand-written cases in the parser (`--dry-run`, `--init`, `--flavour`,
`--on-conflict`, and the behavior toggles). Everything else falls through to a
single rule at the bottom of `parse_args()`: a `--some-setting VALUE` is accepted
whenever `some_setting` (dashes turned to underscores) is a known setting. That
is why `--crypt`, `--disk-layout`, `--bootloader`, `--kernel`, `--mirror`, and
`--jobs` work without being listed in `--help`: a hand-kept list drifts, so the
help screen points you at `--dump-config` for the authoritative set instead.

### The four-level precedence

Later always beats earlier, and the order is fixed no matter how you type the
command line:

```
built-in default  <  profile  <  configuration file  <  explicit flag
```

This holds because of how each layer writes. A flag calls `set_explicit`, which
stamps the key as "the operator asked". A config-file line calls `set_default`
(so a flag already parsed wins) and *then* stamps the key explicit (so the
profile cannot touch it). A profile calls only `set_default`, which never
overwrites a stamped key. So a flag beats a file, a file beats a profile, and a
profile beats the built-in default, regardless of argument order.

### Profiles are a small bundle, not a Portage profile

`--profile minimal|default|desktop|server|hardened` is an *installer* meta-profile:
`apply_profile()` sets a few `set_default`s and nothing more.

| Profile  | flavour      | init    | also |
|----------|--------------|---------|------|
| minimal  | base         | openrc  | |
| default  | base         | openrc  | |
| desktop  | desktop      | systemd | |
| server   | nomultilib   | openrc  | |
| hardened | hardened     | openrc  | `on_conflict = prompt` |

Do not confuse this with the **Portage profile** (`eselect profile`), which
step 60 picks from `data/profiles.tsv` based on your flavour and init. See
[Portage](08-portage.md).

### Variant-selecting flags

Four steps delegate their strategy to a `variants/` file, chosen by a flag:

- `--crypt none|luks-passphrase|luks-tpm|luks-keyfile-gpg` (default
  `luks-passphrase`: the installer encrypts unless you ask it not to).
- `--disk-layout minimal|server|desktop|custom` (default `desktop`).
- `--bootloader grub|efistub|systemd-boot|uki` (default `grub`).
- `--kernel dist-kernel|genkernel|manual` (default `dist-kernel`).

`--init openrc|systemd` and `--flavour NAME` select the stage3 and the init
system; an impossible pair (for example `--flavour splitusr --init systemd`,
which upstream never publishes) is refused at parse time by `resolve_stage()`.

### Selecting a subset of steps

`--steps SPEC` runs only part of the pipeline, and `--skip-steps SPEC` removes
steps from whatever is selected. A SPEC is a comma-separated list of step numbers
and ranges, expanded and de-duplicated:

```bash
$ ./gentoo-install.sh --steps 20,40-60,95 --dry-run
$ ./gentoo-install.sh --skip-steps 30 --dry-run     # everything but encryption
```

A **bare number must name a real step**: `--steps 99` is a typo worth stopping
for and is refused with the step table. A **range is a span, not an
enumeration**: `40-60` means "everything that exists between 40 and 60", so the
gaps are not there. An inverted range (`60-40`), an absurd one, or an
empty item (a stray comma) is refused at parse time, never mid-`emerge`. Step
numbers are the stable public API (they never change), which is why selection is
by number. See [State, resume & rollback](02-state-resume-rollback.md) for how
`--steps` combines with `--resume`.

### Values are checked up front, and secrets never ride the command line

`CFG_ENUM` lists the closed sets, so `--bootloader frobnicate` or a config line
`bootloader = frobnicate` is refused before anything is written, in the project's
error voice. Secrets are different: anything whose name matches `*password*`,
`*passphrase*`, `*secret*`, `*_key`, or `*_token` is masked as `<redacted>` in
`--dump-config` and `--json`, and the installer never accepts a passphrase as an
argument, because arguments land in `ps` output and in shell history. Put secrets
in a key file or type them at the prompt.

## Do it by hand

The point of this chapter is deciding and recording your settings before the
irreversible steps. None of this needs root.

### 1. Ask the machine what is available

```bash
$ ./gentoo-install.sh --list-disks       # which disks exist, before --disk
$ ./gentoo-install.sh --list-flavours     # stage3 flavours for --arch
$ ./gentoo-install.sh --list-steps        # the step registry
```

`--list-disks` reads nothing else and writes nothing: it is the question to ask
before you ever name a `--disk`, so you destroy the disk you meant to.

### 2. Preview the whole plan without privileges

```bash
$ ./gentoo-install.sh --dry-run
$ ./gentoo-install.sh --profile server --dry-run
```

`--dry-run` prints every action it would run (each command is logged as
`dry-run: ...`) and changes nothing, so you read the plan first and only then
decide to `sudo`. It needs no root by design.

### 3. Write your decisions into a config file

A config file is the durable, reviewable record of an install, and the manual
equivalent of writing your choices on paper before following the official
handbook. It is `key = value`, one per line, `#` starts a full-line comment:

```ini
# /root/myhost.conf: the install I intend to run
disk        = /dev/nvme0n1
disk_layout = desktop
disk_filesystem = btrfs
crypt       = luks-tpm
bootloader  = systemd-boot
kernel      = dist-kernel
init        = systemd
flavour     = desktop
hostname    = workstation
timezone    = Europe/Paris
locale      = en_US.UTF-8 UTF-8
on_conflict = backup
```

Every key must be a setting the installer declares; a typo like `bootlaoder` is
refused at parse time with the line number, not silently ignored.

```bash
$ ./gentoo-install.sh --config /root/myhost.conf --dry-run
```

### 4. Override at the last moment with a flag

A flag beats the file for one run without editing it, which is how you test one
change:

```bash
$ ./gentoo-install.sh --config /root/myhost.conf --bootloader grub --dry-run
```

### 5. Confirm exactly what will be used

```bash
$ ./gentoo-install.sh --config /root/myhost.conf --dump-config
```

Read the output before you run anything with root.

## Verify

`--dump-config` prints every setting, its (masked) value, and where it came
from:

```
bootloader = systemd-boot             # explicit
crypt      = luks-tpm                 # explicit
init       = openrc                   # default
```

Read the origin carefully. `explicit` means a flag or a config file set it;
`default` means the built-in default *or* a value a profile filled in, because
profiles apply with `set_default` and so do not stamp a key explicit. If a
precedence complaint ever surprises you, this column is how you debug it.

`--json` prints the same resolved config plus the step list as JSON, for a
script to read; secrets are masked there too.

## Pitfalls and rollback

- **Unknown setting in a config file** stops the run at parse time with the line
  number and points you at `--dump-config`. This is a feature: a mistyped key
  used to be accepted and fail hours later.
- **Enum typo** (`crypt = luks-tmp`) is caught the same way, before any disk is
  touched.
- **A profile value shows as `default`.** Expected, see Verify. If you need a
  value guaranteed to win, set it with a flag or in the config file.
- **Secrets on the command line.** The installer refuses them; use a key file or
  the interactive prompt. A passphrase in `ps` or in `~/.bash_history` is a leak.
- **Config file on a volatile medium.** If you keep it on the live ISO's tmpfs it
  is gone after a reboot. Keep it on a USB stick or type it fresh. This is the
  same hazard the [state journal](02-state-resume-rollback.md) warns about.
- **Rollback:** configuration by itself writes nothing, so there is nothing to
  undo. `--dry-run` is the safety net; run it until the plan reads the way you
  mean it.

## Reference

- **Resolved in:** `main()` of `gentoo-install.sh`, before step 10 (not a step)
- **Uses:** `lib/config.sh` (the `CFG` table, `set_default`/`set_explicit`,
  `config_load_file`, `dump_config`), `lib/core.sh` (output, `require_root`),
  `lib/ui.sh` (`confirm`, `prompt_secret`), and the module `*_init_defaults`
- **Flags/settings:** `--profile`, `--config`, `--dump-config`, `--json`,
  `--dry-run`/`-n`, `--yes`/`-y`, `--force`, `--non-interactive`, `--no-color`,
  `--steps`/`--skip-steps`, `--list-steps`/`--list-flavours`/`--list-disks`,
  `--arch`/`--init`/`--flavour`, and every declared setting as `--<setting> VALUE`
- **Writes:** nothing on disk; the config file is one you author. `--dump-config`
  and `--json` print to stdout.

---
[← Previous: Overview & philosophy](00-overview.md) · [Handbook index](README.md) · [Next: State, resume & rollback →](02-state-resume-rollback.md)
