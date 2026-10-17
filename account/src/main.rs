use anyhow::{bail, Result};
use funtidesk_account::{config::Config, mail, registry::UnixRegistry, store::Store, App};
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<()> {
    let command = std::env::args().nth(1).unwrap_or_default();
    if !command.is_empty() && command != "initialize" {
        bail!("unknown account command");
    }
    let config = Config::from_env()?;
    if command == "initialize" && config.database.exists() {
        bail!("account database already exists");
    }
    if command != "initialize" && !config.database.is_file() {
        bail!("account database missing: initialize explicitly");
    }
    let store = Store::open(&config.database, config.key)?;
    let (sender, receiver) = tokio::sync::mpsc::channel(20);
    let app = App::new(
        store,
        sender,
        Arc::new(UnixRegistry(config.registry_socket)),
        config.trusted_proxies,
    );
    if command == "initialize" {
        println!("ACCOUNT_INITIALIZED");
        return Ok(());
    }
    tokio::spawn(mail::deliver(
        receiver,
        config.smtp_host,
        config.smtp_port,
        app.clone(),
    ));
    let maintenance = app.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            if maintenance.maintain().await.is_err() {
                eprintln!("account database maintenance failed");
            }
        }
    });
    let listener = tokio::net::TcpListener::bind(config.listen).await?;
    axum::serve(
        listener,
        funtidesk_account::router(app)
            .into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        let _ = tokio::signal::ctrl_c().await;
    })
    .await?;
    Ok(())
}
