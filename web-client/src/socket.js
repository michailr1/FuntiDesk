import { encode, decode, encrypt, decrypt, wire } from './protocol.js';

export class Socket {
  constructor(url, type, create = (uri) => new WebSocket(uri)) {
    this.type = type; this.queue = []; this.waiter = null; this.closed = false;
    this.queuedBytes = 0; this.sendCount = 0; this.receiveCount = 0; this.keys = null;
    this.ws = create(url); this.ws.binaryType = 'arraybuffer';
    this.opened = new Promise((resolve, reject) => {
      this.openTimer = setTimeout(() => { this.close('network_timeout'); reject(new Error('network_timeout')); }, 15000);
      this.ws.onopen = () => { clearTimeout(this.openTimer); resolve(); };
      this.ws.onerror = () => { reject(new Error('network_error')); this.close('network_error'); };
      this.ws.onclose = () => { reject(new Error('connection_closed')); this.close(); };
    });
    this.ws.onmessage = (event) => {
      try {
        if (!(event.data instanceof ArrayBuffer) || event.data.byteLength > 16 * 1024 * 1024) throw new Error('invalid_message');
        let bytes = new Uint8Array(event.data);
        if (this.keys) bytes = decrypt(bytes, ++this.receiveCount, this.keys[1]);
        const value = decode(this.type, bytes);
        if (this.waiter) { const pending = this.waiter; this.waiter = null; clearTimeout(pending.timer); pending.resolve(value); }
        else { if (this.queue.length >= 128 || this.queuedBytes + event.data.byteLength > 32 * 1024 * 1024) throw new Error('message_overflow'); this.queue.push({ value, size: event.data.byteLength }); this.queuedBytes += event.data.byteLength; }
      } catch { this.close('invalid_message'); }
    };
  }
  send(value) {
    if (this.closed || this.ws.readyState !== 1) throw new Error('connection_closed');
    if (this.ws.bufferedAmount > 1024 * 1024) { this.close('message_overflow'); throw new Error('message_overflow'); }
    let bytes = encode(this.type, value);
    if (this.keys) bytes = encrypt(bytes, ++this.sendCount, this.keys[0]);
    this.ws.send(bytes);
  }
  async next(timeout = 30000) {
    if (this.closed) throw new Error(this.reason || 'connection_closed');
    if (this.queue.length) { const next = this.queue.shift(); this.queuedBytes -= next.size; return next.value; }
    if (this.waiter) throw new Error('concurrent_read');
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.close('network_timeout'); reject(new Error('network_timeout')); }, timeout);
      this.waiter = { resolve, reject, timer };
    });
  }
  secure(keys) {
    if (this.queue.length || this.keys || this.type !== wire) throw new Error('invalid_handshake');
    this.keys = keys;
  }
  close(reason = 'connection_closed') {
    if (this.closed) return;
    this.closed = true; this.reason = reason; clearTimeout(this.openTimer);
    if (this.waiter) { clearTimeout(this.waiter.timer); this.waiter.reject(new Error(reason)); this.waiter = null; }
    this.queue = []; this.queuedBytes = 0;
    this.ws.onmessage = null; this.ws.onclose = null; this.ws.onerror = null;
    this.ws.close();
  }
}
