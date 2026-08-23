# Public Source Release Runbook

This runbook publishes a stable source snapshot from the private development repository to the public source repository. Enve is source-available under the Enve Noncommercial Public Source License, not OSI open source.

## Repository roles

| Role | Repository | Branch |
| --- | --- | --- |
| Development source and private history | `opisaac9001/Enve-Book-Player-iOS` | `main` |
| Sanitized public snapshots | `opisaac9001/Enve-Book-Player` | `main` |

Use separate checkouts. Never add the private repository as a remote of the public checkout, merge or cherry-pick private commits into it, or copy `.git`. A release transfers reviewed files, not history.

Keep the destination private while preparing a snapshot. Making it public requires a separate, explicit maintainer instruction.

## 1. Verify both checkouts

Run from each repository root:

```sh
pwd
git remote get-url origin
git branch --show-current
git status --short
git fetch --prune origin
git status --short --branch
```

Both working trees must be clean, on `main`, and current with these remotes:

```text
https://github.com/opisaac9001/Enve-Book-Player-iOS.git
https://github.com/opisaac9001/Enve-Book-Player.git
```

Confirm the destination is private:

```sh
gh repo view opisaac9001/Enve-Book-Player \
  --json nameWithOwner,visibility,url
```

Stop on a dirty tree, unexpected remote, wrong branch, diverged branch, or public destination.

## 2. Find the source boundary

After each successful publication, the private source commit is tagged:

```text
public-source-YYYY-MM-DD
public-source-YYYY-MM-DD.N
```

Find the latest boundary and inspect the path-level delta:

```sh
git tag --list 'public-source-*' --sort=-creatordate
git diff --name-status <previous-tag>..HEAD
git diff --stat <previous-tag>..HEAD
```

If no trustworthy tag exists, perform a full tracked-tree comparison. Do not guess from dates or commit messages.

Compare changed paths with the protected list in `AGENTS.md` before reading their contents. An agent may inspect or transfer an `// AGENT-LOCKED` file only after completing the lock protocol for the current task. Earlier authorization does not carry forward.

## 3. Export tracked files only

Create a temporary export outside both repositories:

```sh
SOURCE_REPO="/path/to/Enve-Book-Player-iOS"
EXPORT_DIR="$(mktemp -d)"

git -C "$SOURCE_REPO" archive --format=tar HEAD |
  tar -xf - -C "$EXPORT_DIR"
```

This excludes `.git`, ignored files, and untracked working-copy data. Do not substitute a Finder copy.

The export must not contain:

- `.agent-lock`, `.build`, DerivedData, `xcuserdata`, or editor state
- populated `enve/Configuration/DeveloperSettings.plist`
- credentials, private keys, provisioning profiles, or signing certificates
- downloaded media, library databases, diagnostic exports, or private screenshots
- local environment files or developer-specific absolute paths

An unexpectedly tracked private file blocks the release. Remove it from source control and rotate any exposed credential before continuing.

## 4. Preserve the public surface

Do not blanket-overwrite files owned by the public repository:

- `README.md`
- `LICENSE.md`, `NOTICE.md`, and `THIRD_PARTY_NOTICES.md`
- `CONTRIBUTING.md` and `SECURITY.md`
- `CODE_OF_CONDUCT.md`, `SUPPORT.md`, and `RELEASES.md`
- `.github/`
- public screenshots and branding under `assets/`

Merge changes to these files manually. `CLAUDE.md`, `AGENTS.md`, `ARCHITECTURE.md`, and `DEVELOPMENT.md` should follow current architecture while retaining public contribution, build, and security guidance.

Application source, tests, Xcode project files, maintained local packages, build support, and technical documentation normally follow the reviewed private snapshot.

## 5. Review before copying

Use a checksum dry run to reveal the full proposed transfer:

```sh
PUBLIC_REPO="/path/to/Enve-Book-Player"

rsync -rinc --delete \
  --exclude='.git/' \
  --exclude='.swiftpm/' \
  --exclude='README.md' \
  --exclude='LICENSE.md' \
  --exclude='NOTICE.md' \
  --exclude='THIRD_PARTY_NOTICES.md' \
  --exclude='CONTRIBUTING.md' \
  --exclude='SECURITY.md' \
  --exclude='CODE_OF_CONDUCT.md' \
  --exclude='SUPPORT.md' \
  --exclude='RELEASES.md' \
  --exclude='.github/' \
  --exclude='assets/' \
  --exclude='ThirdParty/foliate-js/' \
  "$EXPORT_DIR/" "$PUBLIC_REPO/"
```

Classify every addition, modification, and deletion. Unexplained changes block the release. The dry run is not permission to run a root-level `rsync --delete`; transfer reviewed incremental paths and deletions explicitly.

`git archive` records a submodule entry but not its working tree. Compare the Foliate gitlink separately:

```sh
git -C "$SOURCE_REPO" ls-tree HEAD ThirdParty/foliate-js
git -C "$PUBLIC_REPO" ls-tree HEAD ThirdParty/foliate-js
```

If the revisions differ, fetch and check out the exact source revision inside the public submodule, then stage the parent repository's gitlink. Never copy the submodule's `.git` data.

