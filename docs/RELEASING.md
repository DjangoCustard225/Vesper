# Releasing

The first release uses the tag **`0.1`**, app version **0.1**, and bundle ID **`app.vesper`**.

## Prepare

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Vesper/Info.plist`.
2. Regenerate the project with `swift Scripts/GenerateXcodeProject.swift`.
3. Validate the release build and IPA.
4. Check the packaged `Payload/Vesper.app/Info.plist`, archive integrity, icon, and executable.
5. Add release notes under `docs/releases/`, commit the source, and create the matching annotated tag.

Keep binaries, credentials, signing material, and generated build files out of Git. Upload the IPA as a release asset.

## Publish 0.1

Run from the project folder with GitHub CLI authenticated and network access available. The repository and release are intended to be public.

If the GitHub repository does not exist yet:

```sh
gh repo create DjangoCustard225/Vesper --public --source=. --remote=origin --push \
  --description 'A native iOS movie and series app with Liquid Glass, TMDB metadata, and Stremio-compatible add-ons.'
```

Push the prepared tag and create a draft with its assets:

```sh
git push origin main
git push origin 0.1
gh release create 0.1 xtool/Vesper.ipa xtool/SHA256SUMS.txt \
  --repo DjangoCustard225/Vesper --verify-tag --draft \
  --title 'Vesper 0.1' --notes-file docs/releases/0.1.md
```

Check the draft's source tag and uploaded assets, then publish:

```sh
gh release edit 0.1 --repo DjangoCustard225/Vesper --draft=false --latest
gh release view 0.1 --repo DjangoCustard225/Vesper
```

To verify the downloaded IPA locally:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

The IPA is unsigned; installation requires signing. Do not replace an existing published tag or asset without reviewing the intended change.
