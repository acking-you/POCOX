//! What a release offers, as its signed manifest describes it, and which of
//! its files this installation takes.
//!
//! The release workflow lists every asset's size and SHA-256 in
//! `release-manifest.json` and signs those exact bytes with the release key
//! (`scripts/release_manifest.py`). Nothing is fetched from a release until
//! that signature checks out, and nothing fetched is used unless it is
//! exactly the file the manifest names.
use anyhow::{anyhow, bail, Context, Result};
use base64::Engine as _;
use ring::signature::{UnparsedPublicKey, ED25519};
use serde::Deserialize;

/// The repository whose releases are this app's updates.
pub const REPOSITORY: &str = "acking-you/POCOX";

/// The Ed25519 key release manifests are signed with (raw, base64). The
/// private half lives only in the repository's `UPDATE_SIGNING_KEY` secret
/// and the maintainer's backup; `scripts/update_signing_key.pub.pem` is the
/// same key for the release workflow's own check.
pub const PUBLIC_KEY: &str = "RorQcOAKbkiQRvkqSmFEnx89Do8PdVamnPGWY8+Wtqk=";

/// The manifest's file name in every release.
pub const MANIFEST_NAME: &str = "release-manifest.json";
/// Its detached signature: base64 of the 64-byte signature.
pub const SIGNATURE_NAME: &str = "release-manifest.json.sig";

/// One downloadable file of a release.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Asset {
    /// A plain file name: a path segment of its URL and a name on disk.
    pub name: String,
    /// Exact size in bytes.
    pub size: u64,
    /// Lower-case hex SHA-256.
    pub sha256: String,
}

/// A release's manifest, trusted only once [`verify`] accepted it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    /// The app version (`0.6.0`), its tag without the `v`.
    pub version: semver::Version,
    /// Every file of the release.
    pub assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Wire {
    version: String,
    assets: Vec<Asset>,
}

impl Manifest {
    /// Parses a manifest's text, before it is trusted; used only to learn
    /// which release's signature to fetch.
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        let wire: Wire = serde_json::from_slice(bytes).context("malformed release manifest")?;
        let version = semver::Version::parse(&wire.version)
            .with_context(|| format!("release manifest version `{}`", wire.version))?;
        for asset in &wire.assets {
            let plain = !asset.name.is_empty()
                && asset
                    .name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
                && !asset.name.starts_with('.');
            if !plain {
                bail!("release asset `{}` is not a plain file name", asset.name);
            }
            let hex = asset.sha256.len() == 64
                && asset
                    .sha256
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
            if !hex {
                bail!("release asset `{}` has a malformed hash", asset.name);
            }
        }
        Ok(Self {
            version,
            assets: wire.assets,
        })
    }
}

/// The page of the release tagged `v<version>`, or of every release.
pub fn release_page(version: Option<&semver::Version>) -> String {
    match version {
        Some(version) => format!("https://github.com/{REPOSITORY}/releases/tag/v{version}"),
        None => format!("https://github.com/{REPOSITORY}/releases/latest"),
    }
}

/// Parses `manifest` only if `signature` (base64) is a valid Ed25519
/// signature of its exact bytes by `public_key` (raw, base64).
pub fn verify(manifest: &[u8], signature: &str, public_key: &str) -> Result<Manifest> {
    let engine = base64::engine::general_purpose::STANDARD;
    let signature = engine
        .decode(signature.trim())
        .map_err(|_| anyhow!("the release signature is not base64"))?;
    let key = engine
        .decode(public_key.trim())
        .map_err(|_| anyhow!("the release key is not base64"))?;
    if signature.len() != 64 || key.len() != 32 {
        bail!("the release signature does not match");
    }
    UnparsedPublicKey::new(&ED25519, &key)
        .verify(manifest, &signature)
        .map_err(|_| anyhow!("the release signature does not match"))?;
    Manifest::parse(manifest)
}

