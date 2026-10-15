import { Socket } from './socket.js';
import { ready, wire, rendezvous, SERVER_KEY, handshake, passwordProof, wipe } from './protocol.js';

const ORIGIN = 'wss://desk.funti.cc';
export class Session {
  constructor(canvas, onState) {
    this.canvas = canvas; this.onState = onState; this.closed = false;
    this.sockets = []; this.keys = null; this.decoder = null; this.connected = false;
    this.keyboard = null; this.screen = { x: 0, y: 0 }; this.pendingFrames = 0;
  }
  async start(id, password) {
    await ready;
    if (this.closed) return;
    if (!/^[0-9]{6,16}$/.test(id) || !password || password.length > 256) throw new Error('invalid_credentials');
    const capability = await VideoDecoder.isConfigSupported({ codec: 'vp09.00.10.08' });
    if (!capability.supported || this.closed) throw new Error('unsupported_browser');
    this.decoder = new VideoDecoder({ output: (frame) => this.draw(frame), error: () => this.fail('video_error') });
    this.decoder.configure({ codec: 'vp09.00.10.08', optimizeForLatency: true });
    this.onState('Соединяемся с компьютером…');
    const signal = new Socket(ORIGIN + '/ws/rendezvous', rendezvous); this.sockets.push(signal);
    await signal.opened;
    signal.send({ punch_hole_request: { id, licence_key: SERVER_KEY, conn_type: 0, nat_type: 2, force_relay: true, version: '1.5.0' } });
    const reply = await signal.next(); signal.close();
    const relay = reply.relay_response;
    if (!relay?.uuid || !relay.pk?.length || relay.refuse_reason) throw new Error('computer_unavailable');
    if (this.closed) return;
    const socket = new Socket(ORIGIN + '/ws/relay', rendezvous); this.socket = socket; this.sockets.push(socket);
    await socket.opened;
    socket.send({ request_relay: { id, uuid: relay.uuid, secure: true, licence_key: SERVER_KEY, conn_type: 0 } });
    socket.type = wire;
    const first = await socket.next();
    const exchange = handshake(relay.pk, first.signed_id?.id, id);
    socket.send({ public_key: exchange.public_key });
    this.keys = [exchange.sendKey, exchange.receiveKey]; socket.secure(this.keys);
    const hash = await socket.next();
    if (!hash.hash?.salt || !hash.hash?.challenge) throw new Error('invalid_handshake');
    const proof = await passwordProof(password, hash.hash.salt, hash.hash.challenge);
    password = '';
    try {
      socket.send({ login_request: { username: id, my_id: 'web-' + crypto.randomUUID(), my_name: 'FuntiDesk Web',
        password: proof, version: '1.5.0', my_platform: 'Web', video_ack_required: true,
        option: { image_quality: 3, show_remote_cursor: 2, disable_audio: 2, disable_clipboard: 2, enable_file_transfer: 1,
          disable_camera: 2, supported_decoding: { ability_vp9: 1, prefer: 1 }, custom_fps: 30 },
      } });
    } finally { wipe(proof); }
    this.onState('Проверяем пароль и разрешения на компьютере…');
    while (!this.closed) {
      const message = await socket.next(120000);
      if (message.hash) throw new Error('authentication_failed');
      if (message.login_response?.error) throw new Error('authentication_failed');
      if (message.login_response?.peer_info) {
        const info = message.login_response.peer_info;
        this.screen = info.displays?.[info.current_display || 0] || { x: 0, y: 0 };
        if (this.keyboard === null) this.keyboard = true;
        this.connected = true;
        this.onState('Подключено. Нажмите на экран для управления.', true);
      }
      if (message.test_delay && !message.test_delay.from_client) socket.send({ test_delay: message.test_delay });
      if (message.misc?.permission_info && (message.misc.permission_info.permission || 0) === 0) {
        this.keyboard = message.misc.permission_info.enabled === true;
        if (!this.keyboard) this.onState('Компьютер разрешил только просмотр.', true);
      }
      if (message.misc?.close_reason) throw new Error('remote_closed');
      if (message.misc?.switch_display) { this.screen = message.misc.switch_display; this.decoder.reset(); this.decoder.configure({ codec: 'vp09.00.10.08', optimizeForLatency: true }); }
      if (message.video_frame && this.connected) this.video(message.video_frame);
    }
  }
  video(video) {
    if (!video.vp9s?.frames?.length || video.vp9s.frames.length > 128) throw new Error('unsupported_video');
    if (this.decoder.decodeQueueSize > 60) throw new Error('video_overflow');
    for (const frame of video.vp9s.frames) {
      if (!frame.data?.length || !Number.isSafeInteger(Number(frame.pts || 0))) throw new Error('invalid_video');
      this.pendingFrames++;
      this.decoder.decode(new EncodedVideoChunk({ type: frame.key ? 'key' : 'delta', timestamp: Number(frame.pts || 0) * 1000, data: frame.data }));
    }
  }
  draw(frame) {
    try {
      if (this.closed) return;
      const { displayWidth: w, displayHeight: h } = frame;
      if (w <= 0 || h <= 0 || w > 8192 || h > 8192 || w * h > 33554432) { this.fail('invalid_video'); return; }
      this.canvas.width = w; this.canvas.height = h;
      this.canvas.getContext('2d', { alpha: false }).drawImage(frame, 0, 0);
      if (--this.pendingFrames === 0) this.socket.send({ misc: { video_received: true } });
    } finally { frame.close(); }
  }
  input(value) { if (!this.closed && this.connected && this.keyboard) this.socket.send(value); }
  fail(code) { this.close(); this.onState(errorText(code)); }
  close() {
    if (this.closed) return;
    this.closed = true; this.connected = false; this.keyboard = false;
    for (const socket of this.sockets) socket.close();
    if (this.decoder && this.decoder.state !== 'closed') this.decoder.close();
    if (this.keys) for (const key of this.keys) wipe(key);
    this.canvas.getContext('2d').clearRect(0, 0, this.canvas.width, this.canvas.height);
  }
}
export function errorText(code) {
  return ({ unsupported_browser: 'Нужен настольный Chromium с поддержкой WebCodecs VP9.',
    invalid_credentials: 'Введите ID и временный или постоянный пароль компьютера.',
    computer_unavailable: 'Компьютер недоступен. Проверьте ID и запущен ли FuntiDesk.',
    authentication_failed: 'Компьютер отклонил вход. Проверьте пароль и разрешения на компьютере.',
    client_update_required: 'Для безопасного веб-подключения обновите FuntiDesk на компьютере.',
    remote_closed: 'Компьютер завершил сеанс.', invalid_identity: 'Не удалось проверить ключ компьютера. Подключение остановлено.',
    invalid_handshake: 'Не удалось установить защищённое соединение.',
  })[code] || 'Соединение завершено или недоступно. Для новой попытки введите пароль ещё раз.';
}
