use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
};

use base64::Engine as _;
use ring::{
    rand::SystemRandom,
    signature::{Ed25519KeyPair, KeyPair},
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::{
    manifest::{self, Host, Install, Method},
    Config, Kind, Phase, Updater,
};

struct Key {
    pair: Ed25519KeyPair,
}

impl Key {
    fn new() -> Self {
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).expect("key");
        Self {
            pair: Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).expect("key"),
        }
    }

    fn public(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.pair.public_key().as_ref())
    }

    fn sign(&self, bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.pair.sign(bytes).as_ref())
    }
}

fn sha256(bytes: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, bytes)
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn manifest_for(version: &str, assets: &[(&str, &[u8])]) -> Vec<u8> {
    let assets: Vec<_> = assets
        .iter()
        .map(|(name, bytes)| {
            serde_json::json!({ "name": name, "size": bytes.len(), "sha256": sha256(bytes) })
        })
        .collect();
    serde_json::to_vec(&serde_json::json!({ "version": version, "assets": assets })).expect("json")
}

/// A release copy served over HTTP, counting requests.
struct Feed {
    url: String,
    files: Arc<std::sync::Mutex<HashMap<String, Vec<u8>>>>,
    hits: Arc<AtomicUsize>,
}

impl Feed {
    async fn start() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let url = format!("http://{}/", listener.local_addr().expect("addr"));
        let files: Arc<std::sync::Mutex<HashMap<String, Vec<u8>>>> = Arc::default();
        let hits = Arc::new(AtomicUsize::new(0));
        let (served, counted) = (files.clone(), hits.clone());
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let (files, hits) = (served.clone(), counted.clone());
                tokio::spawn(async move {
                    let mut request = vec![0u8; 4096];
                    let read = socket.read(&mut request).await.unwrap_or(0);
                    let line = String::from_utf8_lossy(&request[..read]);
                    let path = line
                        .split_whitespace()
                        .nth(1)
                        .unwrap_or("/")
                        .trim_start_matches('/')
                        .to_string();
                    hits.fetch_add(1, Ordering::SeqCst);
                    let body = files.lock().expect("files").get(&path).cloned();
                    let (status, body) = match body {
                        Some(body) => ("200 OK", body),
                        None => ("404 Not Found", Vec::new()),
                    };
                    let head = format!(
                        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = socket.write_all(head.as_bytes()).await;
                    let _ = socket.write_all(&body).await;
                });
            }
        });
        Self {
            url,
            files,
            hits,
        }
    }

    fn put(&self, name: &str, bytes: Vec<u8>) {
        self.files.lock().expect("files").insert(name.into(), bytes);
    }

    fn publish(&self, key: &Key, manifest: Vec<u8>) {
        self.put("release-manifest.json.sig", key.sign(&manifest).into_bytes());
        self.put("release-manifest.json", manifest);
    }
}

const PORTABLE_LINUX: Host = Host {
    install: Install::Portable,
    arch: "x86_64",
};

fn updater(feed: &Feed, key: &Key, dir: PathBuf, current: &str) -> Updater {
    Updater::new(
        Config {
            current: semver::Version::parse(current).expect("version"),
            feed: Some(feed.url.clone()),
            public_key: key.public(),
            replace_self: true,
        },
        PORTABLE_LINUX,
        move || Some(dir.clone()),
    )
}

#[test]
fn only_the_release_key_vouches_for_a_manifest() {
    let (key, other) = (Key::new(), Key::new());
    let manifest = manifest_for("1.2.3", &[("pocket-codex-app-v1.2.3-linux-x64.zip", b"zip")]);
    let release = manifest::verify(&manifest, &key.sign(&manifest), &key.public()).expect("signed");
    assert_eq!(release.version, semver::Version::new(1, 2, 3));

    assert!(manifest::verify(&manifest, &other.sign(&manifest), &key.public()).is_err());
    let mut tampered = manifest.clone();
    tampered[2] ^= 1;
    assert!(manifest::verify(&tampered, &key.sign(&manifest), &key.public()).is_err());
    // Even a signed manifest may not name a file outside the download folder.
    let escaping = manifest_for("1.2.3", &[("../pocket-codex-app-x.zip", b"zip")]);
    assert!(manifest::verify(&escaping, &key.sign(&escaping), &key.public()).is_err());
}

