use lettre::{
    message::{Mailbox, SinglePart},
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

fn login_message(email: &str, code: &str) -> anyhow::Result<Message> {
    // Use an unrelated random ID, never the login code or challenge ID.
    let id = format!("<{}@desk.funti.cc>", &crate::crypto::token()[..32]);
    Ok(Message::builder()
        .message_id(Some(id))
        .from("FuntiDesk <no-reply@funti.cc>".parse::<Mailbox>()?)
        .to(email.parse::<Mailbox>()?)
        .subject("Код входа в FuntiDesk")
        .singlepart(SinglePart::plain(format!(
            "Код входа: {code}\n\nКод действует 5 минут и подходит один раз.\nЕсли это не вы — ничего не делайте.\n"
        )))?)
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
            let message = login_message(&job.email, &job.code)?;
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

#[cfg(test)]
mod tests {
    use super::login_message;

    #[test]
    fn login_mail_has_mime_version_and_unique_sender_message_id() {
        let mut ids = Vec::new();
        for _ in 0..2 {
            let raw = String::from_utf8(
                login_message("person@example.invalid", "123456")
                    .unwrap()
                    .formatted(),
            )
            .unwrap();
            let (headers, _) = raw.split_once("\r\n\r\n").unwrap();
            assert!(headers.lines().any(|line| line == "MIME-Version: 1.0"));
            let id = headers
                .lines()
                .find_map(|line| line.strip_prefix("Message-ID: "))
                .unwrap();
            assert!(id.starts_with('<') && id.ends_with("@desk.funti.cc>"));
            assert_ne!(id, "<123456@desk.funti.cc>");
            ids.push(id.to_owned());
        }
        assert_ne!(ids[0], ids[1]);
    }
}
