import { passwordKey, challengeProof, wipe } from './protocol.js';
const WINDOW = 5 * 60 * 1000;
const transient = new Set(['connection_closed', 'network_error', 'network_timeout']);

export class Recovery {
  constructor(reconnect, expired) {
    this.reconnect = reconnect; this.expired = expired; this.clear();
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) { if (this.auth) { if (this.auth.confirmed && !this.waiting) this.attempted = false; this.arm(); } }
      else { if (this.deadline && Date.now() >= this.deadline) this.expire(); else if (this.waiting) this.resume(); else if (this.auth?.confirmed) this.ready(); }
    });
  }
  clear() {
    clearTimeout(this.timer); wipe(this.auth?.salted);
    this.auth = null; this.deadline = 0; this.waiting = false; this.attempted = false;
  }
  arm() {
    if (this.deadline) return;
    this.deadline = Date.now() + WINDOW;
    this.timer = setTimeout(() => this.expire(), WINDOW);
  }
  expire() { this.clear(); this.expired(); }
  valid() { return !!this.auth?.confirmed && (!this.deadline || Date.now() < this.deadline); }
  async proof(id, peerKey, salt, challenge, password) {
    if (password !== null) {
      this.clear();
      const auth = { id, peerKey: peerKey.slice(), salt, clientId: 'web-' + crypto.randomUUID(), sessionId: crypto.getRandomValues(new Uint32Array(1))[0] || 1 };
      this.auth = auth;
      const salted = await passwordKey(password, salt);
      if (this.auth !== auth) { wipe(salted); throw new Error('recovery_expired'); }
      auth.salted = salted;
    } else if (!this.valid()) throw new Error('recovery_expired');
    const auth = this.auth; auth.confirmed = false;
    if (auth.id !== id || auth.salt !== salt || !auth.peerKey.every((n, i) => n === peerKey[i])) throw new Error('recovery_unavailable');
    const proof = await challengeProof(auth.salted, challenge);
    if (this.auth !== auth || (this.deadline && Date.now() >= this.deadline)) { wipe(proof); throw new Error('recovery_expired'); }
    return proof;
  }
  authorize() {
    if (!this.auth || (this.deadline && Date.now() >= this.deadline)) throw new Error('recovery_expired');
  }
  ready() {
    this.authorize(); this.auth.confirmed = true; this.waiting = false;
    if (!document.hidden) { clearTimeout(this.timer); this.deadline = 0; } else this.arm();
  }
  interrupted(code) {
    if (!transient.has(code) || !this.valid() || this.attempted) return false;
    this.waiting = true; this.arm(); return true;
  }
  resume() {
    if (!this.waiting || document.hidden) return;
    if (!this.valid()) { this.expire(); return; }
    this.waiting = false; this.attempted = true; this.reconnect(this.auth.id);
  }
}
