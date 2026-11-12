use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use dayfold_apns::{ApnsClient, ApnsConfig};
use dayfold_domain::{generate_secret, hash_secret};
use dayfold_store::{SessionKey, Store};
use std::{net::SocketAddr, path::PathBuf, time::Duration};
use tokio::sync::watch;
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

#[derive(Parser)]
#[command(version, about = "Dayfold notification relay")]
struct Args {
    #[arg(long, env = "DATABASE_URL", hide_env_values = true)]
    database_url: String,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Apply database migrations. Run once before serving.
    Migrate,
    /// Create a legacy local-development installation; unavailable to public servers.
    Provision,
    /// Revoke one installation and its outstanding delivery work.
    Revoke { id: Uuid },
    /// Run the HTTP service and durable workers.
    Serve {
        #[arg(long, env = "DAYFOLD_BIND", default_value = "127.0.0.1:8080")]
        bind: SocketAddr,
        #[arg(long, env = "DAYFOLD_PUBLIC_ORIGIN")]
        public_origin: String,
        /// Accept legacy operator tokens only on a loopback listener with APNs disabled.
        #[arg(long, env = "DAYFOLD_ALLOW_LEGACY_DEV_AUTH", default_value_t = false)]
        allow_legacy_dev_auth: bool,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                "dayfold_server=info,dayfold_worker=info,dayfold_api=info".into()
            }),
        )
        .with_writer(std::io::stderr)
        .init();
    let args = Args::parse();
    // Never include connection strings or raw database errors in operator logs.
    let store = Store::connect(&args.database_url, 20)
        .await
        .map_err(|_| anyhow::anyhow!("database connection failed"))?;
    match args.command {
        Command::Migrate => {
            store.migrate().await.map_err(|_| {
                anyhow::anyhow!("migration failed; inspect the migration and database privately")
            })?;
            println!("Migrations applied");
        }
        Command::Provision => {
            let token = generate_secret()?;
            let id = Uuid::new_v4();
            store
                .provision(id, &hash_secret(&token))
                .await
                .map_err(|_| anyhow::anyhow!("provisioning failed"))?;
            println!("{}", serde_json::json!({"device_id":id,"token":token}));
        }
        Command::Revoke { id } => {
            store
                .revoke_device(id)
                .await
                .map_err(|_| anyhow::anyhow!("revocation failed"))?;
        }
        Command::Serve {
            bind,
            public_origin,
            allow_legacy_dev_auth,
        } => {
            let apns = load_apns()?;
            if allow_legacy_dev_auth && (!bind.ip().is_loopback() || apns.is_some()) {
                bail!(
                    "legacy development authentication requires a loopback listener and APNs disabled"
                );
            }
            let session = load_sessions(allow_legacy_dev_auth).await?;
            if session.is_none() && !allow_legacy_dev_auth {
                bail!(
                    "configure Dayfold OIDC and a persistent session key before serving; legacy development authentication must be explicitly enabled on loopback"
                );
            }
            let (store, session) = match session {
                Some((configuration, key)) => (store.with_session_key(key), Some(configuration)),
                None => (store, None),
            };
            let mut state = dayfold_api::ApiState::new(store.clone(), &public_origin)
                .map_err(anyhow::Error::msg)?;
            if let Some(session) = session {
                state = state.with_session_configuration(session);
            }
            state = state.with_legacy_development_auth(allow_legacy_dev_auth);
            tracing::info!(
                apns_enabled = apns.is_some(),
                "notification service starting"
            );
            let listener = tokio::net::TcpListener::bind(bind)
                .await
                .context("cannot bind HTTP listener")?;
            let (shutdown, receive) = watch::channel(false);
            let state = state
                .with_apns_enabled(apns.is_some())
                .with_shutdown(receive.clone());
            let mut http_shutdown = receive.clone();
            let mut worker = tokio::spawn(dayfold_worker::run(store, apns, receive));
            let mut http = tokio::spawn(async move {
                axum::serve(listener, dayfold_api::router(state))
                    .with_graceful_shutdown(async move {
                        let _ = http_shutdown.changed().await;
                    })
                    .await
            });
            let result = tokio::select! {
                result = &mut http => result.context("HTTP task failed")?.context("HTTP service failed"),
                _ = shutdown_signal() => {
                    let _ = shutdown.send(true);
                    match tokio::time::timeout(Duration::from_secs(30), &mut http).await {
                        Ok(result) => result.context("HTTP task failed")?.context("HTTP service failed"),
                        Err(_) => { http.abort(); tracing::warn!("HTTP drain deadline reached"); Ok(()) }
                    }
                }
            };
            let _ = shutdown.send(true);
            match tokio::time::timeout(Duration::from_secs(30), &mut worker).await {
                Ok(result) => result.context("worker task failed")?,
                Err(_) => {
                    worker.abort();
                    tracing::warn!("worker drain deadline reached; leases will recover");
                }
            }
            result?;
        }
    }
    Ok(())
}

