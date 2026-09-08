# Publishing `piesocket-swift`

The Swift SDK is distributed as a **SwiftPM package** (`Channels`) straight
from the GitHub repo — https://github.com/piesocket/piesocket-swift. There is
no registry upload: **SwiftPM resolves versions from annotated git tags**, so
"publishing" a release *is* pushing a `vX.Y.Z` tag.

Current release: **7.0.0**. The version was realigned from the old `2.x` line
to match the other PieSocket client SDKs (piesocket-js, piesocket-flutter,
piesocket-android); `7.0.0` is the release that follows `2.1.0` — see
`CHANGELOG.md`.

There is no version string inside `Package.swift` to bump — the tag is the
only source of truth.

## 1. Sync with the remote first

The local checkout is often behind `origin/main`. Before releasing:

```sh
cd sdks/piesocket-swift
git fetch origin
git rebase origin/main     # or merge; resolve README.md conflicts if any
```

## 2. Pre-flight

- [ ] `CHANGELOG.md` has a `## 7.0.0` top entry.
- [ ] `README.md` reflects the new API (v4, PieRTC, `sendBinary`, screen
      share). The install instructions don't pin a version, so nothing to
      bump there.
- [ ] `Package.swift` platform floor (`.iOS(.v13)`, `.macOS(.v11)`) and the
      `stasel/WebRTC` / `Starscream` version ranges are what you intend to
      ship.
- [ ] `Package.resolved` is committed and current.
- [ ] Working tree clean apart from the release commit.

## 3. Verify locally

SwiftPM here needs these env vars (its bare-repo cache vs git's
`safe.bareRepository=explicit`):

```sh
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.bareRepository
export GIT_CONFIG_VALUE_0=all

swift build
swift test        # ConnectionTests + ChannelsTests, ~15 tests
```

Also open the package in Xcode and build the `Channels` scheme for an iOS
destination once — the `WebRTC` XCFramework only links for Apple SDKs, not
plain `swift build` on some setups.

## 4. Tag and push

```sh
git add CHANGELOG.md README.md Package.swift Package.resolved Sources Tests
git commit -m "v7.0.0 - v4 protocol + PieRTC (WebRTC rooms), binary send, screen share"
git tag -a v7.0.0 -m "v7.0.0"
git push origin main
git push origin v7.0.0
```

Use an **annotated** tag (`-a`). SwiftPM treats `7.0.0` and `v7.0.0` as the
same version; this repo's history uses the `vX.Y.Z` form — keep it.

Then, in the parent `piesocket-server` repo, commit the bumped submodule
pointer.

## 5. GitHub release (optional but recommended)

Create a GitHub Release from the `v7.0.0` tag and paste the `CHANGELOG.md`
section as the notes. The Swift Package Index picks up new tags automatically
within a few minutes.

## 6. Post-publish: cut the demo over to the tagged package

`demos/swift-demo` uses a local path dependency via `project.yml`. Once
`v7.0.0` is tagged:

1. In `demos/swift-demo/project.yml`, replace the `Channels:` package's
   `path: ../../sdks/piesocket-swift` with:
   ```yaml
   Channels:
     url: https://github.com/piesocket/piesocket-swift
     from: "7.0.0"
   ```
2. `xcodegen generate`, resolve packages, build for an iOS simulator, then
   commit.

## 7. Cutting a later release

1. Add a `CHANGELOG.md` section; update `README.md` if the API changed.
2. Run sections 1 → 4 with the new `vX.Y.Z` tag.

Semver: additive API → minor, fix-only → patch, breaking change (incl.
raising the platform floor) → major.
