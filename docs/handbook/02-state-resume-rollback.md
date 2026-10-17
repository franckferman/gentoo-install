# State, resume & rollback

> A Gentoo install compiles a kernel, so an interruption three hours in must not
> start over. A small journal records what each step completed, `--resume` reads
> it, `--restart` throws it away, and this chapter is honest about what can and
> cannot be undone. It maps to `lib/state.sh`, not to a numbered step.

## What the installer does

Every step that finishes is recorded in a journal at `<state-dir>/state`,
default `/var/lib/gentoo-install/state`. The runner does it: when a step function
returns success, `run_steps()` calls `state_done NN`, which writes
`step.NN=done <timestamp>`. Steps also use the same journal to tell later steps
what they did (the disk step records the layout and the LUKS UUID, the crypt step
reads them). A second file, the log at `<log-file>` (default
`/var/log/gentoo-install.log`), gets a timestamped line for every message and
every command the installer runs.

`--resume` skips the steps the journal marks done. `--restart` deletes the
journal and runs from the top. The two contradict each other, so asking for both
is refused at parse time.

## Concepts

### Two files, two jobs

- **The state journal** (`<state-dir>/state`) is machine-readable `key=value`,
  mode `0600`, rewritten atomically. It is the resume record and the channel one
  step uses to hand facts to the next. `state_dump` (and `--json`) read it back.
- **The log file** (`<log-file>`) is an append-only, timestamped history for your
  eyes: every `[*]`/`[+]`/`[!]`/`[x]` line and every `[$]` command is mirrored
  into it, so you can read afterwards exactly what happened and when.

### The journal records what was done, never with what

`state_set()` refuses any key matching `*password*`, `*passphrase*`, `*secret*`,
`*_key`, or `*_token`, as an internal error rather than trusting the caller to
remember. A passphrase, a key file's contents, a root password: none of them ever
reach the journal. The journal says a container was created, not what opens it.

### Why a default loses to the journal

Settings the steps read through `target_fact()` follow their own order: an
*explicit* value (you asked for it) wins, then the *journal*, then the built-in
*default*. The journal beating a default is the point. Imagine a `--resume` run
with no config file: the built-in default for `crypt` would answer "about" a
machine that step 30 encrypted hours ago, and every later check would then verify
a plain install that does not exist. A verifier that trusts the plan over the
machine is not a verifier, so the recorded fact wins over the guess.

### The default journal is in RAM on a live medium

On the Gentoo live ISO, `/var/lib` is a tmpfs, so the default
`/var/lib/gentoo-install` lives in RAM. Interrupt the install, reboot the medium,
and `--resume` has nothing to resume from: the record of which steps completed,
and the disk plan step 20 wrote beside it, are both gone. The installer warns
about this once, up front. Put the journal somewhere that survives with
`--state-dir`.

### `--on-conflict`: what happens to a file that already differs

When a file the installer writes already exists with different content, the
writers in `lib/core.sh` ask `--on-conflict` (default `backup`):

- `overwrite` replaces it, no questions.
- `skip` leaves the existing file and carries on.
- `prompt` asks once per file (and with `--non-interactive` falls back to skip).
- `backup` copies the original aside first, to `<file>.gi-<timestamp>.bak`, then
  writes.

This is the only form of per-file undo the installer keeps. The `hardened`
profile sets it to `prompt`.

## Do it by hand

### 1. Put the journal somewhere persistent

```bash
# live
./gentoo-install.sh --state-dir /run/media/usb/gi-state --config /root/myhost.conf
```

By hand, the official handbook gives you no journal at all: *you* are the journal,
and keeping notes of which commands you have already run is the manual equivalent
of what `state_done` does automatically.

### 2. Read what the installer has recorded

```bash
# live
sort /var/lib/gentoo-install/state
```

Expect lines like `step.10=done 2026-...Z`, `step.20=done ...`, and the facts
steps hand each other (the disk layout, the LUKS UUID). You can watch progress in
the log too:

```bash
# live
tail -f /var/log/gentoo-install.log
```

### 3. Resume after a failure

Fix whatever the failed step reported, then:

```bash
# live
./gentoo-install.sh --resume
```

Done steps are skipped (the plan prints `already done, --resume will skip it`),
and the run continues from the first step that is not recorded.

### 4. Start over

**Warning:** `--restart` clears the journal so the pipeline runs from step 10 again. It
does **not** un-partition a disk or restore anything step 20 erased. It only
forgets that those steps ran:

```bash
# live
./gentoo-install.sh --restart
```

### 5. Choose a log location

```bash
# live
./gentoo-install.sh --log-file /run/media/usb/install.log
```

## Verify

```bash
# live
./gentoo-install.sh --resume --json | grep -A1 '"number": 20'
```

`--json` reports `"done": true` or `false` per step from the journal, and
`show_plan` marks each done step in the plan. A quick `grep '^step\.' state`
confirms exactly which numbers completed. The journal is also where pre-flight
records its verdict (`preflight.result`), so a passing pre-flight is visible
there.

## Pitfalls and rollback

Be clear-eyed about this: **this installer has no general rollback.** There is no
`--rollback` command. Once step 20 partitions and formats the target, that is
irreversible, and `--restart` only deletes the journal, it does not put the old
partitions back. What recovery does exist is narrow and specific:

- **File writers keep backups.** With `--on-conflict backup` (the default) and
  for the validated writes, the original is copied to `<file>.gi-<timestamp>.bak`.
  If the run fails, those backups are kept and listed; restore one with a plain
  `cp`. On a clean run they are removed, because a directory of identical copies
  is a directory nobody reads.
- **`cleanup()` runs on exit** and undoes only what *this* run did: it unmounts
  the mounts the run created (innermost first), removes the temporaries it made,
  and restores the CPU governor. It never scans the system and guesses.
- **`--resume` and `--restart` contradict** and are refused together.
- **A journal on tmpfs is forgotten on reboot.** Use `--state-dir` on persistent
  media, or a resumed install starts from the beginning.
- **A stale journal is trusted over a default, on purpose** (see Concepts), so
  resuming reflects the machine, not an out-of-date guess. Use `--restart` only
  when you genuinely mean to re-run from the top.

The real safety model is upstream of all this: run [`--dry-run`](01-configuration-cli.md)
until the plan is right, and treat step 20 (disk) and step 30 (LUKS format) as
the irreversible acts they are.

## Reference

- **Spans:** the whole run (not a step); written by `run_steps()` via
  `lib/state.sh`, logged by `lib/core.sh`
- **Uses:** `lib/state.sh` (`state_set`/`state_get`, `state_done`,
  `state_is_done`, `state_reset`, the tmpfs warning), `lib/core.sh` (the log,
  `backup_file`/`restore_backup`, `cleanup`, `resolve_conflict`)
- **Flags/settings:** `--resume`, `--restart`, `--on-conflict`, `--state-dir`,
  `--log-file`
- **Writes:** `<state-dir>/state` (mode `0600`), `<log-file>`, and timestamped
  `*.gi-*.bak` backups beside files it changes

---
[← Previous: Configuration & the CLI](01-configuration-cli.md) · [Handbook index](README.md) · [Next: Pre-flight checks →](03-preflight.md)
