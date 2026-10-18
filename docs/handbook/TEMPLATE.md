<!--
  Chapter authoring template + style guide for the gentoo-install Handbook.
  NOT published as a chapter. Every chapter under docs/handbook/ follows this.
  Gold-standard voice reference: the sibling handbook in the gentoo-post-install
  repo (docs/handbook/03-make-conf.md and 19-gpu-drivers.md) uses the same shape.
-->

# Handbook chapter template & style guide

## Voice and rules

- **Audience:** someone installing Gentoo by hand who wants to understand *why*,
  especially the hard parts (disk layout, LUKS, the stage3 trust chain, TPM sealing).
- **Language:** English, US spelling. (The project is English-only; see docs/DESIGN.md.)
- **Tense/person:** second person, present tense. Imperative in steps.
- **Every command is explained.** Never drop a command without saying what it does and
  why it is the right choice. Explain reasoning, not just syntax.
- **Ground everything in the installer.** Each step chapter mirrors one `steps/NN_*.sh`
  phase (and the `lib/*.sh` and `variants/*/*.sh` it uses). The manual commands must
  reach the same end state the installer reaches. Do not invent packages, flags, or
  paths the installer does not use. If unsure, follow the official Gentoo Handbook
  accurately and say what is uncertain; never fabricate.
- **Install-time context.** This runs from a live medium against a target mounted at
  `/mnt/gentoo` (and later inside a chroot). Make clear, in every step, whether a
  command runs on the live system, against the target, or inside the chroot.
- **Both init systems** (OpenRC and systemd) where they differ.
- **Destructive and lock-out steps** (disk wipe, LUKS format, bootloader) get a bold
  **Warning:** marker *before* the command. Mirror the installer's "typed proof"
  caution for the destructive disk step.
- **No em dashes** in prose. Use commas, parentheses, or a period. Hyphens in
  flags/paths are fine.
- **No invented claims.** If a value is a default or heuristic, say so.
- **Cross-link** with the Prev/Next footer and inline links to related chapters.
- Prompts: `# live` = root on the live medium; `# chroot` = inside the target chroot;
  `$` = an unprivileged shell. Be explicit which one each block is.

## Required section structure (step chapters)

```markdown
# <Chapter title>

> One-sentence summary and the matching step / `--flag`.

## What the installer does
Which `steps/NN_*.sh` phase (and libs/variants) this maps to, and the end state.

## Concepts
The background a learner needs: the vocabulary and the trade-offs. The "why".

## Do it by hand
Numbered steps mirroring the installer's actions, each command explained, with the
live / target / chroot context made explicit.

## Verify
How to confirm it worked, with expected output described.

## Pitfalls and rollback
What breaks, how to recover, and how the installer's `--resume` / `--restart` /
state journal relate.

## Reference
- **Step:** `NN` - `steps/NN_name.sh`
- **Uses:** the `lib/*.sh` and `variants/*/*.sh` it loads
- **Flags/settings:** the `--flags` that drive it
- **Writes:** the files/artifacts it creates on the target
```

Overview (00) and appendix (99) may relax the section structure but keep the voice,
the rules, and the Prev/Next footer.

## Nav footer

```markdown
---
[← Previous: <title>](NN-prev.md) · [Handbook index](README.md) · [Next: <title> →](NN-next.md)
```
