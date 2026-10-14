//! Bounded output from a short owned helper, including descendant cleanup.

use std::{ffi::OsString, path::Path, time::Duration};

use tokio::{io::AsyncReadExt, process::ChildStdout};

use super::{leader_exited, spawn, Spawned};

const EXIT_POLL: Duration = Duration::from_millis(20);

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
    let Spawned {
        process,
        stdin,
        stdout,
    } = spawn(program, args, path, env).ok()?;
    drop(stdin);
    let result = tokio::time::timeout(timeout, collect(stdout, process.id(), limit)).await;
    match result {
        Ok(Some(output)) => process.finish().await?.success().then_some(output),
        Ok(None) | Err(_) => {
            process.terminate(Duration::from_millis(100)).await;
            None
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
