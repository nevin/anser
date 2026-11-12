# Releasing Anser

Releases are built by `scripts/release.sh`. It signs Sparkle's parts and the app with the hardened runtime, notarizes the app, builds a DMG, then signs, notarizes and staples the DMG. When updates are set up, it also writes the update feed.

## One-time setup

1. **Developer ID certificate.** In Xcode → Settings → Accounts, create a "Developer ID Application" certificate. Check that it's there:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Notary credentials.** Make an app-specific password at account.apple.com (Sign-In and Security → App-Specific Passwords), then store it once in your Keychain. You type the password yourself; it is never put in a file:

   ```sh
   xcrun notarytool store-credentials anser --apple-id you@example.com --team-id 3HLDG7WVBY
   ```

3. **Automatic updates.** Run once:

   ```sh
   bash scripts/setup-updates.sh
   ```

   - **Feed address.** By default the feed is `appcast.xml` attached to the newest GitHub release: `https://github.com/nevin/anser/releases/latest/download/appcast.xml`. Publishing a release is then all it takes to ship an update. To host the feed elsewhere, pass an https address instead.
   - **Signing key.** It creates your update signing key in your login Keychain, or reuses the one already there. Every update must be signed with it.
   - **Config file.** It writes `scripts/updates.conf` with the feed address and the public key. `build-app.sh` puts both into every build after that.

   **Back up the Keychain item "Private key for signing Sparkle updates"**, for example with `build/sparkle-tools/bin/generate_keys -x key.txt` stored somewhere safe. If you lose it, people can't update automatically and will have to download a new version by hand.

   Copies of Anser built before this step can't update themselves. People with those copies need to download the next release by hand once; after that, updates arrive automatically.

## Each release

1. Build, sign and notarize. `release.sh` gives every release a new version first:

   - **Patch by default** (0.2.0 → 0.2.1).
   - **Bigger steps:** add `minor` (→ 0.3.0) or `major` (→ 1.0.0) at the end, or give an exact version like `0.4.2`.
   - **The build number always goes up by one.** Sparkle compares it to decide what's newer.

   ```sh
   SIGN_IDENTITY="Developer ID Application: nevin paul (3HLDG7WVBY)" NOTARY_PROFILE=anser bash scripts/release.sh
   ```

   **If a release fails partway** (say, notarization is rejected), the version has already moved on. The next run bumps it again, so one number is skipped. That's harmless. `scripts/bump-version.sh` does just the version step on its own.

   **If only the last step fails** (the feed or the GitHub release), the DMG is already built. Fix the cause and finish without building again:

   ```sh
   NOTES=docs/release-notes/6.2.2.md PUBLISH=1 bash scripts/publish-update.sh 6.2.2
   ```

2. Publish. With the default GitHub feed, add `PUBLISH=1` and `release.sh` creates the GitHub release itself, with the DMG and `appcast.xml` attached. `NOTES=` gives the release notes, which appear in the update window and on GitHub:

   ```sh
   SIGN_IDENTITY="Developer ID Application: nevin paul (3HLDG7WVBY)" NOTARY_PROFILE=anser \
     NOTES=docs/release-notes/VERSION.md PUBLISH=1 bash scripts/release.sh
   ```

   - **Without `PUBLISH=1`,** it prints the `gh release create` command to run after you've checked the build.
   - **With a feed on another host,** upload everything in `build/updates/` to that address.

   Once the release is the latest one, copies of Anser with updates turned on find it within a day, or right away with Help → Check for Updates. The release must include `appcast.xml`: a release without it hides every update until the next release that has one.

## Checking a build

```sh
spctl --assess --type execute --verbose=2 build/Anser.app      # "accepted, source=Notarized Developer ID"
xcrun stapler validate build/Anser-*.dmg
codesign --verify --strict --deep --verbose=2 build/Anser.app
```

If notarization fails, `release.sh` prints Apple's log, which names the file that was rejected.
