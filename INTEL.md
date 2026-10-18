# agterm for Intel Macs

Upstream [umputun/agterm](https://github.com/umputun/agterm) ships Apple Silicon builds only. This fork builds
the same upstream releases for Intel (`x86_64`, macOS 14 or later). This file holds the fork's rules and its
maintenance runbook; the notice at the top of [README.md](README.md) is the short version for users.

## What the fork is

- **Tag-for-tag parity.** Release `x86_64-vX.Y.Z-rN` is upstream tag `vX.Y.Z` plus the Intel stack below, and
  `legacy/intel` is upstream `master` plus the same stack. The fork adds no features and changes no behavior
  that already works on Intel. Only on the maintainer's call may a release carry upstream `master` commits that
  no upstream tag has yet: they are cherry-picked with `-x` onto the tag below the stack, the version takes the
  next patch number, and a release-only commit adds `.github/intel-upstream` naming the base tag.
- **Only what Intel needs.** A change joins the stack when agterm cannot build, run or pass its gates on
  `x86_64` without it, or when it keeps this build's identity apart from upstream's (bundle id, signing,
  release assets, the README notice). Any other fix goes upstream as a pull request from `master` and arrives
  here with the next sync.
- **Independent maintenance.** A third-party developer maintains the fork, not the agterm author, and upstream
  neither builds, signs nor supports these binaries. They are signed with the fork maintainer's Developer ID and
  notarized under that account, so their signer differs from upstream releases.
- **Upstream material as published.** Everything outside the stack comes from upstream unchanged: the user guide
  and command reference on agterm.com, `site/`, `docs/`, `cookbook/`, and the agent skill with its plugin
  marketplace under `plugins/`. These may point at upstream releases, the Homebrew cask, Apple Silicon or the
  upstream issue tracker, and the fork does not rewrite or maintain them. Where they disagree with this build,
  the README notice, its Install section and this file apply.
- **Problem reports.** A problem that occurs only in the Intel build goes to this fork's issues; everything else
  goes upstream.

## Branches

- `master` mirrors upstream `master` and is only ever fast-forwarded from it.
  Sync it from the command line (`gh repo sync <fork> -b master`) or from the `master` branch page.
  The Sync fork button on the default branch would merge upstream into `legacy/intel`.
- `legacy/intel` is the default branch: `master` plus a short linear stack of Intel commits.
  After each `master` sync it is rebased onto `master` and force-pushed with a lease.
- Pull requests for upstream start from `master` and contain nothing Intel-specific.
  Once upstream merges one, it reaches this fork through the `master` sync.
- Releases are tags `x86_64-vX.Y.Z-rN` on a release candidate built from the exact upstream tag `vX.Y.Z`.
  `N` counts respins of the same upstream version. Published tags are never moved, so `intel-v0.37.1-r1` keeps the old prefix.

## The Intel stack

| Commit | Why |
| --- | --- |
| `build(intel)` | `ARCHS: x86_64` in `project.yml` and `ZMX_TARGET=x86_64-macos.14.0` in `scripts/setup.sh`. GhosttyKit is built for the host, so the app stays on that slice. |
| `fix(intel)` plain deinit | Swift's `isolated deinit` back-deployment thunk crashes on Intel macOS 15. `SystemWakeObserver`, `SystemAccessibilityObserver`, `RemoteLinkObserver`, `RemotesWatcher`, `AppActions` and `WorkspaceSidebar.Coordinator` use a plain `deinit` with narrowly scoped `nonisolated(unsafe)` storage. |
| `fix(intel)` worker threads | x86_64 Release builds can compile a `Thread { }` literal written in main-actor code as `@MainActor`, which traps on the new thread. Every thread start goes through `makeWorkerThread` or `detachWorkerThread` (`agterm/Control/WorkerThread.swift`). Debug can be right where Release is wrong, so passing tests prove nothing: `scripts/intel-verify-closures.sh` compares the two builds. |
| `test(intel)` | Hosted test fixtures adapted to macOS 15 hosts (NSAlert buttons, WebKit, the CoreFoundation encoding cache, no `setenv` after libghostty starts, a restart-test skip when Live cannot use the login shell, restart fixtures that launch `/bin/bash` because the `/bin/sh` re-exec races argv reads here and not on arm64, ask editor heights read once SwiftUI has applied the draft, which it does a run-loop turn later here). |
| `feat(intel)` bundle id | `io.github.vshuraeff.agterm` (Debug `.debug`), so this build never claims upstream's identity. |
| `build(intel)` CI | `intel-ci.yml` runs upstream's checks for `legacy/intel` pushes/PRs and manual dispatch on `macos-15-intel`, with distinct Intel check names and longer cold-build budgets. It uploads coverage to the fork's Coveralls project. `deps` builds and caches libghostty and zmx (about 40 minutes cold), then `build`, `fixtures` and `hosted` run in parallel; `closures` compares their Release and Debug binaries. `hosted` skips three `ImageRenderer` tests that assert in Metal on the virtual GPU; local `make test-app` still runs them. Upstream's `ci.yml` remains unchanged and targets `master`; `intel-build.yml` builds release tags; `scripts/intel-release.sh` signs locally. |
| `docs(intel)` | This file, the README notice, badges, Install section and bug-report line, the issue form in `.github/ISSUE_TEMPLATE/`, and `.claude/rules/intel-fork.md` for coding agents. |
| `build(intel)` release and DMG | `scripts/intel-release.sh` runs a release to publication and resumes it from `build/<tag>/` (Release below); `intel-attest.yml` attests the DMG on the draft, the file that gets published, and writes the notes with `scripts/intel-release-notes.sh`; `scripts/intel-verify-signed-app.sh` is the signed-app check both release workflows share. `scripts/build-dmg.sh` lays out the installer window from `scripts/dmg/` with a pinned dmgbuild: its settings, and a background TIFF that `render-background.sh` draws from `background.svg`. `scripts/check-dmg.sh` checks an image's entries, background and Finder records against that layout, and its app against the app it should hold. `intel-ci.yml`'s `build` job builds and checks one from the ad-hoc app; `intel-dmg.yml` builds and attests the release DMG from the signed app. Everything but `intel-dmg.yml`, the `intel-ci.yml` step and the SVG's `intel` group is meant for an upstream pull request, with the same step in `ci.yml` and a `release.sh` call. |
| `fix:` zmx DA replies | Temporary, above the stack: patch `0004` stops zmx forwarding a DA query it already answered to an attach whose `Init` comes later. It flakes the session host fixtures here, never on upstream's arm64 CI. Dropped once `ZMX_REV` includes neurosnap/zmx#292. |

When upstream adds a type with `isolated deinit` or a new thread start, it gets the same treatment in the
matching commit. `scripts/intel-audit.sh` fails on either one; it checks source, so the closure check
under Gates still decides.

Keep the stack small: one commit per concern, edits only on lines upstream rarely touches, everything else
in files upstream does not have. Reorder or squash only to drop a commit, since either invalidates the
resolutions of earlier refreshes.

## Refresh after an upstream change

Remotes: `origin` is umputun/agterm, `fork` is this repository. `scripts/intel-refresh.sh BASE ONTO` checks
that `BASE..HEAD` is exactly the stack, rebases it onto `ONTO` with conflict resolutions recorded
(`rerere`), stops on every conflict, and pushes nothing. Its report shows the range-diff, the upstream
`ci.yml` changes to port into `intel-ci.yml`, a `ZMX_REV` move, the temporary commits and the audit.

Port the gate changes in that `ci.yml` diff even when the rebase has no conflicts. Upstream `test`,
`coverage`, `lint` and `cookbook` map to the same job ids. Its `build` steps map to `deps` (helper
builds/cache), `build` (Release, architecture/signatures/entitlements), `fixtures` (staged-zmx tests) and
`hosted` (Debug, required fish and login-shell seams); the fork's extra `closures` job compares Release/Debug
isolation.

```sh
git fetch origin && git fetch fork
OLD=$(git rev-parse fork/legacy/intel)
BASE=$(git merge-base "$OLD" origin/master)   # record both before anything moves
git switch -c refresh/$(date +%Y%m%d) "$OLD"
bash scripts/intel-refresh.sh "$BASE" origin/master
# on a conflict: resolve, git add, rebase --continue as printed, then intel-refresh.sh --report
# drop a temporary commit whose fix upstream now has; run the gates
git push fork origin/master:refs/heads/master
git push --force-with-lease=legacy/intel:"$OLD" fork HEAD:legacy/intel
```

## Gates

Run on an Intel Mac before pushing `legacy/intel` and before tagging a release:

```sh
make prep && lipo -archs agterm/Resources/zmx/zmx
(cd agtermCore && swift test)
make lint
make test-app
scripts/build.sh
bash scripts/intel-verify-arch.sh build/DerivedData/Build/Products/Release/agterm.app
bash scripts/intel-verify-closures.sh build/DerivedData/Build/Products
```

`make test-app` builds the Debug app the closure check compares against. It must report zero failures and no
`Restarting after unexpected exit` lines.

## Release

Signing and notarization happen only on the maintainer's machine; GitHub holds no credentials. From the tag
push to the published release no step needs a person, so an agent can drive a release whole.

Check the machine first:

- `git config user.name` and `user.email` in the checkout are the public identity (the GitHub noreply address;
  a private one is refused with GH007), and signing is on: every stack commit and the tag are signed.
- `security find-identity -v -p codesigning` lists a `Developer ID Application` identity, and
  `xcrun notarytool history --keychain-profile <profile>` succeeds for the profile the script will use.
- `gh` is 2.67.0 or newer, since older versions exit 0 when no attestation is found, and `uv` is installed.
- The screen stays unlocked for the whole run (Failures seen).

The candidate is the refreshed stack moved onto the tag. Its base is the `master` commit the stack sits on,
recorded before `master` moves again, never `fork/master` itself:

```sh
git fetch origin tag vX.Y.Z && git fetch fork
BASE=$(git merge-base fork/legacy/intel origin/master)
git switch -c release/intel-X.Y.Z-rN fork/legacy/intel
bash scripts/intel-refresh.sh "$BASE" vX.Y.Z
# drop temporary commits the tag already has, then the gates as above
git diff vX.Y.Z HEAD -- site docs cookbook plugins CHANGELOG.md   # must print nothing
git tag -a x86_64-vX.Y.Z-rN -m "agterm vX.Y.Z x86_64"
git push fork refs/tags/x86_64-vX.Y.Z-rN        # starts intel-build.yml, about 30 minutes
bash scripts/intel-release.sh X.Y.Z N --dry-run  # after the workflow succeeds
bash scripts/intel-release.sh X.Y.Z N --publish
```

A release that carries upstream `master` commits (What the fork is) starts from a branch at the base tag: the
commits are cherry-picked there with `-x`, oldest first, together with any commit they depend on, and that branch
is `ONTO` for `intel-refresh.sh`. `.github/intel-upstream` is committed above the stack, and the `git diff` check
then prints only the picked changes.

CI builds and verifies an unsigned app and attests its provenance. `--publish` downloads that exact artifact,
verifies the attestation, signs it inside-out with the Developer ID identity, notarizes and staples it, and puts it
on a new draft release. `intel-dmg.yml` checks the app's signature and ticket and builds the DMG; the script checks
the image with `check-dmg.sh` against its signed app, then signs, notarizes and staples it and uploads it with its
`.sha256`. `intel-attest.yml` downloads the DMG from the draft, checks its checksum, signatures, ticket, Gatekeeper
assessment and layout, attests that file and writes the release notes. The script verifies the attestation, removes
the app zip, publishes the release as the latest, then checks the published DMG's checksum, attestation and ticket.
Without `--publish` it stops once the app is notarized. Workflow runs are found by tag, commit and dispatch time,
so drive one release per tag at a time.

Notarization can outlast the script's wait (`AGTERM_NOTARY_WAIT`, default `30m`), and each workflow run gets
30 minutes. The script then exits 75 and names what is pending; rerunning the same command resumes from the
records in `build/x86_64-vX.Y.Z-rN/`. It never submits an artifact twice or replaces a signed DMG, an artifact
Apple already holds a ticket for is stapled without a submission, and a workflow run that failed is dispatched
again. A rerun refuses a release someone else published before it uploads anything; after its own publication
it repeats only the final checks. Once they pass the DMG and its `.sha256` move to `build/` and that directory is
removed. To release an older tag with a newer script, run the newer one with `AGTERM_RELEASE_ROOT` set to the
tag's clean checkout; `--publish` needs a tag that carries all three release workflows.
`intel-build.yml` can be rerun with `gh workflow run intel-build.yml --ref x86_64-vX.Y.Z-rN -f tag=x86_64-vX.Y.Z-rN`.

The signing identity comes from `AGTERM_SIGN_IDENTITY` or the keychain's first `Developer ID Application`
identity, and notary credentials from the notarytool keychain profile named by `AGTERM_NOTARY_PROFILE` (default
`agterm-notary`, as upstream's `scripts/release.sh`). The script refuses to publish an unsigned build. There is no
Homebrew cask for this fork.

### Release notes

`scripts/intel-release-notes.sh` writes them from the base tag's `CHANGELOG.md` section, as upstream's `release.sh`
does, so they keep upstream's New Features, Improved and Bug Fixes groups. Cherry-picked commits come first, under
"From upstream master", one entry per upstream pull request: `feat` under New Features, `fix` under Bug Fixes,
`docs` and untyped subjects under Improved; `refactor`, `test`, `ci`, `chore` and `docs(backlog)` are left out, as
upstream leaves them out. Issue and pull request numbers and short hashes link to upstream, and authors become
plain links, so the notes notify nobody. A generated entry is its commit subject: correct one on the published
release with `gh release edit --notes-file`.

### Failures seen

- notarytool exits 69 with `No Keychain password item found for profile` while the screen is locked: the login
  keychain locks with it. The profile is still there; unlock and rerun.
- The default profile name is upstream's; a profile saved under another name needs `AGTERM_NOTARY_PROFILE`.
- A stray `user.name`/`user.email` in the checkout's `.git/config` overrides the global identity. Check it before
  committing, since a rewritten history is the only fix once such commits are pushed.
- `check-dmg.sh` fails with `Resource busy` when the image is already attached; detach it first.
- A pipeline under `pipefail` whose reader stops early fails with SIGPIPE: read to the end instead.

`intel-build.yml` restores the libghostty and zmx caches that `intel-ci.yml` saves on `legacy/intel` pushes.
Keep `legacy/intel` as the fork's default branch: GitHub lets tag runs restore the default branch's caches;
PR merge-ref caches cannot seed releases ([cache scope](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache)).
Both workflows must keep identical key formulas and paths: the key covers runner OS/version/architecture,
Xcode, Zig, dependency pins, `scripts/setup.sh` and zmx patches. A miss builds from source.

One-time repository settings: enable Actions on the fork, make `legacy/intel` the default branch, and restrict
creation of `x86_64-v*` and `intel-v*` tags to the maintainer with a tag ruleset,
since a tag push is what starts a release build.

## Installing over another build

The bundle id differs from any build made from upstream sources, so macOS treats this as a different app.

1. Save your work and finish running jobs, quit the old build, restart the Mac, then launch this one.
   Running jobs and Live sessions do not survive that restart. Without it, a session host left by the old
   build refuses the new one, and new sessions start without it.
2. Expect to grant the permissions you use again (Accessibility, Automation, microphone, screen recording)
   and check each of them; enable agterm in Notifications and send a test notification.
3. Window positions reset. Settings, sessions and config stay in `~/Library/Application Support/agterm` and
   `~/.config/agterm`, which do not depend on the bundle id. Two installed builds therefore share that data:
   run only one of them.
4. Agent hooks and the `agtermctl` link keep working while the app stays at the same path.
