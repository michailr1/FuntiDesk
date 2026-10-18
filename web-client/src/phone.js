import { controls } from './protocol.js';
const $ = (id) => document.getElementById(id);
const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));
const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

export class PhoneConsole {
  constructor(canvas, session, disconnect) {
    this.canvas = canvas; this.session = session;
    this.enabled = matchMedia('(pointer: coarse)').matches;
    this.points = new Map(); this.mods = new Map(); this.modTimes = new Map();
    this.mode = 'pad'; this.zoom = 1; this.fit = true; this.pan = { x: 0, y: 0 };
    this.cursor = { x: 0, y: 0 }; this.shown = false; this.hinted = false;
    $('phone-end').onclick = disconnect;
    $('phone-menu').onclick = () => { if (!this.menuMoved) $('phone-panel').hidden = !$('phone-panel').hidden; };
    $('phone-mode').onchange = () => { this.reset(); this.mode = $('phone-mode').value; };
    $('phone-fit').onclick = () => { this.fit = true; this.pan = { x: 0, y: 0 }; this.layout(); };
    $('phone-actual').onclick = () => { this.fit = false; this.zoom = 1; this.pan = { x: 0, y: 0 }; this.layout(); };
    $('phone-zoom').oninput = () => { this.fit = false; this.zoom = Number($('phone-zoom').value) / 100; this.layout(); };
    $('phone-keyboard').onclick = () => { $('phone-keys').hidden = false; $('phone-panel').hidden = true; this.layout(); $('phone-text').focus({ preventScroll: true }); };
    $('phone-keys-close').onclick = () => { $('phone-text').blur(); $('phone-keys').hidden = true; this.layout(); };
    $('phone-help').onclick = () => this.help();
    $('phone-help-close').onclick = () => $('phone-help-sheet').close();
    $('phone-cad').onclick = () => { if (confirm('Отправить Ctrl+Alt+Del на компьютер?')) this.key('CtrlAltDel'); };
    $('phone-quality').onchange = () => this.session()?.configure({ option: { image_quality: Number($('phone-quality').value) } });
    $('phone-monitor').onchange = () => { this.reset(); this.pan = { x: 0, y: 0 }; this.session()?.configure({ switch_display: { display: Number($('phone-monitor').value) } }); };
    const names = [['Esc', 'Escape'], ['Tab', 'Tab'], ['Ctrl', 'Control'], ['Alt', 'Alt'], ['Shift', 'Shift'], ['Win', 'Meta'], ['←', 'LeftArrow'], ['↑', 'UpArrow'], ['↓', 'DownArrow'], ['→', 'RightArrow'], ['Del', 'Delete'], ['⌫', 'Backspace'], ['Enter', 'Return']];
    for (let i = 1; i <= 12; i++) names.push(['F' + i, 'F' + i]);
    for (const [label, name] of names) {
      const button = document.createElement('button'); button.type = 'button'; button.textContent = label; button.dataset.key = name;
      button.onpointerdown = (e) => e.preventDefault(); button.onclick = () => this.key(name); $('phone-key-buttons').append(button);
    }
    for (const letter of ['a', 'c', 'v', 'x', 'z']) {
      const button = document.createElement('button'); button.type = 'button'; button.textContent = 'Ctrl+' + letter.toUpperCase();
      button.onpointerdown = (e) => e.preventDefault(); button.onclick = () => this.press({ chr: letter.codePointAt(0) }, [controls.Control]); $('phone-key-buttons').append(button);
    }
    $('phone-text').addEventListener('input', (e) => { if (!e.isComposing) this.text(); });
    $('phone-text').addEventListener('compositionend', () => this.text());
    $('phone-text').addEventListener('keydown', (e) => {
      if (['Backspace', 'Enter', 'Tab'].includes(e.key) && !e.isComposing) { e.preventDefault(); this.key(e.key === 'Enter' ? 'Return' : e.key); }
    });
    $('phone-text').addEventListener('beforeinput', (e) => {
      if (e.isComposing) return;
      const key = { deleteContentBackward: 'Backspace', insertLineBreak: 'Return', insertParagraph: 'Return' }[e.inputType];
      if (key) { e.preventDefault(); this.key(key); }
    });
    // TouchEvent samples both fingers together; separate pointer moves can look like a pinch.
    for (const [type, phase] of [['touchstart', 'pointerdown'], ['touchmove', 'pointermove'], ['touchend', 'pointerup'], ['touchcancel', 'pointercancel']]) canvas.addEventListener(type, (event) => {
      if (!this.enabled || !this.shown) return;
      event.preventDefault();
      if (type === 'touchcancel') { this.reset(); return; }
      if (type === 'touchmove') for (const t of event.touches) this.points.set(t.identifier, { x: t.clientX, y: t.clientY });
      for (const t of event.changedTouches) this.pointer({ type: phase, pointerType: 'touch', pointerId: t.identifier, clientX: t.clientX, clientY: t.clientY, preventDefault() {} });
    }, { passive: false });
    const menu = $('phone-menu'); let drag;
    menu.onpointerdown = (e) => { drag = { x: e.clientX, y: e.clientY, left: menu.offsetLeft, top: menu.offsetTop }; this.menuMoved = false; menu.setPointerCapture(e.pointerId); };
    menu.onpointermove = (e) => {
      if (!drag) return;
      if (Math.hypot(e.clientX - drag.x, e.clientY - drag.y) > 8) this.menuMoved = true;
      if (this.menuMoved) { menu.style.left = clamp(drag.left + e.clientX - drag.x, 0, innerWidth - menu.offsetWidth) + 'px'; menu.style.top = clamp(drag.top + e.clientY - drag.y, 0, innerHeight - menu.offsetHeight) + 'px'; }
    };
    menu.onpointerup = menu.onpointercancel = () => { drag = null; };
    window.addEventListener('resize', () => { this.reset(); this.layout(); });
    visualViewport?.addEventListener('resize', () => this.layout());
    visualViewport?.addEventListener('scroll', () => this.layout());
    window.addEventListener('blur', () => this.reset());
    document.addEventListener('visibilitychange', () => { this.reset(); if (document.hidden) this.unlock(); else this.wake(); });
  }
  sync() {
    const show = this.enabled && this.session()?.connected === true;
    $('phone-state').textContent = $('status').textContent;
    if (show && this.session().keyboard === false) this.reset();
    if (show === this.shown) { this.renderCursor(); return; }
    this.shown = show; document.body.classList.toggle('phone-session', show); $('phone-ui').hidden = !show;
    this.reset();
    if (!show) {
      $('phone-cursor').hidden = true; $('phone-help-sheet').close();
      this.unlock(); $('phone-text').value = ''; $('phone-text').blur(); $('phone-keys').hidden = true;
      for (const name of ['width', 'height', 'transform']) this.canvas.style.removeProperty(name);
      return;
    }
    this.cursor = { x: this.canvas.width / 2, y: this.canvas.height / 2 };
    $('phone-panel').hidden = true; this.fit = true; this.pan = { x: 0, y: 0 }; this.layout(); this.wake();
    $('phone-monitor').replaceChildren();
    for (const [i] of (this.session().displays || []).entries()) {
      const option = document.createElement('option'); option.value = String(i); option.textContent = 'Монитор ' + (i + 1); $('phone-monitor').append(option);
    }
    $('phone-monitor').value = String(this.session().display || 0);
    if (!this.hinted) { this.hinted = true; this.help(); }
  }
  help() {
    this.reset(); $('phone-panel').hidden = true;
    $('phone-text').blur(); $('phone-keys').hidden = true; this.layout();
    if (!$('phone-help-sheet').open) $('phone-help-sheet').showModal();
  }
  async wake() {
    if (!this.shown || document.hidden || this.lock || this.waking || !navigator.wakeLock) return;
    this.waking = true;
    try { const lock = await navigator.wakeLock.request('screen'); if (this.shown && !document.hidden) { this.lock = lock; lock.addEventListener('release', () => { if (this.lock === lock) this.lock = null; }); } else await lock.release(); } catch { /* Wake Lock is optional. */ }
    finally { this.waking = false; }
  }
  unlock() { const lock = this.lock; this.lock = null; if (lock) lock.release().catch(() => {}); }
  layout() {
    if (!this.shown) return;
    const visibleHeight = visualViewport?.height || innerHeight, top = visualViewport?.offsetTop || 0;
    const height = Math.max(1, visibleHeight - ($('phone-keys').hidden ? 0 : $('phone-keys').offsetHeight));
    $('remote-stage').style.top = top + 'px'; $('remote-stage').style.height = height + 'px';
    $('phone-keys').style.bottom = Math.max(0, innerHeight - visibleHeight - top) + 'px';
    const fit = Math.min(innerWidth / this.canvas.width, height / this.canvas.height);
    $('phone-zoom').max = String(Math.round(Math.max(4, fit * 4) * 100));
    if (this.fit) this.zoom = fit;
    this.pan.x = clamp(this.pan.x, -Math.max(0, (this.canvas.width * this.zoom - innerWidth) / 2), Math.max(0, (this.canvas.width * this.zoom - innerWidth) / 2));
    this.pan.y = clamp(this.pan.y, -Math.max(0, (this.canvas.height * this.zoom - height) / 2), Math.max(0, (this.canvas.height * this.zoom - height) / 2));
    this.canvas.style.width = this.canvas.width * this.zoom + 'px'; this.canvas.style.height = this.canvas.height * this.zoom + 'px';
    this.canvas.style.transform = `translate(${this.pan.x}px,${this.pan.y}px)`; $('phone-zoom').value = String(Math.round(this.zoom * 100));
    const menu = $('phone-menu'); menu.style.left = clamp(menu.offsetLeft, 0, innerWidth - menu.offsetWidth) + 'px'; menu.style.top = clamp(menu.offsetTop, top, top + height - menu.offsetHeight) + 'px';
    this.renderCursor();
  }
  remoteCursor(point) {
    const screen = this.session()?.screen || {};
    this.cursor = { x: (point.x || 0) - (screen.x || 0), y: (point.y || 0) - (screen.y || 0) }; this.renderCursor();
  }
  renderCursor() {
    const marker = $('phone-cursor');
    marker.hidden = !this.shown || this.session()?.keyboard === false || this.cursor.x < 0 || this.cursor.y < 0 || this.cursor.x >= this.canvas.width || this.cursor.y >= this.canvas.height;
    if (marker.hidden) return;
    const rect = this.canvas.getBoundingClientRect(), stage = $('remote-stage').getBoundingClientRect();
    marker.style.left = rect.left - stage.left + clamp(Math.round(this.cursor.x), 0, this.canvas.width - 1) * this.zoom + 'px';
    marker.style.top = rect.top - stage.top + clamp(Math.round(this.cursor.y), 0, this.canvas.height - 1) * this.zoom + 'px';
  }
  mouse(type, button = 0, point = this.cursor) {
    this.renderCursor();
    const session = this.session(); if (!session) return;
    const x = clamp(Math.round(point.x), 0, this.canvas.width - 1), y = clamp(Math.round(point.y), 0, this.canvas.height - 1);
    session.input({ mouse_event: { mask: type | (button << 3), x: x + (session.screen.x || 0), y: y + (session.screen.y || 0) } });
  }
  click(button) { this.mouse(1, button); this.mouse(2, button); }
  reset() {
    clearTimeout(this.hold); if (this.dragging) this.mouse(2, 1);
    this.dragging = false; this.points.clear(); this.group = null; this.tap = null; this.mods.clear(); this.updateMods();
  }
  updateMods() { for (const b of $('phone-key-buttons').querySelectorAll('[data-key]')) { b.setAttribute('aria-pressed', String(this.mods.has(b.dataset.key))); b.classList.toggle('locked', this.mods.get(b.dataset.key) === 2); } }
  key(name) {
    if (name === 'CtrlAltDel') { this.session()?.input({ key_event: { control_key: controls.CtrlAltDel, press: true, mode: 0 } }); return; }
    if (['Control', 'Alt', 'Shift', 'Meta'].includes(name)) {
      const time = performance.now(), double = time - (this.modTimes.get(name) ?? -1000) < 350;
      if (this.mods.has(name) && (!double || this.mods.get(name) === 2)) this.mods.delete(name); else this.mods.set(name, double ? 2 : 1);
      this.modTimes.set(name, time); this.updateMods(); return;
    }
    this.press({ control_key: controls[name] });
  }
  press(value, modifiers = [...this.mods.keys()].map((name) => controls[name])) {
    for (const down of [true, false]) this.session()?.input({ key_event: { ...value, modifiers, down, mode: 0 } });
    for (const [name, state] of this.mods) if (state === 1) this.mods.delete(name);
    this.modTimes.clear();
    this.updateMods();
  }
  text() {
    const text = $('phone-text').value; $('phone-text').value = ''; if (!text) return;
    if (this.mods.size && [...text].length === 1) this.press({ chr: text.codePointAt(0) });
    else this.session()?.input({ key_event: { seq: text, mode: 0 } });
  }
  pointer(e) {
    if (!this.enabled || !this.shown || e.pointerType !== 'touch') return;
    e.preventDefault(); const point = { x: e.clientX, y: e.clientY }, time = performance.now();
    if (e.type === 'pointercancel') { this.reset(); return; }
    if (e.type === 'pointerdown') {
      this.points.set(e.pointerId, point);
      if (this.points.size === 1) {
        this.start = point; this.last = point; this.started = time; this.moved = false; this.right = false;
        if (this.mode === 'touch') {
          const r = this.canvas.getBoundingClientRect(); this.cursor = { x: (point.x - r.left) / this.zoom, y: (point.y - r.top) / this.zoom }; this.mouse(0);
          this.hold = setTimeout(() => { this.click(2); this.right = true; }, 550);
        }
        if (this.tap && time - this.tap.time < 300 && distance(point, this.tap) < 32) { clearTimeout(this.hold); this.mouse(1, 1); this.dragging = true; }
      } else {
        clearTimeout(this.hold); if (this.dragging) this.mouse(2, 1); this.dragging = false;
        const [a, b] = [...this.points.values()]; this.group = { distance: distance(a, b), zoom: this.zoom, pan: { ...this.pan }, x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, lastY: (a.y + b.y) / 2, moved: false };
      }
      return;
    }
    if (!this.points.has(e.pointerId)) return;
    if (e.type === 'pointermove') {
      this.points.set(e.pointerId, point);
      if (this.group) {
        if (this.points.size !== 2) return;
        const [a, b] = [...this.points.values()], g = this.group, x = (a.x + b.x) / 2, y = (a.y + b.y) / 2;
        const ratio = distance(a, b) / Math.max(1, g.distance);
        if (Math.hypot(x - g.x, y - g.y) > 8 || Math.abs(ratio - 1) > .06) g.moved = true;
        if (Math.abs(ratio - 1) > .06) g.pinch = true;
        const fit = Math.min(innerWidth / this.canvas.width, (visualViewport?.height || innerHeight) / this.canvas.height);
        if (g.pinch || this.zoom > fit * 1.05) {
          this.fit = false; this.zoom = clamp(g.zoom * (g.pinch ? ratio : 1), .01, Math.max(4, fit * 4));
          this.pan = { x: g.pan.x + x - g.x, y: g.pan.y + y - g.y }; this.layout();
        } else if (Math.abs(y - g.lastY) >= 12) { this.session()?.input({ mouse_event: { mask: 3, x: 0, y: -Math.sign(y - g.lastY) } }); g.lastY = y; }
      } else {
        if (distance(point, this.start) > 8) { this.moved = true; clearTimeout(this.hold); }
        if (this.mode === 'pad') { this.cursor.x += (point.x - this.last.x) / this.zoom; this.cursor.y += (point.y - this.last.y) / this.zoom; }
        else { const r = this.canvas.getBoundingClientRect(); this.cursor = { x: (point.x - r.left) / this.zoom, y: (point.y - r.top) / this.zoom }; }
        this.cursor.x = clamp(this.cursor.x, 0, this.canvas.width - 1); this.cursor.y = clamp(this.cursor.y, 0, this.canvas.height - 1);
        this.last = point; this.mouse(0);
      }
      return;
    }
    this.points.delete(e.pointerId); clearTimeout(this.hold);
    if (this.points.size) return;
    if (this.group) { if (!this.group.moved && time - this.started < 350) this.click(2); this.group = null; this.tap = null; }
    else if (this.dragging) { this.mouse(2, 1); this.dragging = false; this.tap = null; }
    else if (!this.moved && !this.right && time - this.started < 500) { this.click(1); this.tap = { ...point, time }; }
  }
}
