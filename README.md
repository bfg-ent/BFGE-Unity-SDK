# Apollo SDK — Unity Package

This repository is the **UPM distribution package** for the Apollo SDK: prebuilt `Bfg.Apollo`
assemblies (iOS, Android, and Standalone/Editor) plus the SDK's bundled native iOS plugins and
Android dependency manifest. It is built from the Apollo SDK source repository
([`bfg-ent/Apollo_Rebuild`](https://github.com/bfg-ent/Apollo_Rebuild)) — no SDK source code lives
here, and changes should never be made directly to the DLLs in this repo.

- **Package name:** `bfg.apollo`
- **Minimum Unity version:** 2021.2
- **Platforms:** iOS & Android (Standalone/Editor DLL included for in-Editor development)
- **Minimum iOS version:** 15.0
- **Minimum Android version:** API level 25 (Android 7.1)

---

## Requirements

- **Git** must be installed and on your `PATH` — Unity's Package Manager invokes it to fetch git
  packages. Verify with `git --version` in a terminal.
- **Access to this repository.** It is private to the `bfg-ent` organization, so the machine
  adding the package must be able to clone it:
  - **HTTPS** — sign in with a Git credential manager, or use a GitHub personal access token with
    `repo` read scope.
  - **SSH** — an SSH key registered with your GitHub account. Use the SSH URL form shown below.

  Quick check: if `git clone https://github.com/bfg-ent/Apollo-Package.git` works in a terminal,
  Unity can fetch the package the same way.

---

## Install the latest release

Releases are git tags in this repository (e.g. `v0.0.2`). Find the newest one on the
[Releases page](https://github.com/bfg-ent/Apollo-Package/releases) — the newest production
release is marked **Latest**; releases with a **Pre-release** badge are betas (see
[Beta releases](#beta--pre-release-versions) below).

> **Always pin a tag.** Unity's Package Manager has no "auto-latest" for git packages — a URL
> without a `#tag` suffix tracks the default branch's current HEAD, which changes as development
> lands and makes builds unreproducible. Never ship a build from an untagged reference.

**Option A — Package Manager window:**

1. **Window → Package Manager**
2. **+** (top-left) → **Add package from git URL…**
3. Enter the URL with the newest release tag, e.g.:

```
https://github.com/bfg-ent/Apollo-Package.git#v0.0.2
```

**Option B — edit `Packages/manifest.json` directly:**

```json
{
  "dependencies": {
    "bfg.apollo": "https://github.com/bfg-ent/Apollo-Package.git#v0.0.2"
  }
}
```

Unity resolves and imports the package on the next focus/refresh. The package appears in the
Package Manager under **Apollo**.

---

## Install a specific version

Append the release tag to the URL after `#`. Any tag from the Releases page works:

```json
"bfg.apollo": "https://github.com/bfg-ent/Apollo-Package.git#v0.0.2"
```

**SSH URL form** (for machines authenticating with an SSH key):

```json
"bfg.apollo": "git@github.com:bfg-ent/Apollo-Package.git#v0.0.2"
```

### Beta / pre-release versions

Beta builds carry a semver **pre-release suffix** in both the tag and the package version, e.g.
`v0.0.3-beta.1`, and are marked **Pre-release** on the GitHub Releases page. They are not
production builds — install one only when you are explicitly validating a beta:

```json
"bfg.apollo": "https://github.com/bfg-ent/Apollo-Package.git#v0.0.3-beta.1"
```

---

## Updating or switching versions

1. Change the tag in `Packages/manifest.json` to the new release (e.g. `#v0.0.2` → `#v0.0.3`).
2. Return to Unity — the Package Manager re-resolves automatically.

If Unity keeps the old version: `Packages/packages-lock.json` pins the exact commit that was
resolved for the current tag. Changing the tag in `manifest.json` normally updates the lock, but
if the package appears stuck, delete the `"bfg.apollo"` entry from `packages-lock.json` (or use
the **Update** button on the package in the Package Manager window) and let Unity re-resolve.

Downgrading works the same way — set the tag to any older release.

---

## Local development (working against a checkout)

To develop against a local clone of this repository instead of a tagged release — e.g. while
testing unreleased SDK changes — use a `file:` reference with a path relative to your project's
`Packages/` folder:

```json
"bfg.apollo": "file:../../Apollo-Package"
```

Unity reads the package directly from that folder; local changes (rebuilt DLLs) are picked up on
refresh. Never ship a build with a `file:` reference — switch back to a release tag first.

---

## After installing

- **Integration:** follow `APOLLO_SDK_INTEGRATION_GUIDE.md` (bundled in this package) for the
  required configuration files (`BfgSettings.asset`, `ApolloNetworkConfig.json`, …), adapter and
  listener implementations, and feature-by-feature setup. GDPR/ATT consent integration is covered
  by `APOLLO_CONSENT_INTEGRATION_GUIDE.md` in the source repository.
- **Version history:** see `CHANGELOG.md` and the
  [GitHub Releases page](https://github.com/bfg-ent/Apollo-Package/releases).
- **API reference:** lives in the source repository
  ([`bfg-ent/Apollo_Rebuild`](https://github.com/bfg-ent/Apollo_Rebuild) — `README.md` and
  `APOLLO_SDK_API_REFERENCE.md`).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No 'git' executable was found` when adding the package | Install git and restart Unity (and Unity Hub) so the updated `PATH` is picked up. |
| `Cannot resolve` / authentication error fetching the URL | The machine can't clone this private repo — set up a credential manager/PAT for HTTPS or an SSH key, and confirm `git clone` of this repo works in a terminal. |
| Tag change in `manifest.json` doesn't update the package | Remove the `"bfg.apollo"` entry from `Packages/packages-lock.json` and let Unity re-resolve, or use the Package Manager **Update** button. |
| Duplicate-symbol linker errors in the iOS build | The game project has hand-copied copies of Apollo's native iOS files under `Assets/Plugins/iOS/` from before the package bundled them (including the ATT prompt bridge) — delete the local copies; the package ships all required native sources. |
| Package shows as `file:` / changes not versioned | A local-development reference was left in `manifest.json` — switch back to a release-tag URL before building. |
