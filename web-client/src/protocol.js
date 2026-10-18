import sodium from 'libsodium-wrappers';
import { hbb } from './schema.generated.js';

export const SERVER_KEY = '2R3kWM1HR3BMoz3EB6KDmv5SjOKrDEVdrZXRcFWaDg4=';
export const wire = hbb.Message;
export const rendezvous = hbb.RendezvousMessage;
const identity = hbb.IdPk;
export const controls = hbb.ControlKey;
export const ready = sodium.ready;
export function encode(type, value) { return type.encode(type.fromObject(value)).finish(); }
export function decode(type, value) { return type.toObject(type.decode(value), { bytes: Uint8Array, longs: Number, defaults: false }); }
export function nonce(value) {
  const bytes = new Uint8Array(24);
  new DataView(bytes.buffer).setBigUint64(0, BigInt(value), true);
  return bytes;
}
export function splitKeys(secret, initiator, responder, advertised) {
  if (secret.length !== 32 || initiator.length !== 32 || responder.length !== 32 || advertised < 1) throw new Error('invalid_handshake');
  const versions = new Uint8Array(8);
  const view = new DataView(versions.buffer);
  view.setUint32(0, advertised, true); view.setUint32(4, 1, true);
  return [1, 2].map((direction) => sodium.crypto_generichash(32, new Uint8Array([
    ...new TextEncoder().encode('rdkx-spl'), direction, ...versions, ...initiator, ...responder,
  ]), secret));
}
export function verifyIdentity(signed, key, expectedId) {
  if (!signed?.length || key.length !== 32) throw new Error('invalid_identity');
  const value = decode(identity, sodium.crypto_sign_open(signed, key));
  if (value.id !== expectedId || value.pk?.length !== 32) throw new Error('invalid_identity');
  return value;
}
export function handshake(signedPeer, signedId, expectedId, serverKey = SERVER_KEY) {
  const trusted = verifyIdentity(signedPeer, sodium.from_base64(serverKey, sodium.base64_variants.ORIGINAL), expectedId);
  const peer = verifyIdentity(signedId, trusted.pk, expectedId);
  if (!(peer.kx_version >= 1)) throw new Error('client_update_required');
  const pair = sodium.crypto_box_keypair();
  const secret = sodium.randombytes_buf(32);
  try {
    const symmetric_value = sodium.crypto_box_easy(secret, new Uint8Array(24), peer.pk, pair.privateKey);
    const [sendKey, receiveKey] = splitKeys(secret, pair.publicKey, peer.pk, peer.kx_version);
    return { public_key: { asymmetric_value: pair.publicKey, symmetric_value, kx_version: 1 }, sendKey, receiveKey, peerKey: trusted.pk };
  } finally { sodium.memzero(pair.privateKey); sodium.memzero(secret); }
}
export async function passwordKey(password, salt) {
  const text = new TextEncoder(), raw = new Uint8Array([...text.encode(password), ...text.encode(salt)]);
  try { return new Uint8Array(await crypto.subtle.digest('SHA-256', raw)); } finally { wipe(raw); }
}
export async function challengeProof(salted, challenge) {
  const raw = new Uint8Array([...salted, ...new TextEncoder().encode(challenge)]);
  try { return new Uint8Array(await crypto.subtle.digest('SHA-256', raw)); } finally { wipe(raw); }
}
export async function passwordProof(password, salt, challenge) {
  const salted = await passwordKey(password, salt);
  try { return await challengeProof(salted, challenge); } finally { wipe(salted); }
}
export function encrypt(bytes, count, key) { return sodium.crypto_secretbox_easy(bytes, nonce(count), key); }
export function decrypt(bytes, count, key) { return sodium.crypto_secretbox_open_easy(bytes, nonce(count), key); }
export function wipe(bytes) { if (bytes) sodium.memzero(bytes); }
