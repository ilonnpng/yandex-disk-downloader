param([string]$Version = '1.0.1')
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
dotnet run --project Windows/Tests/Tests.csproj -c Release
if ($LASTEXITCODE -ne 0) { throw 'Core tests failed' }
New-Item -ItemType Directory -Force dist | Out-Null
foreach ($rid in @('win-x64', 'win-arm64')) {
    $output = "dist/Windows-$rid"
    dotnet publish Windows/App/YandexDiskDownloader.csproj -c Release -r $rid --self-contained true -p:Version=$Version -o $output
    if ($LASTEXITCODE -ne 0) { throw "Publish failed: $rid" }
    Copy-Item LICENSE "$output/LICENSE.txt"
    Copy-Item Windows/README.md "$output/README.txt"
    $archive = "dist/YandexDiskDownloader-$Version-Windows-$rid.zip"
    Compress-Archive -Path $output -DestinationPath $archive -CompressionLevel Optimal -Force
}
$smoke = Start-Process -FilePath "$PWD/dist/Windows-win-x64/YandexDiskDownloader.exe" -ArgumentList '--smoke', "`"$PWD/dist/screenshot-windows.png`"" -PassThru -Wait -RedirectStandardError "$PWD/dist/smoke-stderr.txt" -RedirectStandardOutput "$PWD/dist/smoke-stdout.txt"
Write-Host "WPF smoke exit: $($smoke.ExitCode); screenshot exists: $(Test-Path dist/screenshot-windows.png)"
if (Test-Path dist/screenshot-windows.png.error.txt) { Get-Content dist/screenshot-windows.png.error.txt | Write-Host }
if (Test-Path dist/smoke-stderr.txt) { Get-Content dist/smoke-stderr.txt | Write-Host }
if ($smoke.ExitCode -ne 0 -or !(Test-Path dist/screenshot-windows.png)) { throw 'WPF window smoke check failed' }
$checksums = Get-ChildItem dist/YandexDiskDownloader-*-Windows-*.zip | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name }
[IO.File]::WriteAllLines("$PWD/dist/SHA256SUMS-Windows.txt", [string[]]$checksums, [Text.UTF8Encoding]::new($false))
$commit = git rev-parse HEAD
$build = if ($env:GITHUB_RUN_ID) { "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID" } else { 'local build' }
@"
Yandex Disk Downloader Windows $Version
Source commit: $commit
Targets: Windows x64 and ARM64; self-contained .NET 10/WPF
Build: $build
Signing: no Authenticode certificate; not independently security-audited.
Tests: core test runner plus an x64 WPF window/layout smoke check.
ARM64 binaries are cross-compiled; ARM64 execution is not verified by this job.
Verify the ZIP bytes using SHA256SUMS-Windows.txt and GitHub build provenance.
"@ | Set-Content dist/BUILD_INFO-Windows.txt -Encoding utf8
