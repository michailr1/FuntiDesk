import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import protobuf from 'protobufjs';
import { build } from 'esbuild';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { main: pbjs } = require('protobufjs-cli/pbjs');
const here = path.dirname(fileURLToPath(import.meta.url));
const root = new protobuf.Root();
root.loadSync([
  path.join(here, '../client/libs/hbb_common/protos/rendezvous.proto'),
  path.join(here, '../client/libs/base/protos/message.proto'),
], { keepCase: true });
root.resolveAll();
const generated = await new Promise((resolve, reject) => pbjs([
  '-t', 'static-module', '-w', 'es6', '--force-number', '--no-delimited', '--no-verify',
  '--keep-case', path.join(here, '../client/libs/hbb_common/protos/rendezvous.proto'),
  path.join(here, '../client/libs/base/protos/message.proto'),
], (error, output) => error ? reject(error) : resolve(output)));
fs.writeFileSync(path.join(here, 'src/schema.generated.js'), generated.replaceAll('protobufjs/minimal\"', 'protobufjs/minimal.js\"'));
const escape = (s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
const notices = ['libsodium', 'libsodium-wrappers', 'protobufjs', 'long', 'fzstd'].map((name) => {
  const pkg = JSON.parse(fs.readFileSync(path.join(here, 'node_modules', name, 'package.json')));
  return '<h2>' + escape(name + ' ' + pkg.version) + '</h2><pre>' + escape(fs.readFileSync(path.join(here, 'node_modules', name, 'LICENSE'), 'utf8')) + '</pre>';
}).join('');
fs.writeFileSync(path.join(here, '../web/connect/licenses.html'), '<!doctype html><html lang="en"><meta charset="utf-8"><title>FuntiDesk browser client — third-party notices</title><main><h1>Third-party notices</h1>' + notices + '</main></html>\n');
await build({ entryPoints: [path.join(here, 'src/main.js')], outfile: path.join(here, '../web/connect/session.js'),
  bundle: true, minify: true, format: 'esm', target: 'chrome120', legalComments: 'inline',
  banner: { js: '/*! FuntiDesk browser client — AGPL-3.0-only. Corresponding source: https://github.com/michailr1/FuntiDesk */' } });
