//! The processes of a handoff: the app being waited for, the helper's own
//! halves, the reopened app, and the lock one update of a copy holds.

use std::ffi::{OsStr, OsString};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::Path;
use std::time::Duration;

use anyhow::{bail, ensure, Result};
use windows_sys::Win32::Foundation::{
    ERROR_CANCELLED, WAIT_ABANDONED, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::System::Threading::{
    CreateMutexW, CreateProcessW, GetExitCodeProcess, OpenProcess, ReleaseMutex,
    WaitForSingleObject, CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW,
    PROCESS_INFORMATION, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, STARTUPINFOW,
};
use windows_sys::Win32::UI::Shell::{
    ShellExecuteExW, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS,
    SHELLEXECUTEINFOW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK, SW_HIDE};

/// `value` as a terminated UTF-16 string.
pub fn wide(value: impl AsRef<OsStr>) -> Vec<u16> {
    value.as_ref().encode_wide().chain(Some(0)).collect()
}

fn millis(timeout: Duration) -> u32 {
    // INFINITE (u32::MAX) is never meant.
    u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX - 1)
}

/// A process held by its handle, so a reused process id can never stand in
/// for it.
pub struct Process(OwnedHandle);

impl Process {
    /// The process `id`, which must still be running.
    pub fn pin(id: u32) -> Result<Self> {
        // SAFETY: OpenProcess takes no pointers; a non-null result is a
        // process handle that nothing else owns.
        let raw =
            unsafe { OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, 0, id) };
        ensure!(!raw.is_null(), "opening the app's process: {}", std::io::Error::last_os_error());
        // SAFETY: `raw` is a valid handle owned by this value from now on.
        let process = Self(unsafe { OwnedHandle::from_raw_handle(raw) });
        ensure!(!process.wait(Duration::ZERO)?, "the app has already quit");
        Ok(process)
    }

    /// Whether it exited within `timeout`.
    pub fn wait(&self, timeout: Duration) -> Result<bool> {
        // SAFETY: the handle stays open for the call.
        match unsafe { WaitForSingleObject(self.0.as_raw_handle(), millis(timeout)) } {
            WAIT_OBJECT_0 => Ok(true),
            WAIT_TIMEOUT => Ok(false),
            _ => bail!("waiting for a process: {}", std::io::Error::last_os_error()),
        }
    }

    /// Its exit code, once it has exited.
    pub fn exit_code(&self) -> Result<u32> {
        let mut code = 0;
        // SAFETY: the handle stays open and `code` outlives the call.
        let read = unsafe { GetExitCodeProcess(self.0.as_raw_handle(), &mut code) };
        ensure!(read != 0, "reading an exit code: {}", std::io::Error::last_os_error());
        Ok(code)
    }
}

/// Starts `executable` with `parameters` through the shell, as administrator
/// when `elevate` is set. The administrator prompt is answered before this
/// returns; declining it is an error.
pub fn launch(executable: &Path, parameters: &OsStr, elevate: bool) -> Result<Process> {
    let file = wide(executable);
    let parameters = wide(parameters);
    let verb = wide(if elevate { "runas" } else { "open" });
    let mut info = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI,
        lpVerb: verb.as_ptr(),
        lpFile: file.as_ptr(),
        lpParameters: parameters.as_ptr(),
        nShow: SW_HIDE,
        ..Default::default()
    };
    // SAFETY: every pointer in `info` outlives this synchronous call.
    if unsafe { ShellExecuteExW(&mut info) } == 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_CANCELLED as i32) {
            bail!("administrator approval for the update was declined");
        }
        bail!("starting the installer helper: {error}");
    }
    ensure!(!info.hProcess.is_null(), "Windows returned no installer helper process");
    // SAFETY: SEE_MASK_NOCLOSEPROCESS hands this process handle to us.
    Ok(Process(unsafe { OwnedHandle::from_raw_handle(info.hProcess) }))
}

