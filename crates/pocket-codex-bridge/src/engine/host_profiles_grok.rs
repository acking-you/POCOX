//! Grok Build's model services: the Grok account route, and a custom
//! provider in a Grok home of the host's own listing the gateway's models
//! (see `pocket_codex_host_svc::acp::grok`).

use std::path::PathBuf;

use anyhow::{anyhow, bail, Context, Result};
use pocket_codex_host_svc::acp::{
    grok, grok_control::GrokControl, provider::AcpProviderLaunch, AgentSpec,
};

use super::{host_names, opencode::models, Engine, Resolved, Source};

/// The Grok home of the custom-provider host `name`. It keeps that host's
/// sessions across provider changes and is never removed by POCOX.
pub(in crate::engine) fn home(name: &str) -> Result<PathBuf> {
    let name = host_names::canonical(name)?;
    let state = pocket_codex_core::paths::state_dir().context("resolving the state directory")?;
    let leaf = if name.len() <= 96 {
        name
    } else {
        pocket_codex_core::history_sync::digest_bytes(name.as_bytes())[..32].to_string()
    };
    Ok(state.join("acp-grok").join(leaf))
}

/// A Grok launch and the authority its session source is keyed by (`None`
/// when it inherits), plus a notice for the user.
pub(in crate::engine) type Routed = (Option<(AcpProviderLaunch, String)>, Option<String>);

/// The Grok launch of `resolved` for the instance `name`; its notice says
/// when the gateway's models could not be listed (only the default model is
/// then offered).
pub(in crate::engine) fn launch(
    resolved: &Resolved,
    spec: &AgentSpec,
    name: &str,
) -> Result<Routed> {
    Engine::Acp(spec).allows(resolved.source, resolved.endpoint.as_ref().map(|e| e.protocol))?;
    let authority = || {
        resolved
            .authority
            .clone()
            .ok_or_else(|| anyhow!("the saved provider has no authority; save it again"))
    };
    match (resolved.source, &resolved.endpoint) {
        (Source::Inherited, _) => Ok((None, None)),
        (Source::Official, _) => {
            let route = grok::account_launch();
            account_preflight(spec, &route)?;
            Ok((Some((route, authority()?)), None))
        },
        (Source::Custom, None) => Err(anyhow!("the saved provider is incomplete; edit the host")),
        (Source::Custom, Some(endpoint)) => {
            let authority = authority()?;
            let (models, notice) =
                match super::super::runtime::runtime().block_on(models::discover(endpoint)) {
                    Ok(listed) => (
                        listed
                            .into_iter()
                            .map(|(id, entry)| {
                                let name = entry["name"].as_str().unwrap_or(&id).to_string();
                                (id, name)
                            })
                            .collect(),
                        None,
                    ),
                    Err(error) => (
                        Vec::new(),
                        Some(format!(
                            "Gateway models unavailable: {error}. Only the configured default \
                             model is available; apply the host configuration again to retry."
                        )),
                    ),
                };
            let launch = grok::provider_launch(&home(name)?, endpoint, &models)?;
            Ok((Some((launch, authority)), notice))
        },
    }
}

/// A Grok-account host must run on a Grok model. Grok's own configuration
/// may make a model the user defined (with its own endpoint and key) the
/// default, which removing environment variables cannot undo, so the model
/// Grok would start with is read from a private `grok` on the same route and
/// the start is refused when the user defined it. An executable that cannot
/// be found is left to the start itself to report.
pub(in crate::engine) fn account_preflight(
    spec: &AgentSpec,
    route: &AcpProviderLaunch,
) -> Result<()> {
    let Some(program) = super::super::serve_acp::locate(&spec.program, Some(&spec.profile_id))
    else {
        return Ok(());
    };
    let home = grok::effective_home(&route.env).context("Grok's home directory is unavailable")?;
    let model = super::super::runtime::runtime().block_on(async {
        let control = GrokControl::start(
            &program,
            pocket_codex_codex::external_tool_path().as_ref(),
            &route.env,
            &route.env_remove,
        )
        .await
        .map_err(|error| anyhow!("{error}"))?;
        let model = control.current_model().map(str::to_owned);
        control.stop().await;
        Ok::<_, anyhow::Error>(model)
    })?;
    if grok::account_default_is_user_model(&home, model.as_deref())? {
        bail!(
            "Grok's default model{} is defined in {}, with its own endpoint and key, so this host \
             would not use the Grok account. Choose Existing configuration, or make a Grok model \
             the default there.",
            model.map(|m| format!(" `{m}`")).unwrap_or_default(),
            home.join("config.toml").display()
        );
    }
    Ok(())
}
