DJI Importer
============

DJI Importer is a small native macOS app for importing media from a connected
DJI Pocket 3 or SD card into Apple Photos.

The app keeps the original script behavior:

- Scan mounted volumes under `/Volumes`.
- Let the user choose a custom folder when automatic detection is not enough.
- Find supported media recursively.
- Import files into Photos through PhotoKit.
- Keep one local import manifest plus an append-only `imported-items.jsond`
  record so interrupted imports can resume without retrying already completed
  files.
- Start Over clears the manifest and imports the selected source from scratch.
- Optionally delete source files after every imported file has been recorded.

Supported formats currently match the original script:

- JPG
- JPEG
- MP4


Project Layout
--------------

- `DJIImporter.xcodeproj` - macOS app project.
- `DJIImporter/` - SwiftUI app source.
- `Scripts/python/` - legacy Python script and its original project files.


Development
-----------

Open the project in Xcode:

```bash
open DJIImporter.xcodeproj
```

Or build from the command line:

```bash
xcodebuild \
  -project DJIImporter.xcodeproj \
  -scheme DJIImporter \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  build
```

The debug app will be produced at:

```text
.build/DerivedData/Build/Products/Debug/DJIImporter.app
```


Release
-------

Create or update a GitHub release for the current app version:

```bash
Scripts/release_github.sh
```

The script builds the signed Release app, creates `dist/DJIImporter.app.zip`,
writes `dist/DJIImporter.app.zip.sha256`, and uploads both files to the
`v<MARKETING_VERSION>` GitHub release. By default it uses ad-hoc signing
(`CODE_SIGN_IDENTITY=-`), which is enough for macOS privacy services to attach
Photos permission to the app bundle identity during local testing. For public
distribution, pass a Developer ID identity and notarize the artifact. The
resulting sha256 must match the Homebrew cask.


Runtime Notes
-------------

- The first import may trigger a macOS Photos add-only permission prompt.
- If import fails with `Unauthorized access: client does not have valid TCC
  authorization`, rebuild with signing enabled, quit the app, run
  `tccutil reset PhotosAdd com.jjy.DJIImporter`, then launch the signed app and
  grant Photos permission again.
- The app does not do global duplicate detection. It only skips files already
  recorded in the current manifest when resuming an interrupted import.
- `Delete Originals` removes source files only after the full import finishes.
  It deletes only files recorded as successfully imported; files rejected by
  Photos or otherwise failed are kept on disk.
- If Photos rejects imports, open Photos once manually, then run the import
  again.
- The app is currently intended for direct Developer ID distribution rather than
  Mac App Store sandboxing.


Legacy Script
-------------

The previous command-line implementation is preserved:

```bash
python3 Scripts/python/dji_importer.py
```

It is useful as a behavior reference while the native app evolves.
