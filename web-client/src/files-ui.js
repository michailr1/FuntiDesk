import {Files} from './files.js';
import {LIMIT, fileSize, fileName, joinPath} from './file-codec.js';
import {errorText} from './session.js';
const $ = id => document.getElementById(id);
const messages = {file_size:'Один файл — не больше 50 МБ.',file_name:'Выберите другое имя файла без служебных символов.',file_exists:'Файл с таким именем уже есть. Укажите другое имя: перезапись не выполнялась.',files_denied:'Компьютер не разрешил файловый сеанс. Проверьте пароль и право передачи файлов.',file_directory:'Не удалось открыть папку. Проверьте путь и права доступа.',file_busy:'Дождитесь завершения или отмените текущую передачу.',file_remote:'Компьютер отклонил передачу. Проверьте имя, папку и права доступа.',file_block:'Компьютер прислал некорректные данные файла.',file_compression:'Не удалось проверить сжатый блок файла.',file_path:'Откройте папку для отправки файла.'};
export class FilePanel {
  constructor(session, beforeOpen = () => {}) {
    this.session = session; this.beforeOpen = beforeOpen; this.dialog = $('files-dialog');
    for (const id of ['files-open','phone-files']) $(id).onclick = () => this.open();
    $('files-close').onclick = () => this.close(); this.dialog.oncancel = e => {e.preventDefault();this.close();};
    $('files-login').onsubmit = e => {e.preventDefault();this.login();};
    $('files-folder-form').onsubmit = e => {e.preventDefault();this.act(() => this.client.list($('files-path').value));};
    $('files-home').onclick = () => this.act(() => this.client.list(''));
    $('files-drives').onclick = () => this.act(() => this.client.list('/'));
    $('files-refresh').onclick = () => this.act(() => this.client.list(this.client.path));
    $('files-up').onclick = () => this.act(() => {
      const path = this.client.path.replace(/[\\/]+$/, '');
      this.client.list(/^[A-Za-z]:$/.test(path) ? '/' : path.replace(/[\\/][^\\/]*$/, '') || '/');
    });
    $('files-pick').onchange = () => {this.release();$('files-name').value = $('files-pick').files[0]?.name || '';};
    $('files-upload').onsubmit = e => {e.preventDefault();this.act(() => {
      const file = $('files-pick').files[0]; if (!file) throw Error('file_name');
      const name = fileName($('files-name').value); fileSize(file.size);
      if (this.client.entries?.some(v => v.name.toLocaleLowerCase() === name.toLocaleLowerCase())) throw Error('file_exists');
      this.release(); this.client.upload(file,name);
    });};
    $('files-cancel').onclick = () => this.client?.cancel();
    this.sync();
  }
  message(text) { if ($('files-status').textContent !== text) $('files-status').textContent = text; }
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
  }
  render() {
    const c = this.client, connected = c?.connected === true, busy = !!c?.job || !!c?.listing;
    $('files-login').hidden = connected; $('files-browser').hidden = !connected;
    $('files-login-button').disabled = this.connecting; $('files-password').disabled = this.connecting;
    if (!connected) { this.release(); this.message(this.connecting ? 'Проверяем пароль и разрешение на компьютере…' : c?.error ? (messages[c.error] || errorText(c.error)) : 'Введите пароль компьютера для файлового сеанса.'); return; }
    for (const id of ['files-home','files-drives','files-up','files-refresh','files-path','files-folder-go','files-pick','files-name','files-send']) $(id).disabled = busy;
    $('files-path').value = c.path || ''; $('files-cancel').hidden = !c.job;
    $('files-progress').hidden = !c.job; $('files-progress').max = c.job?.size || 1; $('files-progress').value = c.job?.bytes || 0;
    const progress = c.job ? `${c.job.name}: ${c.job.bytes} из ${c.job.size} байт${c.job.awaitingDone ? '. Ждём подтверждения компьютера.' : ''}` : '';
    this.message(c.error ? messages[c.error] || errorText(c.error) : progress || (c.listing ? 'Открываем папку…' : c.result?.type === 'upload' ? 'Файл передан на компьютер.' : c.blob ? 'Файл получен. Нажмите «Сохранить».' : 'Выберите папку или файл.'));
    if (this.entries !== c.entries || this.busy !== busy) {
    this.entries = c.entries; this.busy = busy; const list = $('files-list'); list.replaceChildren();
    for (const entry of c.entries || []) {
      const type = entry.entry_type || 0, row = document.createElement('li'), button = document.createElement('button'); button.type = 'button';
      button.textContent = `${type === 0 || type === 3 ? '▸ ' : ''}${entry.name}${type === 4 ? ` · ${entry.size || 0} байт` : ''}`;
      button.disabled = busy || ![0,3,4].includes(type) || (type === 4 && (!Number.isSafeInteger(entry.size || 0) || entry.size < 0 || entry.size > LIMIT));
      button.onclick = () => this.act(() => {this.release();if(type === 4)c.download({...entry,size:entry.size || 0});else c.list(type === 3 ? entry.name + '\\' : joinPath(c.path,entry.name));});
      row.append(button);list.append(row);
    }
    }
    if (c.blob !== this.blob) { this.release(); if (c.blob) {this.blob = c.blob;this.url = URL.createObjectURL(c.blob);$('files-save').href = this.url;$('files-save').download = c.result.name;$('files-save').hidden = false;} }
    if (c.result?.type === 'upload' && this.result !== c.result) {
      this.result = c.result; queueMicrotask(() => {if(this.client === c && c.connected && !c.job && !c.listing)c.list(c.path);});
    }
  }
  close() {
    const c = this.client; this.client = null; c?.close(); this.release(); this.connecting = false; this.owner = null; this.result = null; this.entries = null; this.busy = null;
    $('files-password').value = ''; $('files-password').disabled = false; $('files-pick').value = ''; $('files-id').value = ''; $('files-path').value = ''; $('files-name').value = ''; $('files-list').replaceChildren();
    if(this.dialog.open)this.dialog.close();
  }
}
