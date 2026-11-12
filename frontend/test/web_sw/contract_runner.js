// Feeds a REAL backend-built push payload into the REAL service worker and
// prints what the browser would do. Used by backend/tests/test_web_sw_contract.py.
//   node contract_runner.js <input.json>
// input: { "payload": {data:{...}}, "click": true }
const fs = require('node:fs'); const path = require('node:path'); const vm = require('node:vm');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const src = fs.readFileSync(path.join(__dirname, '..', '..', 'web', 'firebase-messaging-sw.js'), 'utf8');
const url = 'https://gms.example/firebase-messaging-sw.js';
const listeners = {}, shown = [], opened = []; let bg;
const self = { location: { href: url, origin: 'https://gms.example' },
  addEventListener: (t, f) => (listeners[t] = listeners[t] || []).push(f),
  registration: { showNotification: (title, opts) => { shown.push({ title, opts: JSON.parse(JSON.stringify(opts)) }); return Promise.resolve(); } },
  clients: { matchAll: async () => [], openWindow: async (u) => { opened.push(u); return {}; } } };
vm.runInContext(src, vm.createContext({ self, URL, console, importScripts() {},
  firebase: { initializeApp() {}, messaging: () => ({ onBackgroundMessage(f) { bg = f; } }) } }));
(async () => {
  await bg(input.payload);
  if (input.click && shown.length) {
    const waits = [];
    listeners.notificationclick.forEach((f) => f({ notification: { data: shown[0].opts.data, close() {} }, waitUntil: (p) => waits.push(p) }));
    await Promise.all(waits);
  }
  console.log(JSON.stringify({ shown, opened }));
})();
