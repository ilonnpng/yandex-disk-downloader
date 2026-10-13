# Changelog

## 1.0.1 — 2026-10-13

- Normalize unsupported local names without altering their original Yandex API paths.
- Resolve case and Unicode name collisions with stable numbered names.
- Report renamed/skipped items instead of aborting an entire folder.
- Use validated API-reported paths even when they differ from display hierarchy. Skip inaccessible subfolders with visible warnings.
- Skip failed downloads immediately; retry them manually after the queue finishes.
- Avoid security-scoped bookmark operations in non-sandboxed builds.

## 1.0.0 — 2026-10-13

- Initial native SwiftUI app for public Yandex Disk files and folders.
- Recursive pagination and individual downloads with bounded concurrency.
- Byte progress, retries, pause / resume and cancellation.
- Integrity verification, safe filesystem writes and collision handling.
- Settings, local history, language and appearance controls.
- Xcode project, Swift Package, tests and universal app packaging scripts.
