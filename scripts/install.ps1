<#
.SYNOPSIS
  POCOX CLI installer for Windows (PowerShell).

.DESCRIPTION
  Downloads the `pocox` binary from the latest GitHub release, matching your
  CPU, installs it under %LOCALAPPDATA%\Programs\pocket-codex, and adds that
  dir to your user PATH. An install of the CLI under its former name,
  `pocket-codex`, is updated too and keeps that name working through a
  `pocket-codex.cmd` shim.

  One-liner:
    irm https://raw.githubusercontent.com/acking-you/POCOX/main/scripts/install.ps1 | iex

  Environment overrides:
    POCKET_CODEX_VERSION        pin a release tag (e.g. v0.1.3); default: latest
    POCKET_CODEX_BIN_DIR        install dir; default: %LOCALAPPDATA%\Programs\pocket-codex
    POCKET_CODEX_NO_MODIFY_PATH set to 1 to skip adding the dir to PATH
#>

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 defaults to old TLS; force 1.2 for the GitHub API.
# (No-op / already default on PowerShell 7+.)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Repo = 'acking-you/POCOX'
$Bin = 'pocox'
# The CLI's former name.
$OldBin = 'pocket-codex'

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }

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
if ($env:POCKET_CODEX_VERSION) {
  $tag = $env:POCKET_CODEX_VERSION
  $url = "https://github.com/$Repo/releases/download/$tag/pocket-codex-cli-$tag-$target.zip"
}
else {
  Info "resolving the latest release for $target"
  $rel = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases/latest"
  $asset = $rel.assets | Where-Object { $_.name -like "pocket-codex-cli-*-$target.zip" } | Select-Object -First 1
  if (-not $asset) { throw "could not find a CLI asset for $target in the latest release." }
  $url = $asset.browser_download_url
  $tag = $rel.tag_name
}

# --- install vs update: report the current version, if any -----------------
$existing = Get-Command $Bin -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$old = Get-Command "$OldBin.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
  $cur = (& $existing.Source --version 2>$null | Select-Object -First 1)
  $curVer = if ($cur) { ($cur -split '\s+')[-1] } else { '(unknown version)' }
  Info "found $Bin $curVer at $($existing.Source) — updating to $tag"
}
elseif ($old) {
  $cur = (& $old.Source --version 2>$null | Select-Object -First 1)
  $curVer = if ($cur) { ($cur -split '\s+')[-1] } else { '(unknown version)' }
  Info "found $OldBin $curVer at $($old.Source) — updating to $Bin $tag"
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

  # The archive holds one dir `pocket-codex-cli-...\` containing the exe;
  # releases before the rename name it `pocket-codex.exe`.
  $exe = Get-ChildItem -Path $tmp -Recurse -Include "$Bin.exe", "$OldBin.exe" | Select-Object -First 1
  if (-not $exe) { throw "the archive did not contain a '$Bin.exe' binary." }

  # --- install --------------------------------------------------------------
  # When updating an existing install (and no explicit dir), replace THAT copy
  # so the user keeps the same location; otherwise the default programs dir.
  $binDir =
    if ($env:POCKET_CODEX_BIN_DIR) { $env:POCKET_CODEX_BIN_DIR }
    elseif ($existing) { Split-Path -Parent $existing.Source }
    elseif ($old) { Split-Path -Parent $old.Source }
    else { Join-Path $env:LOCALAPPDATA 'Programs\pocket-codex' }
  New-Item -ItemType Directory -Path $binDir -Force | Out-Null
  $dest = Join-Path $binDir "$Bin.exe"
  Copy-Item -Path $exe.FullName -Destination $dest -Force

  $newVer = (& $dest --version 2>$null | Select-Object -First 1)
  $newVer = if ($newVer) { ($newVer -split '\s+')[-1] } else { $tag }
  Info "installed $Bin $newVer -> $dest"

  # Keep the former name working for scripts and services written for it. A
  # running old exe cannot be deleted but can be renamed; `.exe` would win over
  # the `.cmd` shim while it stays in place.
  if ($old -and ((Split-Path -Parent $old.Source) -eq $binDir)) {
    $retired = "$($old.Source).old"
    Remove-Item -Path $retired -Force -ErrorAction SilentlyContinue
    Rename-Item -Path $old.Source -NewName (Split-Path -Leaf $retired)
    Set-Content -Path (Join-Path $binDir "$OldBin.cmd") -Value "@`"%~dp0$Bin.exe`" %*" -Encoding ASCII
    Remove-Item -Path $retired -Force -ErrorAction SilentlyContinue
    Info "$OldBin now runs $Bin"
  }
  elseif ($old) {
    Warn "an older $OldBin remains at $($old.Source); remove it, or point scripts at $dest"
  }

  # --- PATH -----------------------------------------------------------------
  if ($env:POCKET_CODEX_NO_MODIFY_PATH -ne '1') {
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
