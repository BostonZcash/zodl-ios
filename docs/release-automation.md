# Release automation (local fastlane)

Build, sign, and submit any ZODL iOS variant from your Mac with one command. It
signs with the same Xcode identity you already use to Archive by hand, so **no
signing keys are stored in the repo or anywhere new**. A fail-closed *preflight*
reconciles what you ask for against git, the project, and App Store Connect, and
refuses to build on any mismatch.

For the design rationale and the full check list see the
[spec](superpowers/specs/2026-06-25-local-fastlane-release-automation-design.md).
`fastlane/README.md` is the one-screen quick reference.

## How it fits together

| Piece | Role |
|---|---|
| `Scripts/release.sh`, `Scripts/bump.sh` | GNU-style CLI wrappers you run |
| `fastlane/Fastfile` | the `release` and `bump` lanes |
| `fastlane/lib/zodl/` | pure preflight logic (unit-tested) |
| `git worktree` (temp) | each build runs against a clean checkout of the exact ref |

You call the wrappers; they forward to fastlane; fastlane gathers facts, runs the
preflight, then builds in a throwaway worktree and uploads to App Store Connect.

## First-time setup (once per machine)

1. **Ruby** — pinned by `.ruby-version` (3.3.7). With rbenv: `rbenv install 3.3.7`.
2. **Gems** — `bundle install`.
3. **App Store Connect API key** — in App Store Connect → *Users and Access →
   Integrations → App Store Connect API*, create a key and download the `.p8`.
   Then `cp fastlane/.env.example fastlane/.env` and fill in `ASC_KEY_ID`,
   `ASC_ISSUER_ID`, and `ASC_KEY_FILEPATH` (absolute path to the `.p8`).
   `fastlane/.env` and `*.p8` are gitignored — they never get committed.
4. **Partner keys** — put `PartnerKeys.plist` at `secant/Resources/PartnerKeys.plist`
   (gitignored; required to build).
5. **Xcode** — your selected Xcode must match `.xcode-version`.
6. **Signing** — you must already be able to Archive and upload the app from Xcode
   by hand (Apple Distribution certificate, automatic signing, team `RLPRR8CPQG`).
   The tooling reuses that identity; it does not manage certificates.
7. **(optional)** `brew install bats-core` to run the wrapper tests.

## The variants

Each variant is a **separate App Store Connect app**, so build numbers are
independent — a build number only has to beat that variant's own history.

| `--variant` | Scheme | App Store Connect app | Goes to |
|---|---|---|---|
| `internal` | `zodl-internal` | `co.electriccoin.secant-testnet` | TestFlight |
| `testnet` | `zodl-testnet` | `co.ecc.zashi-testnet` | TestFlight |
| `appstore` | `zodl-AppStore` | `co.electriccoin.secant-mainnet` | App Store |
| `internal-testnet` | — | both of the above | builds `internal` then `testnet`, running tests once |

## Everyday use — the release flow

**1. Start a new version (in `main`).** Set and commit the marketing version, push,
then cut the release branch:

```bash
./Scripts/bump.sh --version 3.8.0 --build 1     # edits the project + commits
git push                                         # push the bump commit on main
git checkout -b release/3.8.0
git push -u origin release/3.8.0
```

**2. Build the TestFlight pair** from the release branch:

```bash
./Scripts/release.sh --variant internal-testnet --ref release/3.8.0 --version 3.8.0 --build 1
```

**3. Need a fix?** Commit and push it on `release/3.8.0`, then rebuild with the next
build number:

```bash
./Scripts/release.sh --variant internal-testnet --ref release/3.8.0 --version 3.8.0 --build 2
```

**4. Ship to the App Store** when you're happy:

```bash
./Scripts/release.sh --variant appstore --ref release/3.8.0 --version 3.8.0 --build 1
```

`appstore` is its own App Store Connect app, so its build numbers are a separate
sequence — start from wherever that app left off. (The build then waits for App
Store Connect processing; submitting it for review is still done in App Store
Connect.)

**Off the regular path:** build any variant from any branch, tag, or commit at any
time by pointing `--ref` at it.

## Always check first with `--dry-run`

Add `--dry-run` to run every preflight check and print the reconciliation summary
**without building** — the cheap way to confirm your intent is correct:

```bash
./Scripts/release.sh --variant appstore --ref release/3.8.0 --version 3.8.0 --build 1 --dry-run
```

The preflight blocks the build if: the version doesn't match the project's
`MARKETING_VERSION` or the `release/X.Y.Z` branch; the build number duplicates or
is lower than the variant's latest on App Store Connect; the ref isn't pushed to
`origin`; `PartnerKeys.plist` is missing/invalid; Xcode doesn't match
`.xcode-version`; or no distribution signing identity is present. It *warns* (but
proceeds) on a build-number gap or an uncommitted working tree.

## Command reference

```
Scripts/release.sh --variant <v> --ref <ref> --version <X.Y.Z> --build <n> [options]
  --variant     internal | testnet | appstore | internal-testnet
  --ref         branch, tag, or commit to build
  --version     marketing version you intend to ship (X.Y.Z)
  --build       build number (integer)
  --dry-run     run checks, then stop before building
  --yes         skip the confirmation prompt
  --skip-tests  skip the unit-test step
  -h, --help

Scripts/bump.sh --version <X.Y.Z> --build <n>
```

## Troubleshooting (preflight messages)

| Message | Fix |
|---|---|
| `version … does not match project MARKETING_VERSION …` | Run `bump` first, or pass the version the project is actually at. |
| `build N already exists` / `is lower than the latest build` | Pick a higher number — check that variant's app in App Store Connect / TestFlight. |
| `ref is not on origin` | `git push` the branch or commit first. |
| `PartnerKeys.plist is missing or invalid` | Place a valid plist at `secant/Resources/PartnerKeys.plist` (see `Scripts/validate-partner-keys.sh`). |
| `Xcode version does not match .xcode-version` | Switch Xcode (e.g. `xcodes select`) to the pinned version, or update `.xcode-version`. |
| `no distribution signing identity` | Ensure your Apple Distribution certificate is in the keychain — the same setup that lets you Archive manually. |
| TestFlight build stuck on *Missing Compliance* | Set `ITSAppUsesNonExemptEncryption` so the build clears export compliance automatically. |

## Running the tooling's own tests

```bash
bundle exec rake test                 # Ruby preflight logic (minitest)
bats Scripts/test/release_args.bats   # wrapper arg parsing
```
