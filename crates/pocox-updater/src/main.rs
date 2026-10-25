//! `pocox-updater`: puts a verified POCOX release in place once the app has
//! quit, then reopens it (Windows). The app runs `--prepare <request.json>`
//! and quits only after it succeeds; see the library for the handoff.
#![cfg_attr(windows, windows_subsystem = "windows")]

fn main() {
    #[cfg(windows)]
    if let Err(error) = pocox_updater::run(std::env::args_os().skip(1)) {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
    #[cfg(not(windows))]
    {
        eprintln!("pocox-updater applies Windows updates only");
        std::process::exit(1);
    }
}
