import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import sodium from 'libsodium-wrappers';
import { ready, SERVER_KEY, splitKeys, passwordProof, verifyIdentity, handshake, encode, decrypt, encrypt, wire, rendezvous } from '../src/protocol.js';
import { hbb } from '../src/schema.generated.js';
await ready;
const hex = (bytes) => Buffer.from(bytes).toString('hex');

test('directional keys match the actual native Rust v1 wire vectors', () => {
  const [send, receive] = splitKeys(new Uint8Array(32).fill(0x11),new Uint8Array(32).fill(0x22),new Uint8Array(32).fill(0x33),1);
  assert.equal(hex(send),'c189ec6e1935c0751cfc85a0f075405cae507d7925bb19687caf56cbb54e0ecf');
  assert.equal(hex(receive),'8a62648e9195cb10ea900c0a24d2a166c1e982347a2dc6833c3e756bf5715d36');
  const cipher = encrypt(new TextEncoder().encode('hello'),1,send);
  assert.equal(new TextDecoder().decode(decrypt(cipher,1,send)),'hello');
  assert.throws(() => decrypt(cipher,1,receive));
  assert.throws(() => decrypt(cipher,2,send));
});

test('temporary and permanent passwords use the existing salted challenge proof', async () => {
  for (const password of ['482951','long permanent пароль']) {
    const salt='salt'; const challenge='nonce';
    const expected = createHash('sha256').update(Buffer.concat([createHash('sha256').update(password+salt).digest(),Buffer.from(challenge)])).digest('hex');
    assert.equal(hex(await passwordProof(password,salt,challenge)),expected);
    assert.notEqual(hex(await passwordProof(password,salt,'other')),expected);
  }
});

test('both signed identities are mandatory and the sealed session key opens only at the peer', () => {
  const server=sodium.crypto_sign_keypair();const peer=sodium.crypto_sign_keypair();const box=sodium.crypto_box_keypair();
  const id='123456789';
  const signedPeer=sodium.crypto_sign(encode(hbb.IdPk,{id,pk:peer.publicKey}),server.privateKey);
  const signedId=sodium.crypto_sign(encode(hbb.IdPk,{id,pk:box.publicKey,kx_version:1}),peer.privateKey);
  const serverKey=sodium.to_base64(server.publicKey,sodium.base64_variants.ORIGINAL);
  const exchange=handshake(signedPeer,signedId,id,serverKey);
  const secret=sodium.crypto_box_open_easy(exchange.public_key.symmetric_value,new Uint8Array(24),exchange.public_key.asymmetric_value,box.privateKey);
  const keys=splitKeys(secret,exchange.public_key.asymmetric_value,box.publicKey,1);
  assert.deepEqual(exchange.sendKey,keys[0]);assert.deepEqual(exchange.receiveKey,keys[1]);
  assert.throws(()=>handshake(new Uint8Array(),signedId,id,serverKey));
  assert.throws(()=>handshake(signedPeer,signedId,'987654321',serverKey));
  assert.throws(()=>handshake(signedPeer,signedPeer,id,serverKey));
  assert.throws(()=>handshake(signedPeer,sodium.crypto_sign(encode(hbb.IdPk,{id,pk:box.publicKey}),peer.privateKey),id,serverKey));
  assert.throws(()=>verifyIdentity(signedPeer,sodium.crypto_sign_keypair().publicKey,id));
});

test('current protobuf schemas preserve the secure relay and disabled optional capabilities', () => {
  const request=rendezvous.decode(encode(rendezvous,{request_relay:{id:'123456789',uuid:'random',secure:true}}));
  assert.equal(request.request_relay.secure,true);
  const msg=wire.decode(encode(wire,{login_request:{username:'123456789',password:new Uint8Array([1,2]),option:{disable_clipboard:2,disable_audio:2,enable_file_transfer:1}}}));
  assert.equal(msg.login_request.option.disable_clipboard,2);
  assert.equal(msg.login_request.option.enable_file_transfer,1);
});


test('the browser trust anchor is identical to the pinned native client key', async () => {
  const config = await readFile(new URL('../../client/libs/hbb_common/src/config.rs',import.meta.url),'utf8');
  assert.equal(config.match(/FUNTIDESK_SERVER_PUBLIC_KEY: &str = "([^"]+)"/)[1],SERVER_KEY);
});