#[test]
fn each_installation_takes_its_own_file() {
    let names = [
        "pocket-codex-app-v1.0.0-macos-arm64.dmg",
        "pocket-codex-app-v1.0.0-macos-x64.dmg",
        "pocket-codex-app-v1.0.0-windows-x64-setup.exe",
        "pocket-codex-app-v1.0.0-linux-x86_64.AppImage",
        "pocket-codex-app-v1.0.0-android-armeabi-v7a.apk",
    ];
    let assets: Vec<(&str, &[u8])> = names.iter().map(|name| (*name, &b"x"[..])).collect();
    let release = manifest::Manifest::parse(&manifest_for("1.0.0", &assets)).expect("manifest");
    let pick = |install, arch| {
        let plan = manifest::plan(&release, Host {
            install,
            arch,
        });
        (plan.method, plan.asset.map(|asset| asset.name))
    };
    assert_eq!(pick(Install::MacBundle, "aarch64"), (Method::ReplaceBundle, Some(names[0].into())));
    assert_eq!(
        pick(Install::WindowsInstalled, "x86_64"),
        (Method::Installer, Some(names[2].into()))
    );
    assert_eq!(pick(Install::Android, "arm"), (Method::SystemInstaller, Some(names[4].into())));
    // Nothing built for it, or nothing an app can install there.
    assert_eq!(pick(Install::Android, "aarch64"), (Method::ReleasePage, None));
    assert_eq!(pick(Install::Ios, "aarch64"), (Method::ReleasePage, None));
}

#[tokio::test]
async fn a_newer_release_downloads_only_as_the_manifest_names_it() {
    let (feed, key) = (Feed::start().await, Key::new());
    let dir = tempfile::tempdir().expect("dir");
    let name = "pocket-codex-app-v0.7.0-linux-x64.zip";
    let package = b"the real package".to_vec();
    feed.publish(&key, manifest_for("0.7.0", &[(name, &package)]));
    // Served bytes that differ from what the manifest names.
    feed.put(name, b"a substituted package".to_vec());

    let update = updater(&feed, &key, dir.path().into(), "0.6.0");
    let found = update.check(true).await;
    assert_eq!(found.phase, Phase::Available);
    assert_eq!(found.latest.as_deref(), Some("0.7.0"));
    assert_eq!(found.method, Method::SaveDownload);

    let refused = update.download().await;
    assert_eq!(refused.phase, Phase::Failed);
    assert_eq!(refused.failure.map(|f| f.kind), Some(Kind::Checksum));
    assert!(!dir
        .path()
        .join("work")
        .read_dir()
        .expect("work")
        .any(|_| true));

    feed.put(name, package.clone());
    let ready = update.download().await;
    assert_eq!(ready.phase, Phase::Ready);
    assert_eq!(ready.received, package.len() as u64);
}

#[tokio::test]
async fn an_unsigned_release_is_never_offered() {
    let (feed, key, other) = (Feed::start().await, Key::new(), Key::new());
    let dir = tempfile::tempdir().expect("dir");
    let package = b"zip".to_vec();
    feed.publish(
        &other,
        manifest_for("9.0.0", &[("pocket-codex-app-v9.0.0-linux-x64.zip", &package)]),
    );

    let update = updater(&feed, &key, dir.path().into(), "0.6.0");
    // In the background a failure only records why.
    let quiet = update.check(false).await;
    assert_eq!(quiet.phase, Phase::Idle);
    assert_eq!(quiet.failure.as_ref().map(|f| f.kind), Some(Kind::Signature));
    assert_eq!(quiet.latest, None);
    let asked = update.check(true).await;
    assert_eq!(asked.phase, Phase::Failed);
    assert_eq!(update.download().await.phase, Phase::Failed);
}

#[tokio::test]
async fn background_checks_stay_rare_and_survive_a_restart() {
    let (feed, key) = (Feed::start().await, Key::new());
    let dir = tempfile::tempdir().expect("dir");
    let package = b"zip".to_vec();
    feed.publish(
        &key,
        manifest_for("0.7.0", &[("pocket-codex-app-v0.7.0-linux-x64.zip", &package)]),
    );

    let first = updater(&feed, &key, dir.path().into(), "0.6.0");
    assert_eq!(first.check(false).await.phase, Phase::Available);
    first.announce("0.7.0".into());
    let asked = feed.hits.load(Ordering::SeqCst);
    assert_eq!(first.check(false).await.phase, Phase::Available);
    assert_eq!(feed.hits.load(Ordering::SeqCst), asked, "a fresh answer is reused");

    // The next start offers the release at once, from the saved answer.
    let restarted = updater(&feed, &key, dir.path().into(), "0.6.0");
    let snapshot = restarted.snapshot();
    assert_eq!(snapshot.phase, Phase::Available);
    assert_eq!(snapshot.announced.as_deref(), Some("0.7.0"));
    assert_eq!(feed.hits.load(Ordering::SeqCst), asked);
    // Once it is installed, the same answer means up to date.
    let updated = updater(&feed, &key, dir.path().into(), "0.7.0");
    assert_eq!(updated.snapshot().phase, Phase::UpToDate);
}
