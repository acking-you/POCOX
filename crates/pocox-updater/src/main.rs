//! `pocox-updater`: puts a verified POCOX release in place once the app has
//! quit, then reopens it (Windows, built with the `handoff` feature). The app
//! runs `--prepare <request.json>` and quits only after it succeeds; see the
//! library for the handoff.
#![cfg_attr(windows, windows_subsystem = "windows")]
#![forbid(unsafe_code)]

fn main() {
    #[cfg(all(windows, feature = "handoff"))]
    if let Err(error) = pocox_updater::run(std::env::args_os().skip(1)) {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
    #[cfg(not(all(windows, feature = "handoff")))]
    {
        eprintln!("pocox-updater applies Windows updates, built with its `handoff` feature");
        std::process::exit(1);
    }
}
