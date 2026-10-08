// FUNTIDESK ADR-004: integration test of TCP signaling in hbbs.
//
// Starts the built hbbs on local test ports in a temporary directory and
// checks that
// 1. a device in TCP mode gets a key exchange, secures the channel,
//    registers its key and receives a punch-hole request over TCP;
// 2. a device registered over UDP still receives its request over UDP;
// 3. one-shot TCP requests that send first keep the upstream behaviour.

use hbb_common::{
    protobuf::Message as _,
    rendezvous_proto::*,
    sodiumoxide::crypto::{box_, secretbox, sign},
    tcp::FramedStream,
    tokio,
    udp::FramedSocket,
};
use std::{
    net::SocketAddr,
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::Duration,
};

struct Hbbs {
    child: Child,
    port: u16,
    pk: sign::PublicKey,
    dir: PathBuf,
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

fn start_hbbs(port: u16) -> Hbbs {
    let dir = std::env::temp_dir().join(format!("hbbs-tcp-signaling-{port}"));
    std::fs::remove_dir_all(&dir).ok();
    std::fs::create_dir_all(&dir).unwrap();
    let (pk, sk) = sign::gen_keypair();
    std::fs::write(dir.join("id_ed25519"), base64_encode(&sk.0)).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_hbbs"))
        .args(["-p", &port.to_string(), "-k", "-"])
        .env("TEST_HBBS", "no")
        .current_dir(&dir)
        .env("RUST_LOG", "debug")
        .stdout(std::fs::File::create(dir.join("hbbs.log")).unwrap())
        .stderr(Stdio::null())
        .spawn()
        .expect("start hbbs");
    std::thread::sleep(Duration::from_millis(1500));
    Hbbs { child, port, pk, dir }
}

fn base64_encode(data: &[u8]) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in data.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let n = (b[0] as u32) << 16 | (b[1] as u32) << 8 | b[2] as u32;
        for i in 0..4 {
            if i <= c.len() {
                out.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn licence_key(h: &Hbbs) -> String {
    base64_encode(&h.pk.0)
}

async fn next_msg(stream: &mut FramedStream, ms: u64) -> Option<RendezvousMessage> {
    loop {
        let bytes = stream.next_timeout(ms).await?.ok()?;
        if bytes.is_empty() {
            continue;
        }
        return RendezvousMessage::parse_from_bytes(&bytes).ok();
    }
}

/// Device side of the client's `start_tcp` + `secure_tcp`.
async fn tcp_device(h: &Hbbs, id: &str) -> FramedStream {
    let mut stream = FramedStream::new(format!("127.0.0.1:{}", h.port), None, 3000)
        .await
        .unwrap();
    let msg = next_msg(&mut stream, 3000).await.expect("key exchange offered");
    let Some(rendezvous_message::Union::KeyExchange(ex)) = msg.union else {
        panic!("expected KeyExchange, got {msg:?}");
    };
    assert_eq!(ex.keys.len(), 1);
    let their_pk_b = sign::verify(&ex.keys[0], &h.pk).expect("signed by the server key");
    let their_pk_b = box_::PublicKey::from_slice(&their_pk_b).unwrap();
    let (our_pk_b, our_sk_b) = box_::gen_keypair();
    let key = secretbox::gen_key();
    let nonce = box_::Nonce([0u8; box_::NONCEBYTES]);
    let sealed = box_::seal(&key.0, &nonce, &their_pk_b, &our_sk_b);
    let mut out = RendezvousMessage::new();
    out.set_key_exchange(KeyExchange {
        keys: vec![our_pk_b.0.to_vec().into(), sealed.into()],
        ..Default::default()
    });
    stream.send(&out).await.unwrap();
    stream.set_key(key);

    let mut out = RendezvousMessage::new();
    out.set_register_pk(RegisterPk {
        id: id.to_owned(),
        uuid: format!("uuid-{id}").into_bytes().into(),
        pk: vec![7u8; 32].into(),
        ..Default::default()
    });
    stream.send(&out).await.unwrap();
    let msg = next_msg(&mut stream, 3000).await.expect("register response");
    let Some(rendezvous_message::Union::RegisterPkResponse(r)) = msg.union else {
        panic!("expected RegisterPkResponse, got {msg:?}");
    };
    assert_eq!(r.result.enum_value(), Ok(register_pk_response::Result::OK));
    assert!(r.keep_alive > 0, "keep_alive must be announced");
    stream
}

/// On one host the server asks for the local address instead of punching.
fn is_connect_request(msg: &RendezvousMessage) -> bool {
    matches!(
        msg.union,
        Some(rendezvous_message::Union::PunchHole(_))
            | Some(rendezvous_message::Union::FetchLocalAddr(_))
    )
}

/// Requester side: one-shot TCP request that sends first.
async fn request_punch(h: &Hbbs, id: &str) -> FramedStream {
    let mut stream = FramedStream::new(format!("127.0.0.1:{}", h.port), None, 3000)
        .await
        .unwrap();
    let mut out = RendezvousMessage::new();
    out.set_punch_hole_request(PunchHoleRequest {
        id: id.to_owned(),
        nat_type: NatType::ASYMMETRIC.into(),
        licence_key: licence_key(h),
        ..Default::default()
    });
    stream.send(&out).await.unwrap();
    stream
}

#[tokio::test(flavor = "multi_thread")]
async fn tcp_device_receives_punch_hole_over_tcp() {
    let h = start_hbbs(41116);
    let mut device = tcp_device(&h, "tcpdev01").await;
    let mut requester = request_punch(&h, "tcpdev01").await;
    let msg = next_msg(&mut device, 3000)
        .await
        .expect("punch hole delivered over TCP");
    assert!(is_connect_request(&msg), "got {msg:?}");
    // The requester's one-shot connection never sees a key exchange.
    assert!(next_msg(&mut requester, 500).await.is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn tcp_device_stays_online_and_gets_heartbeats_answered() {
    let h = start_hbbs(41126);
    let mut device = tcp_device(&h, "tcpdev02").await;
    // Answer server heartbeats like the client does; the device must stay
    // reachable after the 30 s registration timeout.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(35);
    while tokio::time::Instant::now() < deadline {
        if let Some(Ok(bytes)) = device.next_timeout(1000).await {
            if bytes.is_empty() {
                device.send_bytes(Default::default()).await.unwrap();
            }
        }
    }
    let _requester = request_punch(&h, "tcpdev02").await;
    let msg = next_msg(&mut device, 3000).await.expect("still reachable");
    assert!(is_connect_request(&msg), "got {msg:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn udp_device_still_receives_punch_hole_over_udp() {
    let h = start_hbbs(41136);
    let server: SocketAddr = format!("127.0.0.1:{}", h.port).parse().unwrap();
    let mut udp = FramedSocket::new("127.0.0.1:0").await.unwrap();
    let mut out = RendezvousMessage::new();
    out.set_register_pk(RegisterPk {
        id: "udpdev01".to_owned(),
        uuid: b"uuid-udpdev01".to_vec().into(),
        pk: vec![9u8; 32].into(),
        ..Default::default()
    });
    udp.send(&out, server).await.unwrap();
    udp.next_timeout(3000).await.expect("register pk response").unwrap();
    let mut out = RendezvousMessage::new();
    out.set_register_peer(RegisterPeer {
        id: "udpdev01".to_owned(),
        ..Default::default()
    });
    udp.send(&out, server).await.unwrap();
    udp.next_timeout(3000).await.expect("register peer response").unwrap();

    let _requester = request_punch(&h, "udpdev01").await;
    let (bytes, _) = udp
        .next_timeout(3000)
        .await
        .expect("punch hole over UDP")
        .unwrap();
    let msg = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
    assert!(is_connect_request(&msg), "got {msg:?}");
}
