//! Bounded, credential-free reader processes. No shell or agent is involved.

use std::{ffi::OsString, path::Path, time::Duration};

use anyhow::{bail, Context, Result};
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::process::{self, Spawned};

const MAX_INPUT: usize = 64 * 1024;
pub(super) const MAX_OUTPUT: usize = 10 * 1024 * 1024;

pub(super) async fn read_json(
    program: &Path,
    args: &[String],
    env: &[(OsString, OsString)],
    input: &Value,
) -> Result<Value> {
    read_json_with_timeout(program, args, env, input, Duration::from_secs(20)).await
}

pub(super) async fn read_json_with_timeout(
    program: &Path,
    args: &[String],
    env: &[(OsString, OsString)],
    input: &Value,
    timeout: Duration,
) -> Result<Value> {
    let input = serde_json::to_vec(input)?;
    if input.len() > MAX_INPUT {
        bail!("native history request is too large");
    }
    let Spawned {
        process,
        mut stdin,
        mut stdout,
    } = process::spawn_isolated(program, args, env).context("starting native history reader")?;
    let pid = process
        .id()
        .context("native history reader has no process id")?;
    let result = tokio::time::timeout(timeout, async {
        stdin.write_all(&input).await?;
        stdin.shutdown().await?;
        drop(stdin);
        let mut output = Vec::new();
        let mut buffer = [0u8; 8192];
        let mut eof = false;
        loop {
            tokio::select! {
                count = stdout.read(&mut buffer), if !eof => {
                    let count = count?;
                    eof = count == 0;
                    if output.len() + count > MAX_OUTPUT {
                        bail!("native history reader output exceeded its limit");
                    }
                    output.extend_from_slice(&buffer[..count]);
                }
                _ = tokio::time::sleep(Duration::from_millis(20)) => {
                    if process::leader_exited(pid) {
                        // Descendants may retain a pipe. Never wait for them
                        // indefinitely after the reader leader has exited.
                        if !eof {
                            let tail = tokio::time::timeout(Duration::from_millis(200), async {
                                loop {
                                    let count = stdout.read(&mut buffer).await?;
                                    if count == 0 { break; }
                                    if output.len() + count > MAX_OUTPUT {
                                        bail!("native history reader output exceeded its limit");
                                    }
                                    output.extend_from_slice(&buffer[..count]);
                                }
                                Ok::<_, anyhow::Error>(())
                            }).await;
                            tail.context("native history reader left its output open")??;
                        }
                        return Ok(output);
                    }
                }
            }
        }
    })
    .await;
    let output = match result {
        Ok(Ok(output)) => output,
        other => {
            process.terminate(Duration::from_millis(50)).await;
            return match other {
                Err(_) => Err(anyhow::anyhow!("native history reader timed out")),
                Ok(Err(error)) => Err(error),
                Ok(Ok(_)) => unreachable!(),
            };
        },
    };
    if !process
        .finish()
        .await
        .is_some_and(|status| status.success())
    {
        bail!("native history reader failed; no session was resumed");
    }
    let value: Value =
        serde_json::from_slice(&output).context("invalid native history response")?;
    // The helper returns a fixed error code, never a native exception or path.
    if let Some(code) = value.get("error").and_then(Value::as_str) {
        bail!("native history read failed ({})", match code {
            "not_found" => "session not found",
            "source_changed" => "source changed; retry",
            "invalid_cursor" => "invalid cursor",
            "source_too_large" => "transcript exceeds reader limit",
            _ => "reader unavailable",
        });
    }
    Ok(value)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[tokio::test]
    async fn child_receives_only_explicit_environment_and_complete_input() {
        let value = read_json(
            Path::new("/bin/sh"),
            &[
                "-c".into(),
                "input=$(cat); test -z \"$HOME\" && test \"$POCOX_READER_TEST\" = yes && printf \
                 '%s' \"$input\""
                    .into(),
            ],
            &[("POCOX_READER_TEST".into(), "yes".into())],
            &serde_json::json!({"ok":true}),
        )
        .await
        .expect("read");
        assert_eq!(value, serde_json::json!({"ok":true}));
    }

    #[tokio::test]
    async fn failed_child_output_is_not_returned_as_history_or_error_details() {
        let error = read_json(
            Path::new("/bin/sh"),
            &["-c".into(), "printf 'private error'; exit 1".into()],
            &[],
            &Value::Null,
        )
        .await
        .expect_err("must fail");
        assert!(!error.to_string().contains("private error"));
    }

    #[tokio::test]
    async fn descendant_holding_output_does_not_stall_reader() {
        let start = std::time::Instant::now();
        let result = read_json(
            Path::new("/bin/sh"),
            &["-c".into(), "sleep 30 & printf '{}'".into()],
            &[],
            &Value::Null,
        )
        .await;
        assert!(result.is_err());
        assert!(start.elapsed() < Duration::from_secs(5));
    }
}
