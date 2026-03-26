# CI/CD

WiredDisplay now has two automation layers:

- CI validation on pushes and pull requests via [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
- tagged releases via [`.github/workflows/release.yml`](../.github/workflows/release.yml)

## Day-to-day flow

1. Make a change.
2. Run `./scripts/ci.sh`.
3. Commit and push your branch.
4. Open or update a pull request.
5. GitHub Actions runs the same validation as local CI.
6. Merge after CI is green.

## Release flow

This repo uses a tag-driven release to keep shipping explicit and safe.

1. Merge your change to `main`.
2. Bump the app version/build if needed.
3. Push a tag such as `v1.2.3`.
4. GitHub Actions runs validation again.
5. If validation passes, the release workflow:
   - imports the Developer ID certificate
   - stores notary credentials
   - writes the Sparkle private key
   - runs both release scripts
   - uploads artifacts to the website
   - creates a GitHub release with the produced zips and appcasts

## Required GitHub secrets

These are required for automated releases:

- `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64`
- `APPLE_DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `APPLE_KEYCHAIN_PASSWORD`
- `APPLE_NOTARY_ISSUER_ID`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_KEY_P8`
- `SPARKLE_PRIVATE_KEY`
- `WDISPLAY_SSH_HOST`
- `WDISPLAY_SSH_USER`
- `WDISPLAY_SSH_KEY`

These are optional and fall back to the existing script defaults when omitted:

- `WDISPLAY_SSH_KNOWN_HOSTS`
- `WDISPLAY_FEED_BASE_URL`
- `WDISPLAY_REMOTE_DIR`
- `WDISPLAY_RECEIVER_FEED_BASE_URL`
- `WDISPLAY_RECEIVER_REMOTE_DIR`
- `WDISPLAY_RECEIVER_APPCAST_FILENAME`
- `WDISPLAY_RECEIVER_SU_FEED_URL`
- `WDISPLAY_CODE_SIGN_IDENTITY`
- `WDISPLAY_RECEIVER_CODE_SIGN_IDENTITY`
- `WDISPLAY_SPARKLE_PUBLIC_ED_KEY`

## Notes

- CI and release are intentionally separate. Regular branch pushes validate code, but only tags publish binaries.
- The release workflow reuses [`scripts/release_displaysender.sh`](../scripts/release_displaysender.sh) and [`scripts/release_displayreceiver.sh`](../scripts/release_displayreceiver.sh), so local and GitHub releases follow the same packaging path.
