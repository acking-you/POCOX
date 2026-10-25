//! Bounded retention of controller services, independent of Flutter view
//! lifetime. The window serializes selections, never hosting or turn execution.
//! Protocol registries make the final idle check atomically with removing their
//! client.

use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use anyhow::{ensure, Result};
use pocox_core::config::{ConnectionEviction, ConnectionWindowConfig};

use super::session_engine::{self, Protocol};
use super::{config, meta, runtime, transport};

static WINDOW: LazyLock<Mutex<Window>> = LazyLock::new(Mutex::default);
static MAINTENANCE: std::sync::Once = std::sync::Once::new();

#[derive(Default)]
struct Window {
    epoch: u64,
    clock: u64,
    entries: Vec<Entry>,
    selected: Option<String>,
}

struct Entry {
    service: String,
    opened: u64,
    used: u64,
}

impl Window {
    fn connect(
        &mut self,
        service: String,
        port: u16,
        settings: ConnectionWindowConfig,
        epoch: u64,
    ) -> Result<()> {
        ensure!(transport::is_current(epoch), "the account or relay changed; reconnect");
        self.refresh();
        let already_retained = self.entries.iter().any(|entry| entry.service == service);
        session_engine::engine(&service).connect_in_epoch(service.clone(), port, epoch)?;
        ensure!(transport::is_current(epoch), "the account or relay changed; reconnect");
        if !already_retained && !self.trim(settings, &service, 1) {
            release(&service);
            anyhow::bail!(
                "connection window is full: running tasks or pending requests protect the \
                 retained services; increase the connection limit in Settings or wait for them to \
                 finish"
            );
        }
        self.touch(&service);
        Ok(())
    }

    fn refresh(&mut self) {
        let epoch = transport::epoch();
        if self.epoch != epoch {
            // Transport has already invalidated its own registries. Never close
            // by an old logical key here: it could now name a different account.
            self.entries.clear();
            self.selected = None;
            self.epoch = epoch;
        }
        self.entries.retain(|entry| {
            if session_engine::engine(&entry.service).is_connected(&entry.service) {
                true
            } else {
                release(&entry.service);
                false
            }
        });
    }

    fn touch(&mut self, service: &str) {
        self.clock += 1;
        if let Some(entry) = self
            .entries
            .iter_mut()
            .find(|entry| entry.service == service)
        {
            entry.used = self.clock;
        } else {
            self.entries.push(Entry {
                service: service.into(),
                opened: self.clock,
                used: self.clock,
            });
        }
        self.selected = Some(service.into());
    }

    fn candidates(&self, policy: ConnectionEviction, selected: &str) -> Vec<String> {
        let mut entries: Vec<_> = self
            .entries
            .iter()
            .filter(|entry| entry.service != selected)
            .collect();
        entries.sort_by_key(|entry| match policy {
            ConnectionEviction::Lru => entry.used,
            ConnectionEviction::Fifo => entry.opened,
        });
        entries
            .into_iter()
            .map(|entry| entry.service.clone())
            .collect()
    }

    fn trim(&mut self, settings: ConnectionWindowConfig, selected: &str, reserve: usize) -> bool {
        for candidate in self.candidates(settings.eviction, selected) {
            if self.entries.len() + reserve <= settings.capacity as usize {
                break;
            }
            if evict_idle(&candidate) {
                self.entries.retain(|entry| entry.service != candidate);
                meta::release_service(&candidate);
            }
        }
        self.entries.len() + reserve <= settings.capacity as usize
    }
}

fn evict_idle(service: &str) -> bool {
    match session_engine::protocol_of(service) {
        Protocol::CodexAppServer => super::app_session::evict_idle(service),
        Protocol::Acp => super::acp::evict_idle(service),
        Protocol::OpenCode => super::opencode::evict_idle(service),
    }
}

fn release(service: &str) {
    session_engine::engine(service).disconnect(service);
    meta::release_service(service);
}

