# Yandex Disk Downloader 1.0.1

Native macOS app for downloading public Yandex Disk folders and files.

**macOS 13 or later · Apple Silicon and Intel · English and Russian**

## Download and install

Download **YandexDiskDownloader-1.0.1-macOS-universal.zip**, unzip it and move **Yandex Disk Downloader.app** to Applications. The automatic Source code archives contain the source project, not the app.

GitHub Actions builds this release from the version tag, runs tests, publishes a provenance attestation and attaches the app, `SHA256SUMS.txt` and `BUILD_INFO.txt` after the workflow completes.

The app is ad-hoc signed and is not Apple-notarized. Use macOS's standard Open / Privacy & Security controls; keep Gatekeeper enabled.

## Changes

- Recursive individual-file downloads with progress and configurable parallelism.
- Failed files are skipped immediately; retry them manually after the queue finishes.
- Improved handling of problematic filenames, API child paths and inaccessible nested folders.
- Safe writes without overwriting existing files, optional checksum verification, settings and download history.

Partial downloads are not restored after quitting. Yandex restrictions and network availability still apply. Intel hardware and macOS 13 execution have not been verified locally.

See [security and verification](https://github.com/ilonnpng/yandex-disk-downloader/blob/v1.0.1/SECURITY.md) and the [validation report](https://github.com/ilonnpng/yandex-disk-downloader/blob/v1.0.1/docs/VALIDATION.md). Public source and build provenance support review; they are not an antivirus certification.
