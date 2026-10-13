# Contributing

Open an issue describing the expected and actual behavior, macOS version, app version and reproducible steps. Use disposable public test data. Never include temporary download URLs, credentials or sensitive source links.

For a change:

1. Fork the repository and create a branch.
2. Keep network and filesystem behavior in YandexDiskCore, UI state on MainActor.
3. Add meaningful tests for changes to pagination, retries, path safety or integrity.
4. Run `./Scripts/test.sh` and `./Scripts/build-app.sh`.
5. When adding Swift files, add them to the Xcode targets or regenerate with `python3 Scripts/generate-xcode-project.py`.
6. Open a pull request explaining the problem, behavior and validation.

Do not add analytics, accounts, paid dependencies or automatic file overwrites. Do not weaken TLS validation or filesystem traversal defenses. Respect Yandex rate limits.

Before a public release, verify with full Xcode, Intel hardware, macOS 13, both appearances, a slow resumable server, disk-full / permission failures and the optional sandbox build. Developer ID signing and notarization belong to the release maintainer.
