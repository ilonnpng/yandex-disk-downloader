# Validation — 2026-10-13

## Build

- Native SwiftUI app compiled on Apple Silicon using Apple Swift 6.3.2 / Command Line Tools.
- Release builds for arm64 and x86_64 succeeded; `lipo` confirmed both architectures in the universal executable.
- Ad-hoc code signature verified with `codesign --verify --strict`.
- Minimum deployment target is macOS 13. Intel execution and execution on macOS 13 were not available for testing.
- Xcode project syntax validated with `plutil`; full `xcodebuild` could not run because Xcode is not installed. The same app/core sources compile with Swift Package Manager.
- DMG creation was attempted but the host rejected the disk-image operation with “Device not configured.” The app is distributed in a ZIP instead.

## Automated checks

18 scenarios passed using Swift Testing, with identical XCTest wrappers included for full Xcode:

1. Public-link validation and malicious host rejection.
2. Resource and download-link JSON parsing.
3. Recursive traversal and multi-page folder listing.
4. Single public file handling.
5. HTTP 429 / 503 retries, 403 rejection and Retry-After parsing.
6. Incomplete pagination detection.
7. Unsafe filename and parent-traversal rejection.
8. File-size / checksum verification, symlink rejection and non-overwriting file publication.
9. Download-task file bytes with URLProtocol mocks.
10. 25 simultaneous API requests through the shared rate gate.
11. Pause before transfer start.
12. Download HTTP error propagation.
13. A stalled transfer times out instead of hanging indefinitely.
14. The data-task fallback streams the expected bytes to disk.
15. Local name normalization and deterministic shortening.
16. A folder with colons, case collisions, misleading metadata paths and an unsafe child still yields safe files and explicit warnings.
17. Prefixed API paths and a missing nested folder still yield the remaining files.
18. Cancellation before transfer start.

## Native UI and real API

The supplied public folder was inspected through the running app. Its name is “1. Шляпа мыслей”; metadata contained 25 files totaling approximately 10.9 MB, including nested folders.

Real MP3 files were downloaded to a separate `integration-downloads` directory. Size and checksum verification were enabled. At least six files were downloaded successfully during testing. Some direct file endpoints timed out with NSURLError -1001. These are not claimed as successful downloads.

Verified interactively: link input, automatic inspection, NSOpenPanel selection, real byte progress, cancellation with preservation of completed files, verifying/skipping existing files after restart, settings persistence, Russian language and light/dark presentation. A real screenshot is included in README.

Pause stopped scheduling and progress. The initial suspension implementation stalled on resuming and was replaced by cancellation with URLSession resume data and a fresh URL on continuation. The final implementation is covered by basic pause/cancel tests, but a complete live resumable-byte transfer was not demonstrated. The streaming fallback restarts a partial file.

User-requested final error policy: do not retry a failed file inside the current queue. Record its error, continue with the next file and provide **Retry Failed Downloads** when the pass finishes. Inspection retries and rate-limit cooldowns remain enabled. This policy supersedes the automatic per-file retry requirement in the initial specification.

## Remaining release QA

- Complete live download of every file from the test folder under a connection that reaches all supplied CDN endpoints.
- Full Xcode build and XCTest execution.
- Intel hardware and macOS 13 runtime checks.
- A slow server exercising live mid-file pause/resume, expired resume URLs and interrupted transfers.
- Deliberate disk-full and write-permission integration tests.
- Notification delivery and the optional App Sandbox build.
- Developer ID signing / notarization for public distribution.

The project is ready for review and further release QA; the observations above do not constitute a claim that every original acceptance criterion was fully verified.

## 1.0.1 name-handling correction

The old generic unsafe-path message could be triggered by legitimate remote names or differences in reported path metadata. API names are now validated separately from local names. Compatible names retain their spelling; unsupported local characters are mapped to underscores, very long names are shortened deterministically, and case/Unicode collisions are numbered. API requests continue to use original names. Validated API-reported paths are used independently of local paths, instead of requiring them to exactly match the display hierarchy. Missing path fields use validated original names. Truly unsafe child names, excessive depth and unavailable subfolders are skipped with visible warnings.