/// Starts `program` with `arguments` in `dir`, independent of this process:
/// it inherits no handle (a pipe its starter reads to the end must not stay
/// open with it), has no console window, and leaves any job this process
/// runs in, as some launchers put the app in one, when the job allows that.
pub fn spawn(program: &Path, arguments: &[&OsStr], dir: &Path) -> Result<Process> {
    let mut line = quoted(program.as_os_str());
    for argument in arguments {
        line.push(" ");
        line.push(quoted(argument));
    }
    let mut line = wide(&line);
    let (program_w, dir_w) = (wide(program), wide(dir));
    let startup = STARTUPINFOW {
        cb: std::mem::size_of::<STARTUPINFOW>() as u32,
        ..Default::default()
    };
    let detached = CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW;
    for flags in [detached | CREATE_BREAKAWAY_FROM_JOB, detached] {
        let mut info = PROCESS_INFORMATION::default();
        // SAFETY: every string is terminated and outlives the call, `line` is
        // writable as CreateProcessW requires, and handles are not inherited.
        let created = unsafe {
            CreateProcessW(
                program_w.as_ptr(),
                line.as_mut_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                flags,
                std::ptr::null(),
                dir_w.as_ptr(),
                &startup,
                &mut info,
            )
        };
        if created != 0 {
            // SAFETY: CreateProcessW handed us both handles; the thread's is
            // not needed.
            drop(unsafe { OwnedHandle::from_raw_handle(info.hThread) });
            // SAFETY: as above, the process handle is ours from now on.
            return Ok(Process(unsafe { OwnedHandle::from_raw_handle(info.hProcess) }));
        }
    }
    bail!("starting {}: {}", program.display(), std::io::Error::last_os_error())
}

/// `value` as one command-line argument. Windows paths cannot contain
/// quotes; trailing backslashes are doubled so they do not escape the
/// closing quote.
fn quoted(value: &OsStr) -> OsString {
    let units: Vec<u16> = value.encode_wide().collect();
    let trailing = units
        .iter()
        .rev()
        .take_while(|&&unit| unit == u16::from(b'\\'))
        .count();
    let mut quoted = OsString::from("\"");
    quoted.push(value);
    quoted.push("\\".repeat(trailing));
    quoted.push("\"");
    quoted
}

/// Held while one update owns a copy of the app; dropped, it lets the next
/// one go ahead.
pub struct Exclusive(OwnedHandle);

/// Waits up to `patience` to own the lock `name`. An owner that died
/// without letting go counts as gone.
pub fn exclusive(name: &str, patience: Duration) -> Result<Exclusive> {
    let name = wide(name);
    // SAFETY: `name` outlives the call; default security and no initial
    // owner are allowed.
    let raw = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
    ensure!(!raw.is_null(), "creating the update lock: {}", std::io::Error::last_os_error());
    // SAFETY: `raw` is a valid handle owned by this value from now on.
    let handle = unsafe { OwnedHandle::from_raw_handle(raw) };
    // SAFETY: the handle stays open for the call.
    match unsafe { WaitForSingleObject(handle.as_raw_handle(), millis(patience)) } {
        WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(Exclusive(handle)),
        WAIT_TIMEOUT => bail!("another update of this copy of POCOX is still in progress"),
        _ => bail!("taking the update lock: {}", std::io::Error::last_os_error()),
    }
}

impl Drop for Exclusive {
    fn drop(&mut self) {
        // SAFETY: this thread owns the mutex (taken in `exclusive`), and the
        // handle is still open.
        unsafe { ReleaseMutex(self.0.as_raw_handle()) };
    }
}

/// Shows `message` in a message box and waits for it to be dismissed.
pub fn alert(message: &str) {
    let (text, caption) = (wide(message), wide("POCOX"));
    // SAFETY: both strings outlive the call; no owner window is allowed.
    unsafe {
        MessageBoxW(std::ptr::null_mut(), text.as_ptr(), caption.as_ptr(), MB_OK | MB_ICONERROR)
    };
}
