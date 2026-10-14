#![cfg(unix)]
// FUNTIDESK ADR-010: hbbs stays usable with account disabled or broken.
use hbb_common::{
    protobuf::Message as _,
    rendezvous_proto::*,
    sodiumoxide::crypto::{box_, secretbox, sign},
    tcp::FramedStream,
    tokio::{
        self,
        io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
        net::UnixStream,
    },
};
use std::{
    os::unix::fs::MetadataExt,
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::Duration,
};

struct Hbbs {
    child: Child,
    port: u16,
    pk: sign::PublicKey,
    dir: PathBuf,
    socket: PathBuf,
}
impl Drop for Hbbs {
    fn drop(&mut self) {
        self.child.kill().ok();
        self.child.wait().ok();
        if !std::thread::panicking() {
            std::fs::remove_dir_all(&self.dir).ok();
        }
    }
}

fn start(port: u16, valid_socket: bool) -> Hbbs {
    let dir = std::env::temp_dir().join(format!(
        "funtidesk-account-registry-{}-{port}",
        std::process::id()
    ));
    std::fs::create_dir(&dir).unwrap();
    let socket = if valid_socket {
        dir.join("hbbs.sock")
    } else {
        dir.join("missing/hbbs.sock")
    };
    let (pk, sk) = sign::gen_keypair();
    std::fs::write(dir.join("id_ed25519"), base64::encode(sk.0)).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_hbbs"))
        .args(["-p", &port.to_string(), "-k", "-"])
        .env("TEST_HBBS", "no")
        .env("FUNTI_ACCOUNT_IDENTITY_SOCKET", &socket)
        .env(
            "FUNTI_ACCOUNT_IDENTITY_GID",
            std::fs::metadata(&dir).unwrap().gid().to_string(),
        )
        .current_dir(&dir)
        .stdout(std::fs::File::create(dir.join("hbbs.log")).unwrap())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(1500));
    Hbbs {
        child,
        port,
        pk,
        dir,
        socket,
    }
}

async fn register(h: &Hbbs, id: &str, key: &sign::PublicKey) -> FramedStream {
    let mut stream = FramedStream::new(format!("127.0.0.1:{}", h.port), None, 3000)
        .await
        .unwrap();
    let bytes = stream.next_timeout(3000).await.unwrap().unwrap();
    let message = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
    let Some(rendezvous_message::Union::KeyExchange(exchange)) = message.union else {
        panic!("missing key exchange")
    };
    let server_box_pk = sign::verify(&exchange.keys[0], &h.pk).unwrap();
    let server_box_pk = box_::PublicKey::from_slice(&server_box_pk).unwrap();
    let (pk, sk) = box_::gen_keypair();
    let encryption_key = secretbox::gen_key();
    let sealed = box_::seal(
        &encryption_key.0,
        &box_::Nonce([0; box_::NONCEBYTES]),
        &server_box_pk,
        &sk,
    );
    let mut request = RendezvousMessage::new();
    request.set_key_exchange(KeyExchange {
        keys: vec![pk.0.to_vec().into(), sealed.into()],
        ..Default::default()
    });
    stream.send(&request).await.unwrap();
    stream.set_key(encryption_key);
    let mut request = RendezvousMessage::new();
    request.set_register_pk(RegisterPk {
        id: id.into(),
        uuid: format!("test-{id}").into_bytes().into(),
        pk: key.0.to_vec().into(),
        ..Default::default()
    });
    stream.send(&request).await.unwrap();
    let bytes = stream.next_timeout(3000).await.unwrap().unwrap();
    let reply = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
    let Some(rendezvous_message::Union::RegisterPkResponse(reply)) = reply.union else {
        panic!("missing registration response")
    };
    assert_eq!(
        reply.result.enum_value(),
        Ok(register_pk_response::Result::OK)
    );
    stream
}

async fn lookup(h: &Hbbs, id: &str) -> serde_json::Value {
    let stream = UnixStream::connect(&h.socket).await.unwrap();
    let mut stream = BufReader::new(stream);
    stream
        .get_mut()
        .write_all(format!("{{\"id\":\"{id}\"}}\n").as_bytes())
        .await
        .unwrap();
    let mut response = String::new();
    stream.read_line(&mut response).await.unwrap();
    serde_json::from_str(&response).unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn private_socket_returns_the_key_registered_over_the_secure_channel() {
    let h = start(43116, true);
    assert_eq!(
        lookup(&h, "unknown01").await,
        serde_json::json!({"pk":null})
    );
    let (pk, _) = sign::gen_keypair();
    let _device = register(&h, "account01", &pk).await;
    assert_eq!(
        lookup(&h, "account01").await,
        serde_json::json!({"pk":base64::encode(pk.0)})
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn broken_account_socket_does_not_stop_rendezvous_registration() {
    let h = start(43126, false);
    let (pk, _) = sign::gen_keypair();
    let _device = register(&h, "account02", &pk).await;
    assert!(!h.socket.exists());
}
