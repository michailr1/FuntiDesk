use lettre::{
    message::{header::ContentType, Mailbox},
    AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor,
};
use tokio::sync::mpsc;

pub struct MailJob {
    pub challenge: String,
    pub email: String,
    pub code: String,
}

pub fn normalize_email(value: &str) -> Option<String> {
    let value = value.trim();
    if value.len() > 254 || !value.is_ascii() || value.bytes().any(|b| b.is_ascii_control()) {
        return None;
    }
    let (local, domain) = value.rsplit_once('@')?;
    let normalized = format!("{local}@{}", domain.to_ascii_lowercase());
    normalized.parse::<lettre::Address>().ok()?;
    Some(normalized)
}

pub async fn deliver(mut queue: mpsc::Receiver<MailJob>, host: String, port: u16, app: crate::App) {
    let transport = AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(host)
        .port(port)
        .timeout(Some(std::time::Duration::from_secs(15)))
        .build();
    while let Some(job) = queue.recv().await {
        let id = job.challenge.clone();
        let now = app.now();
        if !matches!(
            app.db(move |db| db.challenge_pending(&id, now)).await,
            Ok(true)
        ) {
            continue;
        }
        let result = async {
            let message = Message::builder()
                .from("FuntiDesk <no-reply@funti.cc>".parse::<Mailbox>()?)
                .to(job.email.parse::<Mailbox>()?)
                .subject("Код входа в FuntiDesk")
                .header(ContentType::TEXT_PLAIN)
                .body(format!("Код входа: {}\n\nКод действует 5 минут и подходит один раз.\nЕсли это не вы — ничего не делайте.\n", job.code))?;
            transport.send(message).await?;
            Ok::<_, anyhow::Error>(())
        }.await;
        if result.is_err() {
            // Never print the transport error: it can contain the recipient.
            let challenge = job.challenge;
            if app
                .db(move |db| db.cancel_challenge(&challenge))
                .await
                .is_err()
            {
                eprintln!("account mail challenge invalidation failed");
            }
            eprintln!("account mail delivery failed");
        }
    }
}
