# AGENTS.md — Emunix

Instructions for any agent working on this repository. Read before editing.

## Project

Emunix is an immutable, Arch-based Linux distribution for x86_64 handhelds (then desktops),
booting into EmulationStation-DE. See `INSTALL.md` for user-facing docs. Project docs, roadmap,
decisions and milestones live in the Obsidian wiki under `projects/Emunix/` — NOT in this repo.

## Scope of this repo

- Build scripts (`build/`), package lists (`profiles/`), configs (`configs/`), CI (`.github/`).
- Only install/build-facing documentation belongs here (`README.md`, `INSTALL.md`).
- No internal project docs, roadmaps, or decision logs in this repo.

## Rules

1. **Smallest change that fully solves the task.** Reuse existing code/configs first. No
   abstraction, option, wrapper or "for later" code. Deletion beats addition.
2. **Security is never cut.** No secrets in code, URLs, logs, fixtures or commits. Validate at
   trust boundaries. Never disable TLS/signature/cert verification. Never swallow auth failures.
3. **Test what you change.** New non-trivial logic leaves one test that fails without it.
   Trivial changes need none. Quote real command output as proof.
4. **No copyrighted assets or license-incompatible software.** See the asset policy in the wiki
   (`projects/Emunix/Emunix — Decisions.md`). ROMs, BIOS, firmware blobs and proprietary
   redistributable-forbidden blobs must never be committed.
5. **Profiles are split per target.** `profiles/base.txt` (all targets) + `profiles/handheld-common.txt`
   + `profiles/handhelds/<device>.txt`. AUR-only packages must be commented `# AUR`.
6. **CI must stay green.** Every push runs `build-image`; do not merge if it fails.
7. **One-way doors require BP's approval:** force-push/rewrite history, destructive migrations,
   publishing/signing releases, adding third-party deps or hosted services, weakening security,
   committing credentials, editing this file or `docs/decisions/`.

## Conventions

- Default user: `retrogamer`. ROMs/bios/saves/states under `/storage`.
- Kernel: mainline (`linux`), Zen optional later.
- Immutable model: A/B rootfs slots, persistent `/var` + `/home` + `/storage`.
- Package lists: strip inline comments in build scripts; official repos only in base lists.
- Commit messages: imperative, concise.

## Where things live

- Wiki (internal): `projects/Emunix/` in the Obsidian vault.
- Repo (public): this repository.
- Secrets: BP provisions via `.env` on host; never commit values.
