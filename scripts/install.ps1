<#
.SYNOPSIS
  POCOX CLI installer for Windows (PowerShell).

.DESCRIPTION
  Downloads the `pocox` binary from the latest GitHub release, matching your
  CPU, installs it under %LOCALAPPDATA%\Programs\pocox, and adds that
  dir to your user PATH. An existing pocox install is updated in place.

  One-liner:
    irm https://raw.githubusercontent.com/acking-you/POCOX/main/scripts/install.ps1 | iex

  Environment overrides:
    POCOX_VERSION        pin a release tag (e.g. v0.1.3); default: latest
    POCOX_BIN_DIR        install dir; default: %LOCALAPPDATA%\Programs\pocox
    POCOX_NO_MODIFY_PATH set to 1 to skip adding the dir to PATH
#>

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 defaults to old TLS; force 1.2 for the GitHub API.
# (No-op / already default on PowerShell 7+.)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Repo = 'acking-you/POCOX'
$Bin = 'pocox'

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }

# A directory as one canonical string, so paths in it compare equal.
function Normalize-Dir($dir) {
  $trimmed = [IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
  if ($trimmed -match ':$') { "$trimmed\" } else { $trimmed }
}

# Move a file aside so a new one can take its name: a running exe cannot be
# overwritten or deleted, but it can be renamed (and is deleted once free).
function Retire($path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  $retired = "$path.old"
  Remove-Item -LiteralPath $retired -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $retired) { $retired = "$path.$([Guid]::NewGuid().ToString('N')).old" }
  Rename-Item -LiteralPath $path -NewName (Split-Path -Leaf $retired)
  Remove-Item -LiteralPath $retired -Force -ErrorAction SilentlyContinue
}

# --- detect CPU -> Rust target ---------------------------------------------
# Only x86_64-pc-windows-msvc is published; on Windows-on-ARM it runs fine
# under the built-in x64 emulation.
$archEnv = "$env:PROCESSOR_ARCHITECTURE$env:PROCESSOR_ARCHITEW6432"
if ($archEnv -match 'ARM64') {
  Warn 'Windows on ARM detected; installing the x64 build (runs under emulation).'
}
$target = 'x86_64-pc-windows-msvc'

# --- resolve the download URL + tag ----------------------------------------
$headers = @{ 'User-Agent' = 'pocox-install' }
if ($env:POCOX_VERSION) {
  $tag = $env:POCOX_VERSION
  $url = "https://github.com/$Repo/releases/download/$tag/pocox-cli-$tag-$target.zip"
}
else {
  Info "resolving the latest release for $target"
  $rel = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases/latest"
  $asset = $rel.assets | Where-Object { $_.name -like "pocox-cli-*-$target.zip" } | Select-Object -First 1
  if (-not $asset) { throw "could not find a CLI asset for $target in the latest release." }
  $url = $asset.browser_download_url
  $tag = $rel.tag_name
}

# --- install vs update: report the current version, if any -----------------
$existing = Get-Command $Bin -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
  $cur = (& $existing.Source --version 2>$null | Select-Object -First 1)
  $curVer = if ($cur) { ($cur -split '\s+')[-1] } else { '(unknown version)' }
  Info "found $Bin $curVer at $($existing.Source) — updating to $tag"
}
else {
  Info "installing $Bin $tag"
}

# --- download + unpack ------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("pocox-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
  $zip = Join-Path $tmp 'cli.zip'
  Info "downloading $url"
  Invoke-WebRequest -Headers $headers -Uri $url -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $tmp -Force

  # The archive holds one dir `pocox-cli-...\` containing the exe.
  $exe = Get-ChildItem -Path $tmp -Recurse -Include "$Bin.exe" | Select-Object -First 1
  if (-not $exe) { throw "the archive did not contain a '$Bin.exe' binary." }

  # --- install --------------------------------------------------------------
  # When updating an existing install (and no explicit dir), replace THAT copy
  # so the user keeps the same location; otherwise the default programs dir.
  $binDir = Normalize-Dir $(
    if ($env:POCOX_BIN_DIR) { $env:POCOX_BIN_DIR }
    elseif ($existing) { Split-Path -Parent $existing.Source }
    else { Join-Path $env:LOCALAPPDATA 'Programs\pocox' })
  New-Item -ItemType Directory -Path $binDir -Force | Out-Null
  $dest = Join-Path $binDir "$Bin.exe"
  # The installed copy may be running (a worker it started).
  Retire $dest
  Copy-Item -Path $exe.FullName -Destination $dest -Force

  $newVer = (& $dest --version 2>$null | Select-Object -First 1)
  $newVer = if ($newVer) { ($newVer -split '\s+')[-1] } else { $tag }
  Info "installed $Bin $newVer -> $dest"

  # --- PATH -----------------------------------------------------------------
  if ($env:POCOX_NO_MODIFY_PATH -ne '1') {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = ($userPath -split ';') | Where-Object { $_ -ne '' }
    if ($parts -notcontains $binDir) {
      [Environment]::SetEnvironmentVariable('Path', (($parts + $binDir) -join ';'), 'User')
      $env:Path = "$env:Path;$binDir"  # current session too
      Info "added $binDir to your user PATH (restart other terminals to pick it up)."
    }
  }

  Info "done. Run '$Bin --help' to get started."
}
finally {
  Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
