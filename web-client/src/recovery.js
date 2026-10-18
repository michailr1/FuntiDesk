import { passwordKey, challengeProof, wipe } from './protocol.js';
const WINDOW = 5 * 60 * 1000;
const RELOAD = 'funtidesk.phone-reload.v1';
const ATTEMPT = 'funtidesk.phone-reload.attempt';
const bytes = (value) => Array.isArray(value) && value.length === 32 && value.every((n) => Number.isInteger(n) && n >= 0 && n <= 255);
const transient = new Set(['connection_closed', 'network_error', 'network_timeout']);

export class Recovery {
  constructor(reconnect, expired) {
    this.reconnect = reconnect; this.expired = expired; this.clear(true);
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) { if (this.auth) { if (this.auth.confirmed && !this.waiting && !this.recovering) this.attempted = false; this.arm(); } }
      else { if (this.deadline && Date.now() >= this.deadline) this.expire(); else if (this.waiting) this.resume(); else if (this.auth?.confirmed && !this.recovering) this.ready(); }
    });
  }
  static forgetReload() { try { sessionStorage.removeItem(RELOAD); sessionStorage.removeItem(ATTEMPT); } catch { /* Storage may be unavailable. */ } }
  clear(preserveReload = false) {
    if (!preserveReload) Recovery.forgetReload();
    clearTimeout(this.timer); wipe(this.auth?.salted);
    this.auth = null; this.deadline = 0; this.waiting = false; this.attempted = false; this.recovering = false;
  }
  saveReload() {
    Recovery.forgetReload();
    if (location.origin !== 'https://desk.funti.cc' || this.recovering || !this.valid()) return;
    const { id, peerKey, salt, salted, clientId, sessionId } = this.auth;
    const createdAt = Date.now(), expiresAt = this.deadline || createdAt + WINDOW;
    try {
      // This derived credential is password-equivalent. Never store a cleartext password.
      sessionStorage.setItem(ATTEMPT, String(createdAt));
      sessionStorage.setItem(RELOAD, JSON.stringify({ version: 1, id, peerKey: [...peerKey], salt,
        salted: [...salted], clientId, sessionId, createdAt, expiresAt }));
    } catch { try { sessionStorage.removeItem(RELOAD); } catch { /* Keep only the non-secret attempt marker, if saved. */ } }
  }
  static navigationType() {
    const type = performance.getEntriesByType?.('navigation')?.[0]?.type;
    // Safari versions/settings without Navigation Timing 2 still expose the same
    // reload/back-forward distinction through the legacy Navigation Timing API.
    return type ?? ({ 0: 'navigate', 1: 'reload', 2: 'back_forward' })[performance.navigation?.type];
  }
  restoreReload(target) {
    const navigation = Recovery.navigationType();
    let raw, attempt;
    try {
      raw = sessionStorage.getItem(RELOAD); attempt = sessionStorage.getItem(ATTEMPT);
      sessionStorage.removeItem(RELOAD); sessionStorage.removeItem(ATTEMPT);
    }
    catch { return navigation === 'reload' ? 'recovery_storage_unavailable' : false; }
    if (location.origin !== 'https://desk.funti.cc') return false;
    if (navigation !== 'reload') return raw && !navigation ? 'recovery_navigation_unavailable' : false;
    if (!raw) {
      const savedAt = Number(attempt), now = Date.now();
      return attempt && Number.isSafeInteger(savedAt) && savedAt <= now && now - savedAt <= WINDOW ? 'recovery_missing' : false;
    }
    if (raw.length > 4096) return 'recovery_unavailable';
    try {
      const value = JSON.parse(raw), now = Date.now();
      if (value.version !== 1 || typeof value.id !== 'string' || !/^[0-9]{6,16}$/.test(value.id) || (target && target !== value.id) ||
          typeof value.salt !== 'string' || !value.salt || value.salt.length > 256 || !bytes(value.peerKey) || !bytes(value.salted) ||
          typeof value.clientId !== 'string' || !/^web-[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value.clientId) ||
          !Number.isInteger(value.sessionId) || value.sessionId < 1 || value.sessionId > 0xffffffff ||
          !Number.isSafeInteger(value.createdAt) || !Number.isSafeInteger(value.expiresAt) ||
          value.createdAt > now || value.expiresAt <= value.createdAt || value.expiresAt - value.createdAt > WINDOW) return 'recovery_unavailable';
      if (value.expiresAt <= now) return 'recovery_expired';
      this.auth = { id: value.id, peerKey: Uint8Array.from(value.peerKey), salt: value.salt,
        salted: Uint8Array.from(value.salted), clientId: value.clientId, sessionId: value.sessionId, confirmed: true };
      this.deadline = value.expiresAt; this.waiting = true;
      this.timer = setTimeout(() => this.expire(), value.expiresAt - now);
      return true;
    } catch { return 'recovery_unavailable'; }
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
    this.authorize(); this.auth.confirmed = true; this.waiting = false; this.recovering = false;
    if (!document.hidden) { clearTimeout(this.timer); this.deadline = 0; } else this.arm();
  }
  interrupted(code) {
    if (!transient.has(code) || !this.valid() || this.attempted) return false;
    this.waiting = true; this.arm(); return true;
  }
  resume() {
    if (!this.waiting || document.hidden) return;
    if (!this.valid()) { this.expire(); return; }
    this.waiting = false; this.attempted = true; this.recovering = true; this.reconnect(this.auth.id);
  }
}
