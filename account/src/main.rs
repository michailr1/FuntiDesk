use anyhow::{bail, Context, Result};
use funtidesk_account::{
    config::{read_key, Config},
    mail, recovery,
    registry::UnixRegistry,
    store::Store,
    witness, App,
};
use std::path::PathBuf;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<()> {
    let command = std::env::args().nth(1).unwrap_or_default();
    if command == "witness-relay" {
        let address = std::env::var("FUNTI_WITNESS_RELAY_LISTEN")
            .unwrap_or_else(|_| "127.0.0.1:21801".to_owned());
        let listener = tokio::net::TcpListener::bind(address).await?;
        axum::serve(listener, funtidesk_account::witness_relay()?).await?;
        return Ok(());
    }
    let namespace = std::env::var("FUNTI_ACCOUNT_WITNESS_NAMESPACE")
        .context("independent witness namespace is required")?;
    let witness_key = read_key(&PathBuf::from(
        std::env::var("FUNTI_ACCOUNT_WITNESS_KEY_FILE")
            .context("independent witness machine key is required")?,
    ))?;
    if command == "witness-init" || command == "witness" {
        let directory = PathBuf::from(
            std::env::var("FUNTI_WITNESS_DIRECTORY").unwrap_or_else(|_| "/data/witness".to_owned()),
        );
        if command == "witness-init" {
            witness::WitnessStore::initialize(&directory, &namespace, witness_key)?;
            println!("WITNESS_INITIALIZED");
            return Ok(());
        }
        let store = witness::WitnessStore::open(&directory, witness_key)?;
        if store.head().namespace != namespace {
            bail!("witness namespace mismatch");
        }
        let address =
            std::env::var("FUNTI_WITNESS_LISTEN").unwrap_or_else(|_| "127.0.0.1:21802".to_owned());
        let listener = tokio::net::TcpListener::bind(address).await?;
        axum::serve(listener, witness::router(store)).await?;
        return Ok(());
    }
    if !command.is_empty() && command != "initialize" && command != "restore" {
        bail!("unknown account command");
    }
    let config = Config::from_env()?;
    let witness_client = witness::Client::new(
        std::env::var("FUNTI_ACCOUNT_WITNESS_URL")
            .context("independent witness URL is required")?,
        namespace.clone(),
        witness_key,
    )?;
    if command == "restore" {
        let head = recovery::restore(&witness_client, config.key, &config.database).await?;
        println!(
            "ACCOUNT_RECOVERED revision={} event_highwater={}",
            head.revision, head.event_highwater
        );
        return Ok(());
    }
    if command != "initialize" && !config.database.is_file() {
        bail!("account database missing: initialize or restore explicitly");
    }
    let store = Store::open(&config.database, config.key)?;
    let (sender, receiver) = tokio::sync::mpsc::channel(20);
    let app = App::new(
        store,
        sender,
        Arc::new(UnixRegistry(config.registry_socket)),
        config.trusted_proxies,
    );
    let directory = std::env::var("FUNTI_ACCOUNT_RECOVERY_DIRECTORY")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            config
                .database
                .parent()
                .unwrap_or(std::path::Path::new("/data"))
                .join("recovery")
        });
    let app = recovery::Recovery::attach(
        app,
        witness_client,
        directory,
        namespace,
        command == "initialize",
    )
    .await?;
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