pub(crate) fn preferences() -> Result<ConnectionWindowConfig> {
    let settings = config::load_config(&runtime::support_dir()?)?.connection_window;
    validate(settings)?;
    Ok(settings)
}

fn validate(settings: ConnectionWindowConfig) -> Result<()> {
    ensure!((1..=32).contains(&settings.capacity), "connection capacity must be between 1 and 32");
    Ok(())
}

pub(crate) fn set_preferences(settings: ConnectionWindowConfig) -> Result<()> {
    validate(settings)?;
    config::update_config(&runtime::support_dir()?, |config| {
        config.connection_window = settings;
        Ok(())
    })?;
    maintain();
    Ok(())
}

/// Idempotently select a service. One staging connection may temporarily exceed
/// capacity, so a failed handshake never destroys the selected conversation.
pub(crate) fn connect(service: String, port: u16, epoch: u64) -> Result<()> {
    let settings = preferences()?;
    let mut window = WINDOW.lock().unwrap_or_else(|e| e.into_inner());
    window.connect(service, port, settings, epoch)?;
    drop(window);
    start_maintenance();
    Ok(())
}

/// Automatic recovery cannot select an evicted service or cross an account
/// change. Only a new explicit selection may admit it again.
pub(crate) fn reconnect(service: String, port: u16, epoch: u64) -> Result<()> {
    let settings = preferences()?;
    let mut window = WINDOW.lock().unwrap_or_else(|e| e.into_inner());
    ensure!(
        transport::is_current(epoch)
            && window.epoch == epoch
            && window.selected.as_deref() == Some(&service),
        "the service is no longer selected; select it again to connect"
    );
    window.connect(service, port, settings, epoch)
}

pub(crate) fn disconnect(service: &str) {
    let mut window = WINDOW.lock().unwrap_or_else(|e| e.into_inner());
    window.refresh();
    window.entries.retain(|entry| entry.service != service);
    if window.selected.as_deref() == Some(service) {
        window.selected = None;
    }
    release(service);
}

fn maintain() {
    let Ok(settings) = preferences() else { return };
    let Ok(mut window) = WINDOW.try_lock() else { return };
    window.refresh();
    let selected = window.selected.clone().unwrap_or_default();
    window.trim(settings, &selected, 0);
}

fn start_maintenance() {
    MAINTENANCE.call_once(|| {
        runtime::runtime().spawn(async {
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                let _ = tokio::task::spawn_blocking(maintain).await;
            }
        });
    });
}

#[cfg(test)]
#[path = "connection_window_tests.rs"]
mod lifecycle_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_recency_and_connection_age_are_distinct() {
        let mut window = Window::default();
        window.touch("a");
        window.touch("b");
        window.touch("a");
        window.touch("c");
        assert_eq!(window.entries.len(), 3, "reselecting must reuse its slot");
        assert_eq!(window.candidates(ConnectionEviction::Lru, "c"), ["b", "a"]);
        assert_eq!(window.candidates(ConnectionEviction::Fifo, "c"), ["a", "b"]);
    }

    #[test]
    fn missing_preferences_default_and_invalid_capacity_is_rejected() {
        let config: pocox_core::config::Config = toml::from_str("").expect("default config");
        assert_eq!(config.connection_window.capacity, 5);
        assert_eq!(config.connection_window.eviction, ConnectionEviction::Lru);
        assert!(validate(ConnectionWindowConfig {
            capacity: 0,
            ..Default::default()
        })
        .is_err());
        let serialized = toml::to_string(&ConnectionWindowConfig {
            capacity: 8,
            eviction: ConnectionEviction::Fifo,
        })
        .expect("serialize");
        let restored: ConnectionWindowConfig = toml::from_str(&serialized).expect("restore");
        assert_eq!(restored.capacity, 8);
        assert_eq!(restored.eviction, ConnectionEviction::Fifo);
    }
}
