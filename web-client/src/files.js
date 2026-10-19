import {Socket} from './socket.js';
import {ready, wire, rendezvous, SERVER_KEY, handshake, passwordProof, wipe} from './protocol.js';
import {BLOCK, fileBlock, fileName, fileSize, remotePath, joinPath} from './file-codec.js';
const ORIGIN = 'wss://desk.funti.cc';
export class Files {
  constructor(change = () => {}) { this.change = change; this.sockets = []; this.closed = false; this.nextId = 1; }
  async connect(id, password, expectedKey) {
    try {
      await ready;
      if (!/^[0-9]{6,16}$/.test(id) || !password || password.length > 256 || expectedKey?.length !== 32 || this.closed) throw Error('invalid_credentials');
      const signal = new Socket(ORIGIN + '/ws/rendezvous', rendezvous); this.sockets.push(signal); await signal.opened;
      if (this.closed) throw Error('cancelled');
      signal.send({punch_hole_request: {id, licence_key: SERVER_KEY, conn_type: 1, nat_type: 2, force_relay: true, version: '1.5.0'}});
      const response = (await signal.next()).relay_response; signal.close();
      if (!response?.uuid || !response.pk?.length || response.refuse_reason || this.closed) throw Error('computer_unavailable');
      const socket = new Socket(ORIGIN + '/ws/relay', rendezvous); this.socket = socket; this.sockets.push(socket); await socket.opened;
      if (this.closed) throw Error('cancelled');
      socket.send({request_relay: {id, uuid: response.uuid, secure: true, licence_key: SERVER_KEY, conn_type: 1}}); socket.type = wire;
      const first = await socket.next(), exchange = handshake(response.pk, first.signed_id?.id, id);
      this.keys = [exchange.sendKey, exchange.receiveKey];
      if (!exchange.peerKey.every((n, i) => n === expectedKey[i]) || this.closed) throw Error('invalid_identity');
      socket.send({public_key: exchange.public_key}); socket.secure(this.keys);
      const hash = (await socket.next()).hash;
      if (typeof hash?.salt !== 'string' || !hash.salt || hash.salt.length > 256 || typeof hash.challenge !== 'string' || !hash.challenge || hash.challenge.length > 256 || this.closed) throw Error('invalid_handshake');
      const proof = await passwordProof(password, hash.salt, hash.challenge); password = '';
      try { if (this.closed) throw Error('cancelled'); socket.send({login_request: {username: id, my_id: 'web-files-' + crypto.randomUUID(), my_name: 'FuntiDesk Web', password: proof, version: '1.5.0', my_platform: 'Web', file_transfer: {dir: '', show_hidden: false}}}); }
      finally { wipe(proof); }
      const deadline = Date.now() + 30000;
      while (!this.closed) {
        const message = await socket.next(Math.max(1, deadline - Date.now()));
        if (message.hash || message.login_response?.error) throw Error('files_denied');
        this.permission(message);
        if (message.test_delay) socket.send({test_delay: message.test_delay});
        if (message.login_response?.peer_info) {
          // Native file login sends the initial directory itself. Do not race it with ReadDir.
          this.connected = true; this.listing = true;
          this.listTimer = setTimeout(() => { this.error = 'network_timeout'; this.close(); }, 30000);
          this.change(); this.receive(); return;
        }
        if (Date.now() >= deadline) throw Error('network_timeout');
      }
    } catch (error) { this.close(); throw error; } finally { password = ''; }
  }
  permission(message) {
    const p = message.misc?.permission_info;
    if ((p?.permission === 4 && p.enabled !== true) || message.misc?.close_reason) throw Error('files_denied');
  }
  send(message) { if (!this.connected || this.closed) throw Error('connection_closed'); this.socket.send(message); }
  async receive() {
    try { while (!this.closed) {
      const m = await this.socket.next(120000); this.permission(m);
      if (m.test_delay && !m.test_delay.from_client) this.send({test_delay: m.test_delay});
      this.handle(m);
    }} catch (error) { if (!this.closed) { this.error = error.message; this.close(); } }
  }
  list(path = '') {
    if (!this.connected || this.closed) throw Error('connection_closed');
    if (this.job || this.listing) throw Error('file_busy');
    this.listing = true; this.send({file_action: {read_dir: {path: remotePath(path), include_hidden: false}}});
    this.listTimer = setTimeout(() => { this.error = 'network_timeout'; this.close(); }, 30000);
    this.change();
  }
  start(type, name, size) {
    if (!this.connected || this.closed) throw Error('connection_closed');
    if (this.job || this.listing) throw Error('file_busy');
    this.error = ''; this.blob = null; this.result = null;
    this.job = {id: this.nextId++, type, name: fileName(name), size: fileSize(size), bytes: 0, chunks: []}; this.touch(); this.change(); return this.job;
  }
  touch() { clearTimeout(this.jobTimer); this.jobTimer = setTimeout(() => this.cancel('network_timeout'), 30000); }
  upload(file, name = file.name) {
    if (!this.path) throw Error('file_path');
    const j = this.start('upload', name, file.size); j.file = file;
    this.send({file_action: {receive: {id: j.id, path: this.path, files: [{entry_type: 4, name: j.name, size: j.size, modified_time: Math.floor(file.lastModified / 1000) || 0}], total_size: j.size}}});
    this.send({file_response: {digest: {id: j.id, file_num: 0, file_size: j.size, last_modified: Math.floor(file.lastModified / 1000) || 0, is_upload: true}}});
  }
  download(entry) {
    if (entry.entry_type !== 4) throw Error('file_type');
    const j = this.start('download', entry.name, entry.size);
    this.send({file_action: {send: {id: j.id, path: joinPath(this.path, j.name), file_num: 0}}});
  }
  async pump(j) {
    if (j.sending) return; j.sending = true;
    try {
      // An empty block creates a zero-byte native .download file before done.
      do {
        await this.socket.drain(() => this.job === j && !this.closed);
        const data = new Uint8Array(await j.file.slice(j.bytes, j.bytes + BLOCK).arrayBuffer());
        if (this.job !== j || this.closed) return;
        this.send({file_response: {block: {id: j.id, file_num: 0, data, compressed: false}}});
        j.bytes += data.length; this.touch(); this.change();
      } while (j.bytes < j.size);
      j.awaitingDone = true; this.change(); this.send({file_response: {done: {id: j.id, file_num: 0}}});
    } catch (error) { if (this.job === j) this.cancel(error.message); }
  }
  handle(m) {
    const r = m.file_response;
    if (r?.dir && (r.dir.id || 0) === 0 && this.listing) {
      if (!Array.isArray(r.dir.entries || []) || (r.dir.entries || []).length > 10000) throw Error('file_directory');
      this.path = remotePath(r.dir.path || ''); this.entries = (r.dir.entries || []).filter(e => typeof e.name === 'string' && e.name.length <= 255 && e.name !== '.' && e.name !== '..' && !/[\x00-\x1f/\\]/.test(e.name));
      this.listing = false; clearTimeout(this.listTimer); this.change(); return;
    }
    if (r?.error && (r.error.id || 0) === 0 && this.listing) { this.listing = false; clearTimeout(this.listTimer); this.error = 'file_directory'; this.change(); return; }
    const j = this.job; if (!j) return;
    const confirm = m.file_action?.send_confirm;
    if (confirm?.id === j.id && j.type === 'upload') {
      if ((confirm.file_num || 0) !== 0 || confirm.skip || (confirm.offset_blk || 0) !== 0) return this.cancel('file_exists');
      this.pump(j); return;
    }
    if (!r) return;
    const value = r.dir || r.block || r.error || r.done || r.digest;
    if (value?.id !== j.id) return; // ignore late/cancelled job IDs
    this.touch();
    if (r.error) return this.cancel('file_remote');
    if (r.digest) {
      if ((r.digest.file_num || 0) !== 0) throw Error('file_block');
      if (j.type === 'upload') return this.cancel('file_exists');
      if (fileSize(r.digest.file_size || 0) !== j.size || r.digest.is_upload) throw Error('file_size');
      this.send({file_action: {send_confirm: {id: j.id, file_num: 0, offset_blk: 0}}});
    }
    if (r.dir && j.type === 'download') {
      const [file, ...others] = r.dir.entries || [];
      if (!file || others.length || (file.name && file.name !== j.name) || file.entry_type !== 4 || fileSize(file.size || 0) !== j.size) throw Error('file_size');
      j.described = true;
    }
    if (r.block && j.type === 'download') {
      if (!j.described || (r.block.file_num || 0) !== 0) throw Error('file_block');
      const bytes = fileBlock(r.block.data || new Uint8Array(), r.block.compressed);
      if (j.bytes + bytes.length > j.size) throw Error('file_size');
      j.bytes += bytes.length; if (bytes.length) j.chunks.push(bytes); this.change();
    }
    if (r.done) {
      if (![0, 1].includes(r.done.file_num || 0) || j.bytes !== j.size || (j.type === 'upload' && !j.awaitingDone) || (j.type === 'download' && !j.described)) throw Error('file_size');
      this.result = {name: j.name, type: j.type};
      if (j.type === 'download') this.blob = new Blob(j.chunks, {type: 'application/octet-stream'});
      clearTimeout(this.jobTimer); this.job = null; this.change();
    }
  }
  cancel(error = '') {
    const j = this.job; this.job = null; clearTimeout(this.jobTimer);
    if (j && !this.closed) { try { this.send({file_action: {cancel: {id: j.id}}}); } catch {} }
    this.error = error; this.blob = null; this.change();
  }
  close() {
    if (this.closed) return;
    const error = this.error; this.cancel(); this.error = error; this.closed = true; this.connected = false; this.listing = false; clearTimeout(this.listTimer);
    for (const socket of this.sockets) socket.close();
    if (this.keys) this.keys.forEach(wipe); this.blob = null; this.entries = []; this.change();
  }
}