/// How an update reaches this installation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    /// Swap the application bundle once the app has quit, then reopen it
    /// (macOS).
    ReplaceBundle,
    /// Run the installer quietly once the app has quit, then reopen it
    /// (Windows, installed).
    Installer,
    /// Swap the AppImage file once the app has quit, then reopen it (Linux).
    ReplaceAppImage,
    /// Hand the package to the desktop's package installer (Linux `.deb`).
    OpenPackage,
    /// Save the archive to Downloads for the user to unpack (portable
    /// Windows and Linux).
    SaveDownload,
    /// Hand the package to the system installer, which asks the user
    /// (Android).
    SystemInstaller,
    /// Nothing this app can install: open the release page (iOS, or a
    /// release without a file for this device).
    ReleasePage,
}

impl Method {
    /// The wire name the app branches on.
    pub fn name(self) -> &'static str {
        match self {
            Self::ReplaceBundle => "replace_bundle",
            Self::Installer => "installer",
            Self::ReplaceAppImage => "replace_app_image",
            Self::OpenPackage => "open_package",
            Self::SaveDownload => "save_download",
            Self::SystemInstaller => "system_installer",
            Self::ReleasePage => "release_page",
        }
    }

    /// Whether applying it ends with this app quitting.
    pub fn restarts(self) -> bool {
        matches!(self, Self::ReplaceBundle | Self::Installer | Self::ReplaceAppImage)
    }
}

/// How this copy of the app was installed, as far as updating it goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Install {
    /// A macOS application bundle.
    MacBundle,
    /// Set up by the Windows installer (its uninstaller sits beside the
    /// executable).
    WindowsInstalled,
    /// Unpacked from a portable archive.
    Portable,
    /// Running from an AppImage.
    AppImage,
    /// Installed from the Debian package.
    Deb,
    /// An Android package.
    Android,
    /// iOS: sideloaded, nothing to install from here.
    Ios,
}

/// This installation: what it is and which CPU it runs on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Host {
    /// How it was installed.
    pub install: Install,
    /// `std::env::consts::ARCH` of this build.
    pub arch: &'static str,
}

/// The file to fetch and how to apply it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    /// How the update applies.
    pub method: Method,
    /// The file, unless the method is [`Method::ReleasePage`].
    pub asset: Option<Asset>,
}

/// The file of `manifest` meant for `host`; the release page when the
/// release has none for it.
pub fn plan(manifest: &Manifest, host: Host) -> Plan {
    let (suffix, method) = match (host.install, host.arch) {
        (Install::MacBundle, "aarch64") => ("-macos-arm64.dmg", Method::ReplaceBundle),
        (Install::MacBundle, "x86_64") => ("-macos-x64.dmg", Method::ReplaceBundle),
        (Install::WindowsInstalled, "x86_64") => ("-windows-x64-setup.exe", Method::Installer),
        (Install::Portable, "x86_64") if cfg!(windows) => {
            ("-windows-x64.zip", Method::SaveDownload)
        },
        (Install::Portable, "x86_64") => ("-linux-x64.zip", Method::SaveDownload),
        (Install::AppImage, "x86_64") => ("-linux-x86_64.AppImage", Method::ReplaceAppImage),
        (Install::Deb, "x86_64") => ("-linux-amd64.deb", Method::OpenPackage),
        (Install::Android, "aarch64") => ("-android-arm64-v8a.apk", Method::SystemInstaller),
        (Install::Android, "arm") => ("-android-armeabi-v7a.apk", Method::SystemInstaller),
        (Install::Android, "x86_64") => ("-android-x86_64.apk", Method::SystemInstaller),
        _ => return release_page_plan(),
    };
    let mut matching = manifest
        .assets
        .iter()
        .filter(|asset| asset.name.starts_with("pocox-app-") && asset.name.ends_with(suffix));
    match (matching.next(), matching.next()) {
        (Some(asset), None) => Plan {
            method,
            asset: Some(asset.clone()),
        },
        _ => release_page_plan(),
    }
}

fn release_page_plan() -> Plan {
    Plan {
        method: Method::ReleasePage,
        asset: None,
    }
}
