# Security and build verification

This project publishes its source, build scripts, test results and release checksums. These help you inspect the program and verify where a download came from. They do not certify that a program is virus-free. No independent security audit has been completed.

## What the app does

- Uses HTTPS to contact Yandex's public Disk API and the download URLs that API supplies. HTTPS redirects are required.
- Downloads files into the folder you select. Downloaded files are not executed by the app.
- Does not request Yandex passwords or OAuth tokens, read browser credentials, install a background service, request administrator privileges or run shell commands.
- Stores settings, public source links and destination paths locally in UserDefaults. There is no telemetry, third-party backend or automatic updater.
- Uses exclusive staging files and descriptor-relative filesystem operations to reject symbolic-link traversal and avoid overwriting existing files.

Review `Sources/YandexDiskCore/` for network and filesystem code and `Sources/YandexDiskDownloader/` for the interface and local settings.

## Verify a release

Download the application ZIP, `SHA256SUMS.txt` and `BUILD_INFO.txt` from the same GitHub release. In that directory:

```sh
shasum -a256 -c SHA256SUMS.txt
```

GitHub Actions builds the release from the version tag, runs the tests and publishes a provenance attestation. With GitHub CLI installed, verify it using:

```sh
gh attestation verify YandexDiskDownloader-1.0.1-macOS-universal.zip --repo ilonnpng/yandex-disk-downloader
```

`BUILD_INFO.txt` identifies the source commit and public build log. Workflow dependencies are pinned to commit hashes. You can also build the source yourself with `Scripts/build-app.sh` and inspect the workflows in `.github/workflows/`.

Checksums detect changed bytes; attestations describe build origin. Neither replaces source review or security analysis.

## macOS signing

The published app uses ad-hoc signing. It is not Developer ID signed or notarized by Apple. macOS may require approval through its standard Open / Privacy & Security controls. Keep Gatekeeper enabled.

## Reporting

Use GitHub Issues for reports that contain no sensitive details. Do not post private links, temporary signed download URLs or personal files. For a sensitive vulnerability, contact the maintainer privately before sharing details in public.