async fn load_sessions(
    allow_legacy: bool,
) -> Result<Option<(dayfold_api::SessionConfiguration, SessionKey)>> {
    let values: Vec<Option<String>> = [
        "DAYFOLD_OIDC_ISSUER",
        "DAYFOLD_OIDC_CLIENT_IDS",
        "DAYFOLD_OIDC_JWKS_URI",
        "DAYFOLD_SESSION_KEY_FILE",
    ]
    .into_iter()
    .map(|name| std::env::var(name).ok())
    .collect();
    if values.iter().all(Option::is_none) {
        return Ok(None);
    }
    if allow_legacy {
        bail!("OIDC sessions and legacy development authentication cannot be enabled together");
    }
    if values.iter().any(Option::is_none) {
        bail!(
            "sessions require the OIDC issuer, native client IDs, pinned JWKS URI and session key file together"
        );
    }
    let key_path = PathBuf::from(values[3].as_ref().unwrap());
    let metadata = std::fs::symlink_metadata(&key_path)
        .map_err(|_| anyhow::anyhow!("cannot inspect session key file"))?;
    if !metadata.file_type().is_file() || metadata.len() > 128 {
        bail!(
            "session key must be a regular private file containing 32 random bytes or 64 hex characters"
        );
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            bail!("session key file must not be accessible to group or other users");
        }
    }
    let mut bytes = Zeroizing::new(
        std::fs::read(&key_path).map_err(|_| anyhow::anyhow!("cannot read session key file"))?,
    );
    let mut key = Zeroizing::new([0u8; 32]);
    if bytes.len() == 32 {
        key.copy_from_slice(&bytes);
    } else {
        let text = std::str::from_utf8(&bytes)
            .ok()
            .map(str::trim)
            .filter(|text| text.len() == 64 && text.bytes().all(|byte| byte.is_ascii_hexdigit()))
            .ok_or_else(|| {
                anyhow::anyhow!("session key must contain 32 random bytes or 64 hex characters")
            })?;
        for (index, byte) in key.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&text[index * 2..index * 2 + 2], 16)
                .map_err(|_| anyhow::anyhow!("invalid session key encoding"))?;
        }
    }
    bytes.zeroize();
    if key.iter().all(|byte| *byte == 0) {
        bail!("session key cannot be all zeros");
    }
    let session_key = SessionKey::new(*key);
    key.zeroize();
    let config = dayfold_auth::OidcConfig {
        issuer: values[0].clone().unwrap(),
        client_ids: values[1]
            .as_ref()
            .unwrap()
            .split(',')
            .map(str::trim)
            .map(str::to_owned)
            .collect(),
        jwks_uri: values[2].clone().unwrap(),
    };
    let configuration = dayfold_api::SessionConfiguration::new(config)
        .await
        .map_err(|_| anyhow::anyhow!("OIDC discovery or session configuration failed"))?;
    Ok(Some((configuration, session_key)))
}

fn load_apns() -> Result<Option<ApnsClient>> {
    let values: Vec<Option<String>> = [
        "DAYFOLD_APNS_TEAM_ID",
        "DAYFOLD_APNS_KEY_ID",
        "DAYFOLD_APNS_TOPIC",
        "DAYFOLD_APNS_KEY_FILE",
    ]
    .into_iter()
    .map(|name| std::env::var(name).ok())
    .collect();
    if values.iter().all(Option::is_none) {
        return Ok(None);
    }
    if values.iter().any(Option::is_none) {
        bail!("APNs requires team ID, key ID, topic, and key file together");
    }
    let pem = std::fs::read(PathBuf::from(values[3].as_ref().unwrap()))
        .map_err(|_| anyhow::anyhow!("cannot read APNs key file"))?;
    let config = ApnsConfig {
        team_id: values[0].clone().unwrap(),
        key_id: values[1].clone().unwrap(),
        topic: values[2].clone().unwrap(),
        private_key_pem: pem,
    };
    Ok(Some(ApnsClient::new(config).map_err(|_| {
        anyhow::anyhow!("invalid APNs configuration")
    })?))
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("signal handler");
        tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = term.recv() => {} }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
