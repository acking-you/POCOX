//! Bounded output from a short owned helper, including descendant cleanup.

use std::{ffi::OsString, path::Path, time::Duration};

use tokio::{io::AsyncReadExt, process::ChildStdout};

use super::{leader_exited, spawn, SpawnError, Spawned};

const EXIT_POLL: Duration = Duration::from_millis(20);

/// Why inspecting an installed executable failed. Never contains child output.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum OutputError {
    /// The helper could not start.
    #[error(transparent)]
    Spawn(#[from] SpawnError),
    /// The helper exceeded its entire inspection budget.
    #[error("the executable inspection timed out; retry after checking the executable")]
    Timeout,
    /// The helper exited unsuccessfully or could not be reaped.
    #[error("the executable inspection did not exit successfully")]
    Exit,
    /// Output could not be read within the expected bound.
    #[error("the executable inspection returned unreadable or oversized output")]
    Output,
}

/// Read a successful helper's bounded stdout, with no shell and no echoed
/// stderr. The helper inherits the environment plus explicit child overrides.
/// Failure, oversized output, or a timeout returns no output. Every outcome
/// cleans up the process group before returning.
pub async fn read_output(
    program: &Path,
    args: &[String],
    path: Option<&OsString>,
    env: &[(OsString, OsString)],
    timeout: Duration,
    limit: usize,
) -> Option<Vec<u8>> {
    inspect_output(program, args, path, env, timeout, limit)
        .await
        .ok()
}

/// Inspect an executable while retaining the failure category. Every outcome
/// cleans up the owned process group; no stderr or command arguments are
/// echoed.
pub async fn inspect_output(
    program: &Path,
    args: &[String],
    path: Option<&OsString>,
    env: &[(OsString, OsString)],
    timeout: Duration,
    limit: usize,
) -> Result<Vec<u8>, OutputError> {
    let Spawned {
        process,
        stdin,
        stdout,
    } = spawn(program, args, path, env)?;
    drop(stdin);
    let result = tokio::time::timeout(timeout, collect(stdout, process.id(), limit)).await;
    match result {
        Ok(Some(output)) => {
            let status = process.finish().await.ok_or(OutputError::Exit)?;
            if status.success() {
                Ok(output)
            } else {
                Err(OutputError::Exit)
            }
        },
        result => {
            process.terminate(Duration::from_millis(100)).await;
            Err(if result.is_err() { OutputError::Timeout } else { OutputError::Output })
        },
    }
}

async fn collect(mut stdout: ChildStdout, leader: Option<u32>, limit: usize) -> Option<Vec<u8>> {
    let leader = leader?;
    let mut output = Vec::new();
    let mut chunk = [0u8; 8192];
    let mut open = true;
    loop {
        if leader_exited(leader) {
            while open {
                match tokio::time::timeout(EXIT_POLL, stdout.read(&mut chunk)).await {
                    Ok(Ok(0)) | Err(_) => open = false,
                    Ok(Ok(n)) => append(&mut output, &chunk[..n], limit)?,
                    Ok(Err(_)) => return None,
                }
            }
            return Some(output);
        }
        if !open {
            tokio::time::sleep(EXIT_POLL).await;
            continue;
        }
        tokio::select! {
            read = stdout.read(&mut chunk) => match read {
                Ok(0) => open = false,
                Ok(n) => append(&mut output, &chunk[..n], limit)?,
                Err(_) => return None,
            },
            () = tokio::time::sleep(EXIT_POLL) => {},
        }
    }
}

fn append(output: &mut Vec<u8>, bytes: &[u8], limit: usize) -> Option<()> {
    if output.len().saturating_add(bytes.len()) > limit {
        return None;
    }
    output.extend_from_slice(bytes);
    Some(())
}
