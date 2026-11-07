# Releasing Anser

Releases are built by `scripts/release.sh`. It signs Sparkle's parts and the app with the hardened runtime, notarizes the app, builds a DMG, then signs, notarizes and staples the DMG. When updates are set up, it also writes the update feed.

## One-time setup

1. **Developer ID certificate.** In Xcode → Settings → Accounts, create a "Developer ID Application" certificate. Check that it's there:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Notary credentials.** Make an app-specific password at account.apple.com (Sign-In and Security → App-Specific Passwords), then store it once in your Keychain. You type the password yourself; it is never put in a file:

   ```sh
   xcrun notarytool store-credentials anser-notary --apple-id you@example.com --team-id 3HLDG7WVBY
   ```

3. **Automatic updates.** Pick an https address where you'll host the update feed. Any static host works, for example GitHub Pages or S3. Then run:

   ```sh
   bash scripts/setup-updates.sh https://example.com/anser/appcast.xml
   ```

   This downloads Sparkle's tools into `build/sparkle-tools`. It also creates your update signing key in your login Keychain, and writes `scripts/updates.conf` with the address and the public key, which `build-app.sh` puts into the app.

   **Back up the Keychain item "Private key for signing Sparkle updates".** If you lose it, people can't update automatically and will have to download a new version by hand.

## Each release

1. Build, sign and notarize. `release.sh` gives every release a new version first:

   - **Patch by default** (0.2.0 → 0.2.1).
   - **Bigger steps:** add `minor` (→ 0.3.0) or `major` (→ 1.0.0) at the end, or give an exact version like `0.4.2`.
   - **The build number always goes up by one.** Sparkle compares it to decide what's newer.

   ```sh
   SIGN_IDENTITY="Developer ID Application: nevin paul (3HLDG7WVBY)" NOTARY_PROFILE=anser-notary bash scripts/release.sh
   ```

   **If a release fails partway** (say, notarization is rejected), the version has already moved on. The next run bumps it again, so one number is skipped. That's harmless. `scripts/bump-version.sh` does just the version step on its own.

2. Upload everything in `build/updates/` (the DMG and `appcast.xml`) to the feed address. Copies of Anser with updates turned on find the new version within a day, or right away with Check for Updates.

## Checking a build

```sh
spctl --assess --type execute --verbose=2 build/Anser.app      # "accepted, source=Notarized Developer ID"
xcrun stapler validate build/Anser-*.dmg
codesign --verify --strict --deep --verbose=2 build/Anser.app
```

If notarization fails, `release.sh` prints Apple's log, which names the file that was rejected.
