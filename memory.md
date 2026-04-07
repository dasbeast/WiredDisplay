# WiredDisplay Release Memory

## Normal release flow

1. Update version numbers in Xcode/project settings.
   - `MARKETING_VERSION` = user-facing version, like `1.0.3`
   - `CURRENT_PROJECT_VERSION` = build number, like `4`
2. Update website download links in [website/index.html](/Users/baileykiehl/Desktop/WiredDisplay/website/index.html) if they are versioned.
3. Commit and push the release changes.
4. Tag the release.
5. Push the tag.
6. Watch the GitHub `Release` workflow.
7. After it finishes, verify:
   - Sparkle sees the new version
   - direct zip links work
   - homepage buttons point to the new version

## Commands

```sh
git add .
git commit -m "Release 1.0.x"
git push
git checkout main
git pull origin main
git tag v1.0.x
git push origin v1.0.x
```

You can also combine the last push if needed:

```sh
git push origin main v1.0.x
```

## Important release facts

- `git push` sends the commit.
- `git push origin v1.0.x` sends the tag.
- The tag is what triggers the GitHub release workflow.
- Sparkle cares about the app's bundled version/build, not the tag name by itself.
- If a build with the same version is already installed, Sparkle may say you are up to date.

## Current automation behavior

The GitHub release workflow now:

- runs validation
- builds sender and receiver
- signs and notarizes both apps
- uploads sender + receiver zip/appcast files
- publishes the website homepage
- publishes a GitHub release

## Website gotcha

If the site looks outdated but the direct files are current, check Safari/private browsing before assuming deploy failed.

Common issue:

- live site is updated
- Safari cached the old `index.html`

Quick checks:

- open the site in a private window
- hard refresh
- compare the homepage button against the direct zip URL

## If the homepage ever gets stale again

Manual upload command:

```sh
scp website/index.html baileykiehl@108.160.157.71:public_html/WDisplay/index.html
```

## If you need to verify the live homepage file on the server

```sh
ssh baileykiehl@108.160.157.71 "grep -n 'DisplayReceiver-' public_html/WDisplay/index.html"
```

## Receiver updater note

`DisplayReceiver` was changed to follow the simpler non-sandboxed update model so it behaves more like `DisplaySender` during Sparkle updates.
