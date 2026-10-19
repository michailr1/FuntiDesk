import { FilePanel } from './files-ui.js';
import { Session, errorText } from './session.js';
import { controls, ready } from './protocol.js';
import { Recovery } from './recovery.js';
import { PhoneConsole } from './phone.js';
const $ = (id) => document.getElementById(id);
const canvas = $('screen'); let active; let files; let hadSessionOnHide = false;
let target = '';
try { target = decodeURIComponent(location.hash.slice(1)); } catch { /* Invalid fragments do not prefill a computer. */ }
if (/^[0-9]{6,16}$/.test(target)) $('peer-id').value = target;
if (location.hash) history.replaceState(null, '', location.pathname);
function stop(preserveReload = false) { recovery?.clear(preserveReload); $('password').value = ''; active?.close(); active = null; phone.sync(); files?.sync(); $('connect').disabled = false; $('disconnect').disabled = true; }
async function connect(id, password) {
  const session = new Session(canvas, (text) => { if (active === session) { $('status').textContent = text; phone.sync(); files?.sync(); } });
  session.onFilePermission = () => files?.sync();
  if (recovery) session.onFirstFrame = () => recovery.ready();
  if (phone.enabled) session.onCursor = (point) => phone.remoteCursor(point);
  if (phone.enabled) session.onScreen = () => { phone.cursor = { x: canvas.width / 2, y: canvas.height / 2 }; phone.layout(); };
  active = session; $('connect').disabled = true; $('disconnect').disabled = false;
  try { const result = session.start(id, password, recovery); password = ''; await result; }
  catch (error) {
    if (active !== session) return;
    const code = session.failure || error.message;
    session.close(); active = null; phone.sync(); files?.sync();
    if (recovery?.interrupted(code)) {
      $('status').textContent = 'Соединение прервано. Восстановим его при возвращении в течение 5 минут.';
      recovery.resume();
    } else { stop(); $('status').textContent = errorText(code); }
  }
}
$('connection-form').addEventListener('submit', (event) => {
  event.preventDefault();
  if (location.origin !== 'https://desk.funti.cc' || active) return;
  recovery?.clear();
  let password = $('password').value; $('password').value = '';
  connect($('peer-id').value.trim(), password); password = '';
});
$('disconnect').addEventListener('click', () => { stop(); $('status').textContent = 'Сеанс завершён.'; });
window.addEventListener('pagehide', () => {
  hadSessionOnHide = active?.connected === true && active.firstFrame;
  recovery?.saveReload(); stop(true);
});
window.addEventListener('pageshow', (event) => {
  if (event.persisted) { Recovery.forgetReload(); if (recovery && hadSessionOnHide) $('status').textContent = errorText('recovery_page_restored'); hadSessionOnHide = false; }
});
const buttons = new Set(); const keys = new Map();
const modifier = (e) => [e.altKey && controls.Alt, e.ctrlKey && controls.Control, e.shiftKey && controls.Shift, e.metaKey && controls.Meta].filter(Boolean);
function release() {
  for (const [code, key] of keys) active?.input({ key_event: { ...key, down: false } });
  keys.clear();
  for (const button of buttons) active?.input({ mouse_event: { mask: 2 | (button << 3) } });
  buttons.clear();
}
canvas.addEventListener('blur', release);
window.addEventListener('blur', release);
document.addEventListener('visibilitychange', () => { if (document.hidden) release(); });
canvas.addEventListener('contextmenu', (e) => e.preventDefault());
function mouse(e, type) {
  if (e.pointerType === 'touch' && phone.enabled) return;
  if (!active?.connected) return;
  e.preventDefault();
  if (type === 1) { canvas.focus(); buttons.add([1, 4, 2][e.button]); canvas.setPointerCapture(e.pointerId); }
  if (type === 2) buttons.delete([1, 4, 2][e.button]);
  const rect = canvas.getBoundingClientRect();
  const x = Math.min(canvas.width - 1, Math.max(0, Math.round((e.clientX - rect.left) * canvas.width / rect.width)));
  const y = Math.min(canvas.height - 1, Math.max(0, Math.round((e.clientY - rect.top) * canvas.height / rect.height)));
  active.input({ mouse_event: { mask: type | (type ? [1, 4, 2][e.button] << 3 : 0), x: x + (active.screen.x || 0), y: y + (active.screen.y || 0), modifiers: modifier(e) } });
}
canvas.addEventListener('pointermove', (e) => mouse(e, 0));
canvas.addEventListener('pointerdown', (e) => mouse(e, 1));
canvas.addEventListener('pointerup', (e) => mouse(e, 2));
canvas.addEventListener('pointercancel', release);
canvas.addEventListener('wheel', (e) => {
  if (!active?.connected) return; e.preventDefault();
  active.input({ mouse_event: { mask: 3, x: -Math.sign(e.deltaX), y: -Math.sign(e.deltaY), modifiers: modifier(e) } });
}, { passive: false });
const special = { Enter: 'Return', ArrowLeft: 'LeftArrow', ArrowRight: 'RightArrow', ArrowUp: 'UpArrow', ArrowDown: 'DownArrow', ' ': 'Space', OS: 'Meta' };
function key(e, down) {
  if (!active?.connected) return;
  if ((e.ctrlKey || e.metaKey) && ['w', 't', 'n', 'l'].includes(e.key.toLowerCase())) return;
  const control = controls[special[e.key] || e.key];
  const value = control !== undefined ? { control_key: control } : [...e.key].length === 1 ? { chr: e.key.codePointAt(0) } : null;
  if (!value) return;
  e.preventDefault();
  const event = { ...value, modifiers: modifier(e), mode: 0 };
  if (down) keys.set(e.code, event); else keys.delete(e.code);
  active.input({ key_event: { ...event, down } });
}
canvas.addEventListener('keydown', (e) => key(e, true));
canvas.addEventListener('keyup', (e) => key(e, false));
const phone = new PhoneConsole(canvas, () => active, () => $('disconnect').click());
files = new FilePanel(() => active, () => {phone.reset();$('phone-panel').hidden = true;$('phone-text').blur();$('phone-keys').hidden = true;});

const recovery = phone.enabled ? new Recovery((id) => connect(id, null), () => { stop(); $('status').textContent = errorText('recovery_expired'); }) : null;

await ready;
const restored = recovery?.restoreReload(target);
if (restored === true) {
  $('peer-id').value = recovery.auth.id;
  recovery.resume();
} else {
  Recovery.forgetReload();
  if (typeof restored === 'string') $('status').textContent = errorText(restored);
}
