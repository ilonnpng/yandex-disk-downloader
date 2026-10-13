# Yandex Disk Downloader — Windows 1.0.1

Native Windows app for downloading public Yandex Disk files and folders. Russian interface, recursive traversal, real byte progress, parallel downloads, pause/resume, cancellation, immediate error skipping and manual retry.

## Скачать

- **Windows-win-x64.zip** — обычный ПК с Intel или AMD.
- **Windows-win-arm64.zip** — Windows на ARM.

Полностью распакуйте архив и запустите **YandexDiskDownloader.exe**. Оставьте остальные файлы рядом с EXE. Среда .NET включена; отдельно устанавливать её не нужно.

Windows 10 22H2 / Windows 11, 64-bit. The EXE has no Authenticode certificate. Keep Windows security enabled; source, checksums and provenance are available for review.

GitHub Actions builds the tagged source, runs the core tests and x64 window smoke check, then attaches both ZIPs, **SHA256SUMS-Windows.txt** and **BUILD_INFO-Windows.txt**. ARM64 execution has not been tested on hardware. Partial downloads are not restored after quitting.

[Windows source and instructions](https://github.com/ilonnpng/yandex-disk-downloader/tree/v1.0.1-windows/Windows) · [Public build logs](https://github.com/ilonnpng/yandex-disk-downloader/actions/workflows/windows.yml)

Source review, checksums and build provenance support verification. They are not an independent security audit or antivirus guarantee.
