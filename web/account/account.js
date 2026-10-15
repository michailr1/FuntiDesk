(() => {
  'use strict';

  const API = '/api/account/v1';
  const $ = (id) => document.getElementById(id);
  let loginCsrf = '';
  let sessionCsrf = '';
  let challenge = '';
  let email = '';
  let busy = false;
  let library = null;
  const retryRequests = new Map();

  class ApiError extends Error {
    constructor(status, code) {
      super(code);
      this.status = status;
      this.code = code;
    }
  }

  function message(text = '', kind = '') {
    $('message').textContent = text;
    $('message').dataset.kind = kind;
  }

  async function api(path, body, csrf) {
    if (window.location.origin !== 'https://desk.funti.cc') {
      throw new ApiError(0, 'wrong_origin');
    }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 25000);
    try {
      const headers = { Accept: 'application/json' };
      if (body !== undefined) {
        headers['Content-Type'] = 'application/json';
        headers['X-Funti-CSRF'] = csrf;
      }
      const response = await fetch(API + path, {
        method: body === undefined ? 'GET' : 'POST',
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        credentials: 'same-origin',
        mode: 'same-origin',
        cache: 'no-store',
        redirect: 'error',
        signal: controller.signal,
      });
      if (response.status === 204) return null;
      let data;
      try { data = await response.json(); } catch { throw new ApiError(response.status, 'service_unavailable'); }
      if (!response.ok) throw new ApiError(response.status, data.error);
      return data;
    } finally {
      clearTimeout(timeout);
    }
  }

  function updateButtons() {
    for (const button of document.querySelectorAll('main button')) button.disabled = busy;
    $('send-code').disabled = busy || !loginCsrf;
    document.querySelector('main').setAttribute('aria-busy', String(busy));
  }

  function errorText(error) {
    if (error.code === 'wrong_origin') return 'Откройте кабинет по адресу https://desk.funti.cc/account/.';
    if (error.code === 'invalid_code') return 'Код неверный или больше не действует. Проверьте письмо или запросите новый код.';
    if (error.code === 'try_later' || error.status === 429) return 'Слишком много запросов. Попробуйте немного позже.';
    if (error.status === 409) return 'Список изменён на другом устройстве. Обновите списки и повторите действие.';
    if (error.status === 403) return 'Не удалось подтвердить запрос. Обновите страницу и повторите действие.';
    if (error.code === 'invalid_request') return 'Проверьте введённые данные и повторите действие.';
    return 'Кабинет сейчас недоступен. Попробуйте ещё раз позже. Подключения и семья в программе продолжают работать.';
  }

  async function run(action) {
    if (busy) return;
    busy = true;
    updateButtons();
    message();
    try {
      await action();
    } catch (error) {
      if (error.status === 401) {
        clearAccount();
        try { await prepareLogin(); } catch { $('retry-login').hidden = false; }
        message('Вход закончился. Войдите по почте ещё раз.', 'error');
      } else {
        message(errorText(error), 'error');
        if (!sessionCsrf && !loginCsrf) {
          $('login').hidden = false;
          $('retry-login').hidden = false;
        }
      }
    } finally {
      busy = false;
      updateButtons();
    }
  }

  function clearAccount() {
    sessionCsrf = '';
    loginCsrf = '';
    challenge = '';
    email = '';
    retryRequests.clear();
    library = null;
    $('favorite-id').value = '';
    $('favorite-name').value = '';
    $('account').hidden = true;
    $('login').hidden = false;
    $('email-form').hidden = false;
    $('code-form').hidden = true;
    $('email').value = '';
    $('code').value = '';
    $('code-sent').textContent = '';
    for (const id of ['devices', 'family', 'removals', 'favorites', 'history', 'account-email', 'session-expiry', 'device-count']) $(id).replaceChildren();
  }

  async function prepareLogin() {
    const data = await api('/auth/bootstrap');
    if (typeof data.csrf !== 'string' || !data.csrf) throw new ApiError(0, 'service_unavailable');
    loginCsrf = data.csrf;
    $('login').hidden = false;
    $('retry-login').hidden = true;
  }

  function date(value) {
    if (!Number.isFinite(value) || value <= 0) return 'ещё нет данных';
    return new Date(value * 1000).toLocaleString('ru-RU', { dateStyle: 'short', timeStyle: 'short' });
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = String(text);
    return node;
  }

  function label(device) { return device.name || 'Компьютер'; }

  function removeButton(target) {
    const button = element('button', 'danger-outline', 'Убрать из семьи');
    button.type = 'button';
    button.addEventListener('click', () => {
      if (busy || !window.confirm('Убрать «' + label(target) + '» из семьи на компьютерах этого аккаунта? Устройства вне сети применят удаление позже.')) return;
      run(async () => {
        let requestId = retryRequests.get(target.pk);
        if (!requestId) {
          requestId = Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) => byte.toString(16).padStart(2, '0')).join('');
          retryRequests.set(target.pk, requestId);
        }
        await api('/family/remove', { target_pk: target.pk, request_id: requestId }, sessionCsrf);
        retryRequests.delete(target.pk);
        await loadLists();
        message('Удаление принято. Ниже видно, какие компьютеры уже подтвердили его применение.');
      });
    });
    return button;
  }

  function connectLink(id) {
    const link = element('a', 'back-link', 'Подключиться');
    link.href = '/connect/#' + encodeURIComponent(id);
    return link;
  }

  function renderDevices(devices) {
    const root = $('devices');
    root.replaceChildren();
    $('device-count').textContent = String(devices.length);
    if (!devices.length) root.append(element('li', 'empty', 'Пока нет устройств. Войдите в кабинет в программе на своём компьютере.'));
    for (const device of devices) {
      const row = element('li', 'row');
      const body = element('div', 'row-body');
      body.append(element('p', 'row-name', label(device)));
      body.append(element('p', 'row-detail', 'ID: ' + device.funti_id + (device.version ? ' · ' + device.version : '')));
      body.append(element('p', 'row-detail', 'В кабинете с ' + date(device.bound_at)));
      body.append(element('p', 'row-detail', 'Последний обмен: ' + date(device.last_seen)));
      row.append(body, connectLink(device.funti_id), removeButton(device));
      root.append(row);
    }
  }

  function renderFamily(sources) {
    const root = $('family');
    root.replaceChildren();
    if (!sources.length) root.append(element('p', 'empty', 'Компьютеры ещё не передали списки семьи.'));
    for (const source of sources) {
      const section = element('section', 'family-source');
      section.append(element('h3', '', source.source_name || 'Компьютер'));
      section.append(element('p', 'muted', 'Копия от ' + date(source.updated_at)));
      const list = element('ul', 'rows');
      if (!source.members.length) list.append(element('li', 'empty', 'В этой копии семьи пока нет устройств.'));
      for (const member of source.members) {
        const row = element('li', 'row');
        const body = element('div', 'row-body');
        body.append(element('p', 'row-name', label(member)), element('p', 'row-detail', 'ID: ' + member.id));
        row.append(body, removeButton(member));
        list.append(row);
      }
      section.append(list);
      root.append(section);
    }
  }

  function renderRemovals(deliveries, devices, sources, hasMore) {
    const root = $('removals');
    root.replaceChildren();
    if (!deliveries.length) root.append(element('p', 'empty', 'Удалений ещё нет.'));
    const names = new Map(devices.map((device) => [device.pk, label(device)]));
    for (const source of sources) for (const member of source.members) names.set(member.pk, label(member));
    const computers = new Map(devices.map((device) => [device.device_id, label(device)]));
    const groups = new Map();
    for (const delivery of deliveries) {
      if (!groups.has(delivery.event_id)) groups.set(delivery.event_id, []);
      groups.get(delivery.event_id).push(delivery);
    }
    if (hasMore || deliveries.length >= 4096) root.append(element('p', 'muted', 'Показана последняя часть журнала удалений.'));
    for (const [id, rows] of groups) {
      const section = element('section', 'removal');
      const confirmed = rows.filter((row) => row.acknowledged_at !== null).length;
      section.append(element('h3', '', names.get(rows[0].target_pk) || 'Устройство'));
      section.append(element('p', 'muted', 'Удаление № ' + id + ' · ' + date(rows[0].created_at)));
      section.append(element('span', confirmed === rows.length ? 'badge done' : 'badge', 'Подтверждено: ' + confirmed + ' из ' + rows.length + ' показанных компьютеров'));
      for (const row of rows) {
        const delivery = element('div', 'delivery');
        delivery.append(element('span', '', computers.get(row.source_device_id) || 'Компьютер'));
        delivery.append(element('span', '', row.acknowledged_at === null ? 'Ожидает обмена' : 'Подтверждено · ' + date(row.acknowledged_at)));
        section.append(delivery);
      }
      root.append(section);
    }
  }

  function renderLibrary(lists, devices) {
    if (!Array.isArray(lists.favorites) || !Array.isArray(lists.history) || !Number.isSafeInteger(lists.revision) || !Number.isSafeInteger(lists.history_epoch)) throw new ApiError(0, 'service_unavailable');
    library = lists;
    const favorites = $('favorites');
    const history = $('history');
    favorites.replaceChildren();
    history.replaceChildren();
    if (!lists.favorites.length) favorites.append(element('li', 'empty', 'Избранных компьютеров пока нет.'));
    for (const favorite of lists.favorites) {
      const row = element('li', 'row');
      const body = element('div', 'row-body');
      body.append(element('p', 'row-name', favorite.name || favorite.funti_id), element('p', 'row-detail', 'ID: ' + favorite.funti_id));
      const remove = element('button', '', 'Убрать из избранного');
      remove.type = 'button';
      remove.addEventListener('click', () => run(async () => {
        await api('/library/favorites', { revision: library.revision, favorites: library.favorites.filter((entry) => entry.funti_id !== favorite.funti_id) }, sessionCsrf);
        await loadLists();
      }));
      row.append(body, connectLink(favorite.funti_id), remove);
      favorites.append(row);
    }
    const names = new Map(devices.map((d) => [d.device_id, d.name || d.funti_id]));
    if (!lists.history.length) history.append(element('li', 'empty', 'История пока пуста.'));
    for (const entry of lists.history) {
      const row = element('li', 'row');
      const body = element('div', 'row-body');
      body.append(element('p', 'row-name', entry.name || entry.funti_id),
        element('p', 'row-detail', 'ID: ' + entry.funti_id + ' · ' + date(entry.connected_at)),
        element('p', 'row-detail', 'С компьютера: ' + (names.get(entry.source_device_id) || 'Компьютер')));
      row.append(body);
      row.append(connectLink(entry.funti_id));
      history.append(row);
    }
  }

  async function loadLists() {
    const [devices, family, removals, lists] = await Promise.all([
      api('/devices'), api('/family'), api('/family/removals'), api('/library'),
    ]);
    if (!Array.isArray(devices.devices) || !Array.isArray(family.sources) || !Array.isArray(removals.deliveries) || family.sources.some((source) => !Array.isArray(source.members))) {
      throw new ApiError(0, 'service_unavailable');
    }
    renderLibrary(lists, devices.devices);
    renderDevices(devices.devices);
    renderFamily(family.sources);
    renderRemovals(removals.deliveries, devices.devices, family.sources, removals.has_more === true);
  }

  async function showAccount() {
    const session = await api('/session');
    if (typeof session.csrf !== 'string' || !session.csrf) throw new ApiError(0, 'service_unavailable');
    sessionCsrf = session.csrf;
    loginCsrf = '';
    challenge = '';
    email = '';
    $('email').value = '';
    $('code').value = '';
    $('code-sent').textContent = '';
    $('account-email').textContent = session.email;
    $('session-expiry').textContent = 'Вход действует до ' + date(session.expires_at);
    $('login').hidden = true;
    $('account').hidden = false;
    await loadLists();
  }

  async function sendCode() {
    const input = email || $('email').value.trim();
    const data = await api('/auth/request', { email: input }, loginCsrf);
    if (typeof data.challenge_id !== 'string' || !data.challenge_id) throw new ApiError(0, 'service_unavailable');
    challenge = data.challenge_id;
    email = input;
    $('email-form').hidden = true;
    $('code-form').hidden = false;
    $('code').value = '';
    $('code-sent').textContent = 'Письмо отправляется на ' + email + '. Проверьте входящие и папку «Спам».';
    $('code').focus();
  }

  $('favorite-form').addEventListener('submit', (event) => {
    event.preventDefault();
    run(async () => {
      if (!library) throw new ApiError(0, 'service_unavailable');
      const id = $('favorite-id').value.trim();
      const favorites = library.favorites.filter((entry) => entry.funti_id !== id);
      favorites.push({ funti_id: id, name: $('favorite-name').value.trim() });
      await api('/library/favorites', { revision: library.revision, favorites }, sessionCsrf);
      $('favorite-id').value = '';
      $('favorite-name').value = '';
      await loadLists();
    });
  });
  $('clear-history').addEventListener('click', () => {
    if (busy || !library || !window.confirm('Очистить историю на всех клиентах аккаунта? Старые отложенные записи не вернутся.')) return;
    run(async () => {
      await api('/library/history/clear', { history_epoch: library.history_epoch }, sessionCsrf);
      await loadLists();
    });
  });

  $('email-form').addEventListener('submit', (event) => { event.preventDefault(); run(sendCode); });
  $('code-form').addEventListener('submit', (event) => {
    event.preventDefault();
    run(async () => {
      await api('/auth/verify', { challenge_id: challenge, code: $('code').value.trim() }, loginCsrf);
      await showAccount();
      message('Вы вошли в FuntiDesk.');
    });
  });
  $('resend-code').addEventListener('click', () => run(sendCode));
  $('change-email').addEventListener('click', () => {
    challenge = '';
    email = '';
    $('code').value = '';
    $('code-sent').textContent = '';
    $('code-form').hidden = true;
    $('email-form').hidden = false;
    message();
    $('email').focus();
  });
  $('retry-login').addEventListener('click', () => run(prepareLogin));
  $('refresh').addEventListener('click', () => run(showAccount));
  for (const [id, path] of [['logout', '/logout'], ['logout-all', '/logout-all']]) {
    $(id).addEventListener('click', () => {
      if (busy || (id === 'logout-all' && !window.confirm('Выйти из кабинета во всех браузерах и программах? Семейные подключения останутся самостоятельными.'))) return;
      run(async () => {
        await api(path, {}, sessionCsrf);
        clearAccount();
        await prepareLogin();
        message(id === 'logout-all' ? 'Вход в кабинет завершён на всех устройствах.' : 'Вы вышли из кабинета.');
      });
    });
  }

  run(async () => {
    try { await showAccount(); } catch (error) {
      if (error.status !== 401) throw error;
      clearAccount();
      await prepareLogin();
    }
  });
})();
