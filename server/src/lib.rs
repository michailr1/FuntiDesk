mod rendezvous_server;
pub use rendezvous_server::*;
pub mod common;
mod database;
// FUNTIDESK (ADR-008): pairing by code.
mod funti_pair;
// FUNTIDESK (ADR-010): account has read-only access to registered device keys.
mod funti_account_identity;
mod peer;
mod version;
