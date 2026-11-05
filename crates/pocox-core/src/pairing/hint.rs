//! The optional hardware hint: finds a candidate device when the user asks to
//! recover, and never authorizes anything.
//!
//! ```text
//! hardware_key = HMAC-SHA256(
//!     key = raw_id,
//!     msg = encode("pocox.device.v1", source, os_account, environment,
//!                  canonical_backend, POCOX_DEVICE_SCOPE))
//! ```
//!
//! The raw identifier never leaves the device. Read it only at activation or
//! for an explicit recovery request. `unsafe` stays forbidden, so desktop
//! sources come from the system's own tools; Linux, WSL and containers have no
//! source, and mobile sources arrive through the bridge.

use base64::Engine as _;
use hmac::{Hmac, Mac};
use sha2::Sha256;

use super::store::StoreKey;
use super::tuple::encode_tuple;
use crate::provider::Secret;

const DOMAIN: &str = "pocox.device.v1";

/// Firmware placeholders and well-known shared values, normalized.
const PLACEHOLDERS: &[&str] = &[
    "03000200-0400-0500-0006-000700080009",
    "00020003-0004-0005-0006-000700080009",
    "12345678-1234-5678-90ab-cddeefaabbcc",
    "to be filled by o.e.m.",
    "default string",
    "not settable",
    "not specified",
    "system uuid",
    "none",
    "unknown",
    // The value many Android 2.2 devices shared.
    "9774d56d682e549c",
];

/// Where a raw hardware identifier came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HintSource {
    /// macOS `IOPlatformUUID`.
    MacosPlatformUuid,
    /// The Windows SMBIOS UUID.
    WindowsSmbiosUuid,
    /// The Windows `MachineGuid`, when the firmware's UUID is a placeholder.
    WindowsMachineGuid,
    /// Android's `ANDROID_ID`, supplied through the bridge.
    AndroidId,
}

impl HintSource {
    /// The label the derivation binds and the backend records.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::MacosPlatformUuid => "macos_platform_uuid",
            Self::WindowsSmbiosUuid => "windows_smbios_uuid",
            Self::WindowsMachineGuid => "windows_machine_guid",
            Self::AndroidId => "android_id",
        }
    }

    /// The source a platform adapter names, or `None` for one this build does
    /// not know: an unknown source produces no hint at all.
    pub fn from_label(label: &str) -> Option<Self> {
        [
            Self::MacosPlatformUuid,
            Self::WindowsSmbiosUuid,
            Self::WindowsMachineGuid,
            Self::AndroidId,
        ]
        .into_iter()
        .find(|source| source.as_str() == label)
    }
}

/// A usable raw identifier. Its value is not printable through `Debug` or logs.
#[derive(Debug, Clone)]
pub struct RawHardwareId {
    source: HintSource,
    value: Secret,
}

impl RawHardwareId {
    /// `value` from `source`, or `None` for an empty value or a placeholder.
    pub fn new(source: HintSource, value: &str) -> Option<Self> {
        let normalized = value.trim().to_ascii_lowercase();
        usable(&normalized).then(|| Self {
            source,
            value: Secret::new(normalized),
        })
    }

    /// Where it came from.
    pub fn source(&self) -> HintSource {
        self.source
    }
}

fn usable(normalized: &str) -> bool {
    let digits: Vec<char> = normalized.chars().filter(|ch| *ch != '-').collect();
    let repeats = digits
        .first()
        .is_some_and(|first| digits.iter().all(|ch| ch == first));
    !digits.is_empty() && !repeats && !PLACEHOLDERS.contains(&normalized)
}

/// A hardware key ready for the wire. Holds nothing that reverses to the raw
/// identifier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DerivedHint {
    /// The 32-byte key in unpadded base64url.
    pub key: String,
    /// The informational source label.
    pub source: &'static str,
}

/// Derive this device's hardware key for one backend, environment and scope.
pub fn derive_hint(raw: &RawHardwareId, key: &StoreKey, os_account: &str) -> DerivedHint {
    let message = encode_tuple(&[
        DOMAIN.as_bytes(),
        raw.source.as_str().as_bytes(),
        os_account.as_bytes(),
        key.environment().as_bytes(),
        key.backend().as_bytes(),
        key.scope().unwrap_or_default().as_bytes(),
    ]);
    let mut mac = Hmac::<Sha256>::new_from_slice(raw.value.expose().as_bytes())
        .expect("HMAC accepts a key of any length");
    mac.update(&message);
    DerivedHint {
        key: base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()),
        source: raw.source.as_str(),
    }
}

