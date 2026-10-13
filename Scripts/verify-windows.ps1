$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$work = "$PWD/.build/WindowsQA"
New-Item -ItemType Directory -Force "$work/screenshots" | Out-Null
$repo = 'ilonnpng/yandex-disk-downloader'
$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/tags/v1.0.1-windows"
$asset = $release.assets | Where-Object name -eq 'YandexDiskDownloader-1.0.1-Windows-win-x64.zip'
if (!$asset) { throw 'Published x64 ZIP not found' }
$zip = "$work/$($asset.name)"
Invoke-WebRequest $asset.browser_download_url -OutFile $zip
$digest = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ("sha256:$digest" -ne $asset.digest) { throw 'Downloaded release ZIP digest mismatch' }
Write-Host "PASS published archive SHA-256: $digest"
gh attestation verify $zip --repo $repo
if ($LASTEXITCODE -ne 0) { throw 'Build provenance verification failed' }
Expand-Archive $zip -DestinationPath "$work/published" -Force
$app = "$work/published/Windows-win-x64"
$process = Start-Process "$app/YandexDiskDownloader.exe" -ArgumentList '--smoke', "`"$work/screenshots/01-window.png`"" -PassThru -Wait -RedirectStandardError "$work/exe-stderr.txt"
if (Test-Path "$work/screenshots/01-window.png.error.txt") { Get-Content "$work/screenshots/01-window.png.error.txt" | Write-Host }
if ($process.ExitCode -ne 0 -or !(Test-Path "$work/screenshots/01-window.png")) { throw 'Published EXE launch failed' }
Write-Host 'PASS published EXE launch and built-in queue smoke checks'
dotnet run --project Windows/Tests/Tests.csproj -c Release "-p:CoreAssemblyPath=$app/Core.dll"
if ($LASTEXITCODE -ne 0) { throw 'Published core tests failed' }
dotnet run --project Windows/QaRunner/QaRunner.csproj -c Release "-p:CoreAssemblyPath=$app/Core.dll" "-p:AppAssemblyPath=$app/YandexDiskDownloader.dll" -- "$work/screenshots"
if ($LASTEXITCODE -ne 0) { throw 'Published interface functional checks failed' }
@"
Published Windows app QA
OS: $([Environment]::OSVersion.VersionString)
Release: $($release.html_url)
Archive SHA-256: $digest
EXE startup: PASS
Core scenarios: 18/18 PASS against the published Core.dll
Queue / pause / range resume / retry / existing files / cancel / collisions: PASS
UI screenshots are rendered from the running WPF application on Windows.
Downloads in functional scenarios use a controlled HTTP fixture, not live Yandex CDN endpoints.
"@ | Set-Content "$work/QA-RESULTS.txt" -Encoding utf8
# Publish nonsensitive demo screenshots and QA evidence with the app's public source.
$evidence = @(Get-ChildItem "$work/screenshots/*.png") + @(Get-Item "$work/QA-RESULTS.txt")
foreach ($file in $evidence) {
    $path = "docs/windows-qa/$($file.Name)"
    $existing = gh api "repos/$repo/contents/$path" --jq .sha 2>$null
    $body = @{ message = 'Publish Windows execution screenshots and QA evidence'; branch = 'main'; content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName)) }
    if ($LASTEXITCODE -eq 0) { $body.sha = "$existing" }
    $body | ConvertTo-Json | Set-Content "$work/upload.json" -Encoding utf8
    gh api --method PUT "repos/$repo/contents/$path" --input "$work/upload.json" --silent
    if ($LASTEXITCODE -ne 0) { throw "Evidence upload failed: $path" }
}