After copying, review the destination rather than the source commit:

```sh
git status --short
git diff --stat
git diff --check
git diff --submodule=log
```

Read the complete public diff.

## 6. Sanitize the destination

Check tracked and staged content for:

- credentials, authorization headers, tokens, private keys, and real account identifiers
- private server addresses, LAN IPs, signed URLs, and user library data
- `/Users/`, `/Volumes/`, stale workspace paths, and machine-specific settings
- generated reports, temporary patches, backup files, task notes, and editor state
- merge markers, debug logging, placeholders, and unexplained fixtures
- media or artwork without redistribution rights

When a match might contain a secret, report only its filename and redact the value. Rotate real credentials even when they are removed before commit.

Run these repository checks:

```sh
git ls-files -ci --exclude-standard
git diff --check
./scripts/verify-provenance
```

Also confirm:

- submodule URLs and revisions are public and reproducible
- comments explain constraints rather than narrating code
- task transcripts, one-off walkthroughs, and temporary policy documents are absent
- new code follows `ARCHITECTURE.md`
- license and notice files remain intact

`CLAUDE.md` and `AGENTS.md` are intentional. They make the project ready for contributors using coding agents and are not sanitization targets.

Read `docs/legal/THIRD_PARTY_AUDIT.md` when dependencies, vendored source, models, fonts, provider artwork, or binary distribution terms change.

## 7. Verify the public checkout

Build and test an Apple-silicon simulator from the destination:

```sh
xcodebuild -project enve.xcodeproj \
  -scheme enve \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -derivedDataPath .build/DerivedData \
  build

xcodebuild -project enve.xcodeproj \
  -scheme enve \
  -testPlan AllTests \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -derivedDataPath .build/DerivedData \
  test
```

Build other affected targets separately. Install and exercise user-visible changes. Apply the provider, reader, playback, sync, Watch, widget, and tvOS checks in `CLAUDE.md` as relevant.

Do not publish with build errors, failed tests, new application warnings, or an unexplained verification gap.

## 8. Commit without private history

Stage only reviewed paths. Do not use `git add -A`, `git add .`, or `git add --all` in an unreviewed worktree.

Routine snapshots are normal public commits whose parent is the current public `main`. Do not create an orphan commit, reset published history, or force-push unless the maintainer explicitly requests a one-time history replacement.

If the maintainer explicitly approves a release branch:

```sh
git switch -c public-release/<version>
git push -u origin public-release/<version>
gh pr create \
  --repo opisaac9001/Enve-Book-Player \
  --base main \
  --head public-release/<version> \
  --draft
```

Otherwise remain on `main` and push only after explicit approval of the reviewed commit.

## 9. Verify GitHub

Confirm the remote head and watch CI:

```sh
git rev-parse HEAD
git ls-remote origin refs/heads/main

gh run list \
  --repo opisaac9001/Enve-Book-Player \
  --workflow ios-ci.yml \
  --limit 5

gh run watch <run-id> \
  --repo opisaac9001/Enve-Book-Player \
  --exit-status
```

`Build and test` must pass. Confirm branch protection still requires review, code-owner approval, linear history, conversation resolution, and CI, with force pushes and deletions disabled.

## 10. Record the successful boundary

Only after public CI succeeds, tag the exact private source commit:

```sh
git tag -a public-source-YYYY-MM-DD \
  -m 'Published at public commit <public-commit>' \
  <private-source-commit>

git push origin public-source-YYYY-MM-DD
```

Tags are immutable. Use a numbered tag for a correction. Record the private tag, public commit, CI URL, app version, verification, and any intentionally withheld paths in the maintainer release notes.

## 11. Publish visibility separately

After explicit maintainer approval:

```sh
gh repo edit opisaac9001/Enve-Book-Player \
  --visibility public \
  --accept-visibility-change-consequences

gh repo view opisaac9001/Enve-Book-Player \
  --json nameWithOwner,visibility,url
```

A request to prepare, sanitize, test, commit, or push is not permission to make the repository public.

## Incident handling

For an ordinary bad release, keep or make the repository private and revert with a new commit. Preserve history.

For leaked sensitive data, revoke or rotate it first, make the repository private, identify affected commits, tags, workflow artifacts, forks, and caches, then follow GitHub's sensitive-data removal process. Rewriting a commit does not revoke a secret or remove it from existing clones.

## Final checklist

- [ ] Repository identities, remotes, branches, and clean states verified
- [ ] Destination confirmed private
- [ ] Previous private source boundary identified without guessing
- [ ] Protected changed files authorized for this task
- [ ] Export contains tracked files only
- [ ] Public-owned files preserved or manually merged
- [ ] Entire public diff reviewed and sanitized
- [ ] License, notices, provenance, and third-party obligations checked
- [ ] Public checkout builds and `AllTests` passes
- [ ] Affected runtime workflows and secondary targets verified
- [ ] Public commit contains no private Git history
- [ ] GitHub CI passes and branch protection is intact
- [ ] Private source boundary tagged and recorded
- [ ] Visibility changed only after explicit approval
