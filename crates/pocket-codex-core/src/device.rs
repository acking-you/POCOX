//! Publisher metadata. Relay device names are labels, not proof of locality.

use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

/// The environment that actually owns a registered service.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceMetadata {
    /// Metadata schema version, independent of the management protocol.
    pub protocol: u32,
    /// OS of the publisher executable (`windows`, `linux`, `macos`, etc.).
    pub os: String,
    /// Architecture of the publisher executable.
    pub arch: String,
    /// Runtime environment (`wsl` on Windows Subsystem for Linux).
    pub environment: Option<String>,
    /// Display hostname, which may be shared by independent environments.
    pub hostname: String,
    /// Opaque identity of this publisher process; renewed on restart.
    ///
    /// Correlates this process's service responses. Local ownership still
    /// comes from the native host registry; metadata never grants access.
    pub instance_id: String,
}

impl DeviceMetadata {
    /// Metadata shared by every service owned by this process.
    pub fn current() -> &'static Self {
        static VALUE: OnceLock<DeviceMetadata> = OnceLock::new();
        VALUE.get_or_init(|| Self {
            protocol: 1,
            os: std::env::consts::OS.into(),
            arch: std::env::consts::ARCH.into(),
            environment: environment(
                std::env::consts::OS,
                &std::fs::read_to_string("/proc/sys/kernel/osrelease").unwrap_or_default(),
            ),
            hostname: sysinfo::System::host_name().unwrap_or_default(),
            instance_id: uuid::Uuid::new_v4().to_string(),
        })
    }
}

fn environment(os: &str, kernel_release: &str) -> Option<String> {
    (os == "linux" && kernel_release.to_ascii_lowercase().contains("microsoft"))
        .then(|| "wsl".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_and_wsl_are_distinct_even_with_the_same_hostname() {
        assert_eq!(environment("windows", "Microsoft Windows"), None);
        assert_eq!(environment("linux", "6.6.87.2-microsoft-standard-WSL2"), Some("wsl".into()));
        assert_eq!(environment("linux", "5.15.153.1-Microsoft"), Some("wsl".into()));
        assert_eq!(environment("linux", "6.8.0-generic"), None);
        assert_eq!(environment("macos", ""), None);
    }

    #[test]
    fn services_share_one_process_identity_and_ignore_future_fields() {
        let first = DeviceMetadata::current();
        assert_eq!(first, DeviceMetadata::current());
        assert_eq!(first.os, std::env::consts::OS);
        assert!(uuid::Uuid::parse_str(&first.instance_id).is_ok());
        let mut json = serde_json::to_value(first).expect("metadata");
        json["future"] = true.into();
        assert_eq!(serde_json::from_value::<DeviceMetadata>(json).expect("future peer"), *first);
    }
}