/// The OS account this process runs as, which the derivation binds.
///
/// Constant on Android, whose `ANDROID_ID` is already per user and whose app
/// uid can change on the reinstall a hint exists to survive.
pub fn os_account() -> String {
    #[cfg(target_os = "android")]
    {
        "android".to_string()
    }
    #[cfg(all(unix, not(target_os = "android")))]
    {
        nix::unistd::getuid().as_raw().to_string()
    }
    #[cfg(windows)]
    {
        let part = |name: &str| std::env::var(name).unwrap_or_default().to_ascii_lowercase();
        format!("{}\\{}", part("USERDOMAIN"), part("USERNAME"))
    }
}

/// Read this desktop's hardware identifier from the system's own tools, or
/// `None` where there is no source or it yields only a placeholder. Blocks for
/// a few seconds at worst; call it only at activation or for an explicit
/// recovery request.
pub fn read_local_hardware_id() -> Option<RawHardwareId> {
    #[cfg(target_os = "macos")]
    {
        let output =
            tools::run("/usr/sbin/ioreg", &["-rd1", "-c", "IOPlatformExpertDevice"]).ok()?;
        RawHardwareId::new(HintSource::MacosPlatformUuid, &parse_ioreg(&output)?)
    }
    #[cfg(windows)]
    {
        windows::read()
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        None
    }
}

/// The `IOPlatformUUID` in `ioreg` output.
#[cfg(any(target_os = "macos", test))]
fn parse_ioreg(output: &str) -> Option<String> {
    let line = output
        .lines()
        .find(|line| line.contains("\"IOPlatformUUID\""))?;
    let (_, value) = line.split_once('=')?;
    Some(value.trim().trim_matches('"').to_string())
}

/// The `MachineGuid` value in `reg query` output.
#[cfg(any(windows, test))]
fn parse_reg_query(output: &str) -> Option<String> {
    let line = output.lines().find(|line| line.contains("MachineGuid"))?;
    line.split_whitespace().last().map(str::to_string)
}

/// Why a system tool gave no output.
#[cfg(any(target_os = "macos", windows, test))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ToolFailure {
    /// It could not run or reported failure: its answer is simply not there.
    Unusable,
    /// It outlasted the wait, which says nothing about what it would have said.
    TimedOut,
}

#[cfg(any(target_os = "macos", windows))]
pub(super) mod tools {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    use super::ToolFailure;

    const WAIT: Duration = Duration::from_secs(5);

    /// Stdout of a system tool named by absolute path, so `PATH` cannot choose
    /// what runs.
    pub(in crate::pairing) fn run(program: &str, args: &[&str]) -> Result<String, ToolFailure> {
        let mut command = Command::new(program);
        command
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt as _;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            command.creation_flags(CREATE_NO_WINDOW);
        }
        let mut child = command.spawn().map_err(|_| ToolFailure::Unusable)?;
        let deadline = Instant::now() + WAIT;
        loop {
            match child.try_wait().map_err(|_| ToolFailure::Unusable)? {
                Some(status) if status.success() => break,
                Some(_) => return Err(ToolFailure::Unusable),
                None if Instant::now() >= deadline => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(ToolFailure::TimedOut);
                },
                None => std::thread::sleep(Duration::from_millis(20)),
            }
        }
        let mut output = String::new();
        let mut stdout = child.stdout.take().ok_or(ToolFailure::Unusable)?;
        std::io::Read::read_to_string(&mut stdout, &mut output)
            .map_err(|_| ToolFailure::Unusable)?;
        Ok(output)
    }
}

/// The firmware's UUID when it is real, else the installation's GUID. A
/// firmware answer that merely took too long stays unknown: falling back then
/// would send a different key from the one this device bound.
#[cfg(any(windows, test))]
fn windows_identifier(
    smbios: Result<String, ToolFailure>,
    machine_guid: impl FnOnce() -> Result<String, ToolFailure>,
) -> Option<RawHardwareId> {
    let firmware = match smbios {
        Err(ToolFailure::TimedOut) => return None,
        Err(ToolFailure::Unusable) => None,
        Ok(output) => RawHardwareId::new(HintSource::WindowsSmbiosUuid, &output),
    };
    firmware.or_else(|| {
        let output = machine_guid().ok()?;
        RawHardwareId::new(HintSource::WindowsMachineGuid, &parse_reg_query(&output)?)
    })
}

#[cfg(windows)]
mod windows {
    use super::{tools, windows_identifier, RawHardwareId};

