import {Files} from './files.js';
import {LIMIT, fileSize, fileName, joinPath} from './file-codec.js';
import {errorText} from './session.js';
const $ = id => document.getElementById(id);
const collator = new Intl.Collator('ru', {numeric:true, sensitivity:'base'});
const directory = e => [0,2,3].includes(e.entry_type || 0);
export function displayEntries(entries, query = '', sort = 'name') {
  const text = query.trim().toLocaleLowerCase('ru');
  return entries.filter(e => e.name.toLocaleLowerCase('ru').includes(text)).sort((a,b) =>
    Number(directory(b)) - Number(directory(a)) ||
    (sort === 'size' && !directory(a) ? (b.size || 0) - (a.size || 0) : sort === 'date' ? (b.modified_time || 0) - (a.modified_time || 0) : 0) ||
    (sort === 'reverse' ? -1 : 1) * collator.compare(a.name,b.name));
}
export function displaySize(value = 0) {
  if (!Number.isSafeInteger(value) || value < 0) return 'Размер неизвестен';
  const unit = value >= 1048576 ? 2 : value >= 1024 ? 1 : 0;
  return new Intl.NumberFormat('ru', {maximumFractionDigits:1}).format(value / 1024 ** unit) + ' ' + ['Б','КБ','МБ'][unit];
}
function text(tag, value, className) { const node = document.createElement(tag); node.textContent = value; if(className)node.className = className; return node; }
function icon(type) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg','svg'), path = document.createElementNS(svg.namespaceURI,'path');
  svg.setAttribute('viewBox','0 0 24 24'); svg.setAttribute('aria-hidden','true'); svg.classList.add('files-icon');
  path.setAttribute('d', type === 3 ? 'M3 5h18v14H3z M6 15h2 M17 15h1' : directory({entry_type:type}) ? 'M3 7V4h6l3 3h9v13H3z' : 'M14 3H5v18h14V8z M14 3v6h5');
  svg.append(path); return svg;
}
const messages = {file_size:'Один файл — не больше 50 МБ.',file_name:'Выберите другое имя файла без служебных символов.',file_exists:'Файл с таким именем уже есть. Укажите другое имя: перезапись не выполнялась.',files_denied:'Компьютер не разрешил файловый сеанс. Проверьте пароль и право передачи файлов.',file_directory:'Не удалось открыть папку. Проверьте путь и права доступа.',file_busy:'Дождитесь завершения или отмените текущую передачу.',file_remote:'Компьютер отклонил передачу. Проверьте имя, папку и права доступа.',file_block:'Компьютер прислал некорректные данные файла.',file_compression:'Не удалось проверить сжатый блок файла.',file_path:'Откройте папку для отправки файла.'};
export class FilePanel {
  constructor(session, beforeOpen = () => {}) {
    this.session = session; this.beforeOpen = beforeOpen; this.dialog = $('files-dialog');
    for (const id of ['files-open','phone-files']) $(id).onclick = () => this.open();
    $('files-close').onclick = () => this.close(); this.dialog.oncancel = e => {e.preventDefault();this.close();};
    $('files-login').onsubmit = e => {e.preventDefault();this.login();};
    $('files-folder-form').onsubmit = e => {e.preventDefault();this.act(() => {this.client.list($('files-path').value);$('files-location').open = false;});};
    $('files-home').onclick = () => this.act(() => this.client.list(''));
    $('files-drives').onclick = () => this.act(() => this.client.list('/'));
    $('files-refresh').onclick = () => this.act(() => this.client.list(this.client.path));
    $('files-up').onclick = () => this.act(() => {
      const path = this.client.path.replace(/[\\/]+$/, '');
      this.client.list(/^[A-Za-z]:$/.test(path) ? '/' : path.replace(/[\\/][^\\/]*$/, '') || '/');
    });
    for (const id of ['files-search','files-sort']) $(id).oninput = () => {this.entries = null;this.render();};
    $('files-choose').onclick = () => $('files-pick').click();
    $('files-unpick').onclick = () => {this.unpick();this.render();};
    $('files-pick').onchange = () => {
      const file = $('files-pick').files[0]; if(!file)return;
      this.client.blob = null; this.release(); $('files-name').value = file.name;
      try {fileSize(file.size);} catch(error) {this.unpick();this.error(error);return;}
      this.render();
    };
    $('files-upload').onsubmit = e => {e.preventDefault();this.act(() => {
      const file = $('files-pick').files[0]; if (!file) throw Error('file_name');
      const name = fileName($('files-name').value); fileSize(file.size);
      if (this.client.entries?.some(v => v.name.toLocaleLowerCase() === name.toLocaleLowerCase())) throw Error('file_exists');
      this.release(); this.client.upload(file,name);
    });};
    $('files-cancel').onclick = () => this.client?.cancel();
    this.sync();
  }
  message(text) { const node = $(this.client?.connected ? 'files-status' : 'files-login-status'); if(node.textContent !== text)node.textContent = text; }
  error(error) { this.message(messages[error.message] || errorText(error.message)); }
  act(action) { try { action(); } catch(error) { this.error(error); } }
  sync() {
    const s = this.session(), enabled = s?.connected && s.filesAllowed === true;
    for (const id of ['files-open','phone-files']) $(id).hidden = !enabled;
    if (this.dialog.open && (!enabled || s !== this.owner)) this.close();
  }
  open() {
    const s = this.session(); if (!s?.connected || !s.filesAllowed) return;
    this.close(); this.owner = s; this.beforeOpen(); this.connecting = false;
    $('files-id').value = s.id; $('files-password').value = '';
    $('files-computer').textContent = 'Компьютер ' + s.id;
    $('files-pick').value = ''; $('files-name').value = ''; $('files-path').value = '';
    this.render(); this.dialog.showModal(); $('files-password').focus();
  }
  async login() {
    if (this.connecting || this.client?.connected) return;
    this.client?.close();
    const c = new Files(() => { if (this.client === c) this.render(); }); this.client = c;
    this.connecting = true; let password = $('files-password').value; $('files-password').value = ''; $('files-password').blur(); this.render();
    try {
      const attempt = c.connect(this.owner.id,password,this.owner.peerKey); password = ''; await attempt;
      if (this.client !== c || !this.dialog.open) return;
      this.connecting = false; this.render();
    } catch(error) { if (this.client === c) {this.connecting = false;this.render();this.error(error);} }
    finally { password = ''; }
  }
  release() {
    if (this.url) URL.revokeObjectURL(this.url);
    this.url = null; this.blob = null; $('files-save').hidden = true; $('files-save').removeAttribute('href'); $('files-save').removeAttribute('download');
    $('files-save-help').hidden = true;
  }
  unpick() { $('files-pick').value = ''; $('files-name').value = ''; $('files-rename').open = false; }
  breadcrumbs(path) {
    const nav = $('files-breadcrumbs'); nav.replaceChildren();
    const windows = /^[A-Za-z]:[\\/]/.test(path), separator = windows ? '\\' : '/', parts = path.split(/[\\/]/).filter(Boolean);
    // UNC has a share root; don't offer the unsupported server-only path.
    if(path.startsWith('\\\\') && parts.length > 1)parts.splice(0,2,'\\\\' + parts.slice(0,2).join('\\'));
    if(!windows && !path.startsWith('\\\\') && path.startsWith('/'))parts.unshift('');
    parts.forEach((part,i) => {
      const target = parts.slice(0,i+1).join(separator) + (windows && i === 0 ? '\\' : '') || '/';
      const button = text('button',part || '/', 'files-crumb'); button.type = 'button'; button.title = target;
      button.disabled = !!this.client.job || this.client.listing;
      if(i === parts.length-1)button.setAttribute('aria-current','location');
      button.onclick = () => this.act(() => this.client.list(target));
      if(i)nav.append(text('span','›')); nav.append(button);
    });
    if(!parts.length)nav.append(text('span','Диски компьютера'));
    nav.scrollLeft = nav.scrollWidth;
  }
  renderList(c, busy) {
    const list = $('files-list'), scroll = $('files-scroll'); list.replaceChildren();
    const entries = displayEntries(c.entries || [],$('files-search').value,$('files-sort').value); let previous;
    for (const entry of entries) {
      const type = entry.entry_type || 0, group = directory(entry) ? 'Папки' : 'Файлы';
      if(group !== previous) {list.append(text('li',group,'files-group'));previous = group;}
      const row = document.createElement('li'), button = document.createElement('button'); button.type = 'button';
      const unsupported = ![0,3,4].includes(type), large = type === 4 && (!Number.isSafeInteger(entry.size || 0) || entry.size < 0 || entry.size > LIMIT);
      button.className = directory(entry) ? 'files-row files-directory' : 'files-row'; button.disabled = busy || unsupported || large;
      const label = text('span','','files-label'); label.append(text('span',entry.name,'files-name'),text('small',unsupported ? 'Ссылка · недоступна' : large ? 'Больше 50 МБ · недоступен' : type === 3 ? 'Диск' : type === 0 ? 'Папка' : displaySize(entry.size)));
      button.append(icon(type),label,text('span',directory(entry) ? '›' : '↓','files-row-action'));
      button.setAttribute('aria-label',`${directory(entry) ? 'Открыть папку' : 'Скачать'} ${entry.name}${large ? ': больше 50 МБ' : unsupported ? ': недоступно' : ''}`);
      button.onclick = () => this.act(() => {c.blob = null;this.release();this.unpick();if(type === 4)c.download({...entry,size:entry.size || 0});else c.list(type === 3 ? entry.name + '\\' : joinPath(c.path,entry.name));});
      row.append(button); list.append(row);
    }
    $('files-empty').hidden = entries.length > 0 || busy;
    $('files-empty').textContent = $('files-search').value.trim() ? 'Ничего не найдено в этой папке' : 'Папка пуста';
    if(this.entries !== c.entries || this.query !== $('files-search').value)scroll.scrollTop = 0;
    this.query = $('files-search').value;
  }
  render() {
    const c = this.client, connected = c?.connected === true, busy = !!c?.job || !!c?.listing;
    $('files-login').hidden = connected; $('files-browser').hidden = !connected;
    $('files-login-status').hidden = connected;
    $('files-login-button').disabled = this.connecting; $('files-password').disabled = this.connecting;
    if (!connected) { this.release(); this.message(this.connecting ? 'Проверяем пароль и разрешение на компьютере…' : c?.error ? (messages[c.error] || errorText(c.error)) : 'Введите пароль компьютера для файлового сеанса.'); return; }
    for (const id of ['files-home','files-drives','files-up','files-refresh','files-path','files-folder-go','files-pick','files-name','files-send','files-choose','files-unpick']) $(id).disabled = busy;
    if(this.path !== c.path) {this.path = c.path;$('files-search').value = '';this.unpick();$('files-location').open = false;}
    const picked = $('files-pick').files[0];
    $('files-choose').hidden = !!picked || !!c.job; $('files-upload').hidden = !picked || !!c.job;
    $('files-picked-name').textContent = picked?.name || ''; $('files-picked-size').textContent = picked ? displaySize(picked.size) : '';
    $('files-path').value = c.path || ''; $('files-cancel').hidden = !c.job;
    $('files-progress').hidden = !c.job; $('files-progress').max = c.job?.size || 1; $('files-progress').value = c.job?.bytes || 0;
    const progress = c.job ? `${c.job.type === 'upload' ? 'Отправка' : 'Скачивание'} ${c.job.name}: ${displaySize(c.job.bytes)} из ${displaySize(c.job.size)}${c.job.awaitingDone ? '. Ждём подтверждения.' : ''}` : '';
    this.message(c.error ? messages[c.error] || errorText(c.error) : progress || (c.listing ? 'Открываем папку…' : c.result?.type === 'upload' ? 'Файл передан на компьютер.' : c.blob ? `Получен ${c.result.name}. Сохраните на устройство.` : picked ? 'Файл выбран. Отправить в текущую папку?' : 'Нажмите на файл, чтобы скачать.'));
    if (this.entries !== c.entries || this.busy !== busy) {
      this.breadcrumbs(c.path || ''); this.renderList(c,busy); this.entries = c.entries; this.busy = busy;
    }
    if (c.blob !== this.blob) { this.release(); if (c.blob) {this.blob = c.blob;this.url = URL.createObjectURL(c.blob);$('files-save').href = this.url;$('files-save').download = c.result.name;$('files-save').hidden = false;$('files-save-help').hidden = false;} }
    if (c.result?.type === 'upload' && this.result !== c.result) {
      this.unpick(); $('files-upload').hidden = true; $('files-choose').hidden = false;
      this.result = c.result; queueMicrotask(() => {if(this.client === c && c.connected && !c.job && !c.listing)c.list(c.path);});
    }
  }
  close() {
    const c = this.client; this.client = null; c?.close(); this.release(); this.connecting = false; this.owner = null; this.result = null; this.entries = null; this.busy = null; this.path = null; this.query = '';
    this.unpick(); $('files-search').value = ''; $('files-sort').value = 'name'; $('files-location').open = false; $('files-breadcrumbs').replaceChildren();
    $('files-password').value = ''; $('files-password').disabled = false; $('files-pick').value = ''; $('files-id').value = ''; $('files-path').value = ''; $('files-name').value = ''; $('files-list').replaceChildren();
    if(this.dialog.open)this.dialog.close();
  }
}
