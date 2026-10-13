# Yandex Disk Downloader for Windows

Native C# / WPF application. Public folder traversal, individual downloads, bounded parallelism, byte progress, pause/resume, cancellation, immediate failed-file skipping, manual retry, existing-file checks, SHA-256/MD5 verification, local settings and history. The first Windows interface is Russian.

## Скачать и запустить

1. Откройте https://github.com/ilonnpng/yandex-disk-downloader/releases/tag/v1.0.1-windows
2. Для обычного ПК с Intel/AMD скачайте ZIP **Windows-win-x64**. Для компьютера с Windows на ARM — **Windows-win-arm64**.
3. Полностью распакуйте ZIP в отдельную папку и запустите **YandexDiskDownloader.exe** внутри неё. Не переносите EXE отдельно от остальных файлов.
4. Вставьте публичную ссылку, нажмите «Проверить», выберите папку и нажмите «Скачать».

Windows 11, 64-bit. The self-contained archive includes the Microsoft .NET 10 runtime; there are no third-party application packages. Administrator rights, Python and a separate .NET installation are not required. Windows 10 execution is unverified; Microsoft's current .NET support on Windows 10 is limited to specific Enterprise/LTSC editions. See [Microsoft's supported Windows versions](https://learn.microsoft.com/dotnet/core/install/windows).

The EXE is not Authenticode-signed. Windows SmartScreen may warn about an unrecognized publisher. Keep Windows security protection enabled and review the source and build information before opening the app. No independent antivirus certification or security audit is claimed.

## Build and verify

On Windows with the .NET 10 SDK, from the repository root:

```powershell
pwsh -File Scripts/build-windows.ps1
```

The script runs core tests, publishes x64 and ARM64 self-contained applications, starts the x64 WPF window for a layout smoke check, creates ZIPs and SHA-256 checksums. It does not install anything or change system security settings.

Verify downloaded files with PowerShell:

```powershell
Get-FileHash .\YandexDiskDownloader-1.0.1-Windows-win-x64.zip -Algorithm SHA256
```

Compare with `SHA256SUMS-Windows.txt` from the same release. With GitHub CLI installed:

```powershell
gh attestation verify .\YandexDiskDownloader-1.0.1-Windows-win-x64.zip --repo ilonnpng/yandex-disk-downloader
```

`BUILD_INFO-Windows.txt` identifies the exact commit and public build job. Build provenance verifies origin, not the absence of bugs or malware.

## Windows-specific behavior and limits

- Files with invalid characters, reserved device names, trailing dots/spaces and case/Unicode collisions receive safe local names. Original API paths are retained.
- Existing files are never overwritten. A different existing file gets a numbered sibling.
- Destination reparse points (symbolic links / junctions) are rejected. Directory handles prevent rename/deletion while files are being checked or published. The app is not a security boundary against a privileged local attacker.
- Pausing retains open temporary-file handles in memory. Resume obtains a fresh HTTPS URL and sends a Range request; a server that ignores Range causes a clean restart. Invalid resume responses fail that file. Partial downloads are not restored after quitting.
- A response with no network data for 45 seconds fails that file, then the queue continues. Inspection retries transient API failures; individual file attempts do not retry automatically. HTTP 429 imposes a shared cooldown.
- Empty folders are created where permissions allow. Unavailable subfolders are reported as warnings. Disk-full/permission errors are reported; available space is needed for temporary data and destination staging.
- Settings and up to 200 history records are local to `%LOCALAPPDATA%\YandexDiskDownloader`. Signed download URLs are not persisted. No telemetry, updater, browser-credential access, background service or downloaded-file execution.
- x64 is tested on a hosted Windows runner. ARM64 is cross-compiled; real ARM64 hardware and Windows 10 runtime testing remain release QA tasks.
- The app honors Yandex access restrictions; it does not bypass them.

The macOS Swift implementation remains in `Sources/`. This Windows port uses `Windows/Core` for network/filesystem logic and `Windows/App` for the WPF interface and view model.
