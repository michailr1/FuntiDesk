// FUNTIDESK: refresh the NAT classification when the network changes
// (former MIK-16, ported 2026-10-15). Upstream tests the NAT type once and
// keeps it until restart, so after Wi-Fi <-> mobile or a VPN switch new
// sessions punch holes with the old classification and fall back to relay.
//
// The monitor watches the local source address the OS picks for the pinned
// rendezvous server (not the default route: VPN split tunneling can route
// it differently). A UDP `connect` only selects the address, nothing is sent.

use hbb_common::{config::Config, log, rendezvous_proto::NatType};
use std::{
    net::{IpAddr, ToSocketAddrs, UdpSocket},
    time::{Duration, Instant},
};

const POLL: Duration = Duration::from_secs(4);
const SETTLE: Duration = Duration::from_secs(2);
/// A router or mobile network may change its mapping without a new local
/// address; test again now and then.
const PERIODIC_REFRESH: Duration = Duration::from_secs(120);

fn route_source() -> Option<IpAddr> {
    let server = hbb_common::socket_client::check_port(
        &*Config::get_rendezvous_server(),
        hbb_common::config::RENDEZVOUS_PORT,
    );
    let remote = server.to_socket_addrs().ok()?.find(|addr| addr.is_ipv4())?;
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect(remote).ok()?;
    Some(socket.local_addr().ok()?.ip())
}

/// Starts the monitor once per process.
pub fn start_monitor() {
    static START: std::sync::Once = std::sync::Once::new();
    START.call_once(|| {
        std::thread::spawn(run);
    });
}

fn run() {
    let mut previous = route_source();
    let mut unavailable = previous.is_none();
    log::info!("FuntiDesk network monitor started, source {:?}", previous);
    let mut last_test = Instant::now();
    loop {
        std::thread::sleep(POLL);
        let Some(current) = route_source() else {
            if !unavailable {
                log::warn!("FuntiDesk network monitor: route to the server unavailable");
            }
            // A recovered route may keep the address but not the NAT.
            unavailable = true;
            continue;
        };
        if unavailable || previous != Some(current) {
            // Do not test a path that is still changing.
            std::thread::sleep(SETTLE);
            if route_source() != Some(current) {
                continue;
            }
            log::info!(
                "FuntiDesk network monitor: route changed {:?} -> {} (recovered={})",
                previous,
                current,
                unavailable
            );
            unavailable = false;
            previous = Some(current);
            // New sessions must not use the old route's classification.
            Config::set_nat_type(NatType::UNKNOWN_NAT as _);
            crate::rendezvous_mediator::RendezvousMediator::restart();
            crate::test_nat_type();
            last_test = Instant::now();
        } else if last_test.elapsed() >= PERIODIC_REFRESH {
            crate::test_nat_type();
            last_test = Instant::now();
        }
    }
}

/// After a test: a changed classification means the mapping behind an
/// unchanged local route changed, so register again.
pub fn on_tested(old: i32, new: i32) {
    if old != NatType::UNKNOWN_NAT as i32 && old != new {
        log::info!("FuntiDesk: NAT type changed {old} -> {new}, re-registering");
        crate::rendezvous_mediator::RendezvousMediator::restart();
    }
}