    fn system32(tool: &str) -> String {
        let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_string());
        format!("{root}\\System32\\{tool}")
    }

    pub(super) fn read() -> Option<RawHardwareId> {
        let smbios = tools::run(&system32("WindowsPowerShell\\v1.0\\powershell.exe"), &[
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "(Get-CimInstance -ClassName Win32_ComputerSystemProduct).UUID",
        ]);
        windows_identifier(smbios, || {
            tools::run(&system32("reg.exe"), &[
                "query",
                "HKLM\\SOFTWARE\\Microsoft\\Cryptography",
                "/v",
                "MachineGuid",
            ])
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pairing::CanonicalBackend;

    fn key(backend: &str, scope: Option<&str>) -> StoreKey {
        StoreKey::new(
            &CanonicalBackend::parse(backend).expect("backend"),
            "macos-native",
            scope.map(str::to_string),
        )
    }

    #[test]
    fn a_slow_firmware_answer_never_becomes_another_hardware_key() {
        let guid = "HKEY\n    MachineGuid    REG_SZ    11111111-2222-3333-4444-555555555555\n";
        let timed_out = windows_identifier(Err(ToolFailure::TimedOut), || panic!("not asked"));
        assert!(timed_out.is_none());
        let unusable = windows_identifier(Err(ToolFailure::Unusable), || Ok(guid.to_string()));
        assert_eq!(unusable.expect("the guid").source(), HintSource::WindowsMachineGuid);
        let placeholder =
            windows_identifier(Ok("00000000-0000-0000-0000-000000000000".into()), || {
                Ok(guid.to_string())
            });
        assert_eq!(placeholder.expect("the guid").source(), HintSource::WindowsMachineGuid);
    }

    #[test]
    fn placeholders_and_empty_values_are_no_identifier() {
        for value in [
            "",
            "   ",
            "00000000-0000-0000-0000-000000000000",
            "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            "03000200-0400-0500-0006-000700080009",
            "To Be Filled By O.E.M.",
            "9774d56d682e549c",
        ] {
            assert!(RawHardwareId::new(HintSource::WindowsSmbiosUuid, value).is_none(), "{value}");
        }
        assert!(RawHardwareId::new(
            HintSource::MacosPlatformUuid,
            "564D1234-AAAA-BBBB-CCCC-0123456789AB"
        )
        .is_some());
    }

    #[test]
    fn a_key_is_bound_to_its_backend_scope_account_and_source() {
        let raw = RawHardwareId::new(HintSource::MacosPlatformUuid, "564D1234-AAAA-BBBB-CCCC-01")
            .expect("raw");
        let base = key("https://one.example", None);
        let derived = derive_hint(&raw, &base, "501");
        assert_eq!(derived.source, "macos_platform_uuid");
        assert!(!derived.key.to_ascii_lowercase().contains("564d1234"));
        assert_eq!(derived, derive_hint(&raw, &base, "501"), "a derivation is stable");
        // Case in the raw identifier is the tool's spelling, not a new machine.
        let shouted =
            RawHardwareId::new(HintSource::MacosPlatformUuid, "564d1234-aaaa-bbbb-cccc-01")
                .expect("raw");
        assert_eq!(derived, derive_hint(&shouted, &base, "501"));
        for other in [
            derive_hint(&raw, &key("https://two.example", None), "501"),
            derive_hint(&raw, &key("https://one.example", Some("test")), "501"),
            derive_hint(&raw, &base, "502"),
            derive_hint(
                &RawHardwareId::new(HintSource::WindowsMachineGuid, "564D1234-AAAA-BBBB-CCCC-01")
                    .expect("raw"),
                &base,
                "501",
            ),
        ] {
            assert_ne!(other.key, derived.key);
        }
    }

    #[test]
    fn tool_output_yields_the_identifier_or_nothing() {
        let ioreg = "+-o IOPlatformExpertDevice\n  {\n    \"IOPlatformSerialNumber\" = \"X\"\n    \
                     \"IOPlatformUUID\" = \"564D1234-AAAA\"\n  }\n";
        assert_eq!(parse_ioreg(ioreg).as_deref(), Some("564D1234-AAAA"));
        assert_eq!(parse_ioreg("nothing here"), None);
        let reg =
            "\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n    MachineGuid    \
             REG_SZ    1f2e3d4c-aaaa\r\n\r\n";
        assert_eq!(parse_reg_query(reg).as_deref(), Some("1f2e3d4c-aaaa"));
    }

    #[test]
    fn a_raw_identifier_does_not_print() {
        let raw = RawHardwareId::new(HintSource::AndroidId, "abcdef0123456789").expect("raw");
        assert!(!format!("{raw:?}").contains("abcdef0123456789"));
    }
}
