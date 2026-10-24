//! Exercise the Windows launcher through a batch shim and a nested shell.

use std::fs;
use std::process::Stdio;

use super::build_command;

#[test]
fn shim_and_nested_shell_run_without_a_console_window() {
    let dir = tempfile::tempdir().expect("fixture directory");
    let shim = dir.path().join("codex launcher.cmd");
    fs::write(
        &shim,
        "@echo off\r\npowershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
         -File \"%~dp0probe.ps1\"\r\nexit /b %errorlevel%\r\n",
    )
    .expect("batch shim");
    // Check the OS console association, not command flags or printed wording.
    // The nested shell deliberately does not request window hiding.
    fs::write(
        dir.path().join("probe.ps1"),
        r#"$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleProbe {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
}
'@
if ([ConsoleProbe]::GetConsoleWindow() -ne [IntPtr]::Zero) { exit 9 }
[Console]::Out.Write('command completed')
"#,
    )
    .expect("nested shell probe");
    let output = build_command(&shim, "ws://127.0.0.1:1", &[], None, None)
        .stdin(Stdio::null())
        .output()
        .expect("run the production launcher");
    assert!(
        output.status.success(),
        "the nested command must execute without attaching a console: {:?}; {}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(output.stdout, b"command completed", "preserve command output");
}
