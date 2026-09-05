# Contributing

Thank you for looking. This is an installer that partitions disks, so the bar
is a little higher than usual and most of it is written down rather than left
to taste.

## Read the contract first

[`docs/DESIGN.md`](docs/DESIGN.md) is not advice. It is fifteen sections that
every file in this repository follows, and a patch that contradicts one of them
will be asked to change even if the code works. It covers the script header,
the output helpers and where they print, the exit codes, the step registry,
configuration precedence, the error voice, the separation of engine and
rendering, how a file is written, idempotence and resume, where data lives, the
lifecycle traps, the safety doctrine, argument parsing, repository quality, and
what this project deliberately does not do.

If you read only one page before writing code, read that one.

## Run the checks

```bash
make lint test
```

`make lint` runs ShellCheck, then `shfmt --diff`, then `bash -n`, over the
entry point, `lib/`, `steps/` and `tools/` — 43 files. `make test` runs the
bats suite when there is one.

**Both tools have to be on your `PATH`, and `make lint` fails plainly if they
are not.** Until that is resolved, the same checks run in containers, with the
same arguments CI uses:

```bash
# ShellCheck
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
  gentoo-install.sh lib/*.sh steps/*.sh tools/*.sh

# Formatting
docker run --rm -v "$PWD:/mnt" -w /mnt mvdan/shfmt:latest \
  --diff --indent 2 --case-indent --binary-next-line \
  gentoo-install.sh lib/*.sh steps/*.sh tools/*.sh

# Syntax, which needs no container
bash -n gentoo-install.sh lib/*.sh steps/*.sh tools/*.sh variants/*/*.sh
```

`make format` rewrites the files with the same shfmt arguments. A ShellCheck
directive must precede the **whole** compound command it applies to — never a
lone `done`, never the middle of a `\` continuation — and `bash -n` stays green
in all the wrong cases, so it is not the check that catches this.

Smoke-test what you changed without touching a disk:

```bash
./gentoo-install.sh --dry-run
./gentoo-install.sh --dump-config
./gentoo-install.sh --json | python3 -m json.tool > /dev/null
```

## A guard rail is not removed without saying what it prevented

The single rule that matters most here. Every refusal, every typed
confirmation, every "verify then roll back" in this repository was put there
because of a specific failure — a disk erased, a machine that would not boot, a
TPM that stopped releasing a key after a firmware update.

If a check is in your way, that is a fact about the check and worth fixing. But
the patch has to say, in the commit message and in the code comment, **what the
guard prevented and why that can no longer happen**. "It was annoying" is not
an answer. A patch that quietly deletes a refusal, widens a `--force` to cover
a proof, or turns a typed confirmation into a `y/n` will be rejected on sight.

The reverse also holds: a new refusal names what it protects against, and comes
with its own switch to lift it — one switch per refusal, never a blanket flag.

## Conventions that come up in review

- **English everywhere.** Code, comments, messages, help text, documentation,
  commit messages. No exceptions.
- **Everything prints to stderr.** stdout carries only values a function
  returns and `--json`. A helper that prints on stdout and is called in `$( )`
  poisons the value.
- **Data goes in `data/`**, one record per line. Not a literal inside a
  function.
- **Adding a setting** means one `set_default` call with its enumeration in the
  trailing comment, and — when it has a closed set of values — its entry in
  `CFG_ENUM`. It then works as a `.conf` key and as a flag with no further
  code.
- **Adding a step** means one line in `STEP_MAP`, one in `STEP_DESC`, and one
  file under `steps/`. Never an `if` in the run loop.
- **The version lives in `gentoo-install.sh` and nowhere else.** Do not restate
  it in the README, in a badge, or in this file.
- **Rescue tools stay standalone.** Nothing under `tools/` may source a
  library. The duplication is deliberate: a tool that cannot be copied alone
  onto a USB stick is useless in the situation it exists for.

## Commits

Conventional Commits, in the imperative, with a scope that names the step
number or the module:

```
feat(30-crypt): add a recovery keyslot to the luks-tpm variant
fix(disk): compare step numbers exactly instead of by substring
docs(readme): state that no end-to-end install has been done yet
refactor(stage): read the pointer payload from gpg, not from the file
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`.

The body explains **why**, not what — the diff already says what. If the change
touches a guard rail, a refusal or a destructive path, the body says what used
to go wrong.

## Pull requests

- One subject per pull request.
- `make lint` clean, or the container commands above clean, and CI green.
- Say how you tested it. "Loop device under `/tmp`", "`--dry-run` on a machine
  with no TPM", "a throwaway VM" are all real answers. `--dry-run` alone is a
  fine answer too — just say so rather than implying more.
- Never test against your own disk or bootloader.

## Reporting a problem

Include the output of `./gentoo-install.sh --version` and
`./gentoo-install.sh --dump-config`, the exact command line, and the step
number that failed. `--dump-config` says where each value came from, which is
usually the whole answer to a precedence question.

If the problem is a security one — a way the trust chain can be bypassed, a
secret reaching a log or the state journal, a refusal that can be sidestepped —
say so in the report and describe it precisely rather than opening a pull
request that demonstrates it.
