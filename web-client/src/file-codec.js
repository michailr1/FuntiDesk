import {Decompress} from 'fzstd';
export const BLOCK = 128 * 1024;
export const LIMIT = 50 * 1024 * 1024;
export function fileName(name) {
  if (typeof name !== 'string' || !name || name.length > 255 || /[\x00-\x1f<>:"/\\|?*]/.test(name) || /[. ]$/.test(name) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(name)) throw Error('file_name');
  return name;
}
export function fileSize(size) {
  if (!Number.isSafeInteger(size) || size < 0 || size > LIMIT) throw Error('file_size');
  return size;
}
export function remotePath(path) {
  if (typeof path !== 'string' || path.length > 4096 || /[\x00-\x1f]/.test(path)) throw Error('file_path');
  return path;
}
export function joinPath(parent, leaf) { return remotePath(parent.replace(/[\\/]+$/, '') + (parent.includes('\\') || /^[A-Za-z]:/.test(parent) ? '\\' : '/') + fileName(leaf)); }
// Validate the complete frame BEFORE the decoder can allocate from untrusted sizes.
export function fileBlock(data, compressed) {
  if (!(data instanceof Uint8Array) || data.length > BLOCK + 64) throw Error('file_block');
  if (!compressed) { if (data.length > BLOCK) throw Error('file_block'); return data; }
  if (data.length < 6 || data[0] !== 0x28 || data[1] !== 0xb5 || data[2] !== 0x2f || data[3] !== 0xfd) throw Error('file_compression');
  const flag = data[4], single = !!(flag & 32), kind = flag >> 6;
  if ((flag & 27) || (!single && !kind)) throw Error('file_compression'); // reserved bits, dictionary or unknown content size
  let at = 5, window = 0;
  if (!single) { const descriptor = data[at++]; window = 2 ** (10 + (descriptor >> 3)) * (1 + (descriptor & 7) / 8); }
  const sizeBytes = kind ? 1 << kind : 1;
  if (at + sizeBytes > data.length) throw Error('file_compression');
  let size = 0n; for (let i = 0; i < sizeBytes; i++) size |= BigInt(data[at++]) << BigInt(i * 8);
  if (kind === 1) size += 256n;
  if (size > BigInt(BLOCK) || window > BLOCK) throw Error('file_compression');
  let last = false, blocks = 0;
  while (!last) {
    if (++blocks > 16 || at + 3 > data.length) throw Error('file_compression');
    const header = data[at] | data[at + 1] << 8 | data[at + 2] << 16; at += 3;
    last = !!(header & 1); const type = (header >> 1) & 3, length = header >>> 3;
    if (type === 3 || length > BLOCK) throw Error('file_compression');
    at += type === 1 ? 1 : length;
    if (at > data.length) throw Error('file_compression');
  }
  if (flag & 4) at += 4;
  if (at !== data.length) throw Error('file_compression'); // no concatenated frames
  const output = new Uint8Array(Number(size)); let written = 0;
  const decoder = new Decompress(chunk => {
    if (written + chunk.length > output.length) throw Error('file_compression');
    output.set(chunk, written); written += chunk.length;
  });
  decoder.push(data, true);
  if (written !== output.length) throw Error('file_compression');
  return output;
}
