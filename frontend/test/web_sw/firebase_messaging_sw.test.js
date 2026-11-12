// Verifies web/firebase-messaging-sw.js by EXECUTING it in a sandbox
// that mimics a service-worker global scope. Run:
//     node --test test/web_sw/
// (Node >= 18, no dependencies.) This proves the worker's logic; it does
// NOT replace a real-browser check — see the live checklist in the
// delivery report.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SW_PATH = path.join(__dirname, '..', '..', 'web', 'firebase-messaging-sw.js');
const SW_SOURCE = fs.readFileSync(SW_PATH, 'utf8');

function loadWorker({ url = 'https://gms.example/firebase-messaging-sw.js', clients = [] } = {}) {
  const listeners = {};
  const shown = [];
  const opened = [];
  const state = { bg: null, bgRegistrations: 0 };

  const self = {
    location: { href: url, origin: new URL(url).origin },
    addEventListener: (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); },
    registration: {
      showNotification: (title, opts) => { shown.push({ title, opts }); return Promise.resolve(); },
    },
    clients: {
      matchAll: async () => clients,
      openWindow: async (u) => { opened.push(u); return {}; },
    },
  };
  const firebase = {
    initializeApp() {},
    messaging: () => ({
      onBackgroundMessage(fn) { state.bg = fn; state.bgRegistrations += 1; },
    }),
  };
  vm.runInContext(SW_SOURCE, vm.createContext({
    self, firebase, URL, console, importScripts() {},
  }));

  return {
    shown, opened, listeners, state,
    push: (payload) => state.bg(payload),
    async click(data, closedFlag = { v: false }) {
      const waits = [];
      const event = {
        notification: { data, close() { closedFlag.v = true; } },
        waitUntil(p) { waits.push(p); },
      };
      listeners.notificationclick.forEach((fn) => fn(event));
      await Promise.all(waits);
      return closedFlag;
    },
  };
}

const chatPush = (over = {}) => ({
  data: { title: 'New Message', body: 'Sam sent you a message.', screen: 'chat',
          partner_id: '9', notif_id: '42', type: 'chat', recipient_id: '7', ...over },
});

// ───────────── exactly one notification per push ─────────────

test('a data-only push displays exactly ONE notification', async () => {
  const w = loadWorker();
  await w.push(chatPush());
  assert.equal(w.shown.length, 1);
  assert.equal(w.shown[0].title, 'New Message');
  assert.equal(w.shown[0].opts.body, 'Sam sent you a message.');
  assert.equal(w.shown[0].opts.data.partner_id, '9');
});

test('a push that already has a `notification` block is NOT displayed again (Firebase shows it)', async () => {
  const w = loadWorker();
  await w.push({ notification: { title: 'x', body: 'y' }, data: { title: 'x', body: 'y' } });
  assert.equal(w.shown.length, 0);
});

test('the same push delivered twice carries the same tag, so the browser collapses it to one', async () => {
  const w = loadWorker();
  await w.push(chatPush());
  await w.push(chatPush());
  assert.equal(w.shown.length, 2);                 // two calls…
  assert.equal(w.shown[0].opts.tag, 'gms-n-42');   // …one visible notification
  assert.equal(w.shown[1].opts.tag, 'gms-n-42');
});

test('different notifications get different tags (a chat burst is not squashed)', async () => {
  const w = loadWorker();
  await w.push(chatPush({ notif_id: '1' }));
  await w.push(chatPush({ notif_id: '2' }));
  assert.notEqual(w.shown[0].opts.tag, w.shown[1].opts.tag);
});

test('a push without notif_id still displays (no tag)', async () => {
  const w = loadWorker();
  await w.push({ data: { title: 'T', body: 'B' } });
  assert.equal(w.shown.length, 1);
  assert.equal(w.shown[0].opts.tag, undefined);
});

test('an empty data payload still shows a sensible notification rather than a browser "site updated" notice', async () => {
  const w = loadWorker();
  await w.push({});
  assert.equal(w.shown.length, 1);
  assert.equal(w.shown[0].title, 'GMS');
});

test('showNotification is called synchronously inside the handler', () => {
  const w = loadWorker();
  w.push(chatPush());                              // deliberately NOT awaited
  assert.equal(w.shown.length, 1);
});

test('icon resolves relative to the worker location (works under a sub-path)', async () => {
  const w = loadWorker({ url: 'https://host.example/app/firebase-messaging-sw.js' });
  await w.push(chatPush());
  assert.equal(w.shown[0].opts.icon, 'https://host.example/app/icons/Icon-192.png');
});

test('exactly one background handler and one click handler are registered', () => {
  const w = loadWorker();
  assert.equal(w.state.bgRegistrations, 1);
  assert.equal(w.listeners.notificationclick.length, 1);
});

test('source guard: there is a single showNotification call site (reintroducing a second display path would duplicate)', () => {
  const calls = SW_SOURCE.split('\n')
    .filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*'))
    .join('\n').match(/showNotification\(/g) || [];
  assert.equal(calls.length, 1);
});

// ───────────── click routing ─────────────

test('click with NO open tab opens one at a deep-link URL for the chat', async () => {
  const w = loadWorker();
  const closed = await w.click({ screen: 'chat', partner_id: '9', recipient_id: '7' });
  assert.equal(closed.v, true);
  assert.equal(w.opened.length, 1);
  const u = new URL(w.opened[0]);
  assert.equal(u.origin + u.pathname, 'https://gms.example/');
  assert.equal(u.searchParams.get('gms_screen'), 'chat');
  assert.equal(u.searchParams.get('gms_partner_id'), '9');
  assert.equal(u.searchParams.get('gms_recipient_id'), '7');
});

test('click for a booking deep-links to that booking', async () => {
  const w = loadWorker();
  await w.click({ screen: 'booking', booking_id: '55', recipient_id: '7' });
  const u = new URL(w.opened[0]);
  assert.equal(u.searchParams.get('gms_screen'), 'booking');
  assert.equal(u.searchParams.get('gms_booking_id'), '55');
});

test('click with an open tab focuses it and tells it where to go; opens no new window', async () => {
  const posted = []; let focused = 0;
  const tab = { focused: false, visibilityState: 'hidden', focus: async () => { focused++; },
                postMessage: (m) => posted.push(m) };
  const w = loadWorker({ clients: [tab] });
  await w.click({ screen: 'chat', partner_id: '9' });
  assert.equal(focused, 1);
  assert.equal(w.opened.length, 0);
  // JSON round-trip: the worker runs in a separate vm realm, so its
  // objects have a different Object prototype than the test's.
  assert.deepEqual(JSON.parse(JSON.stringify(posted)),
                   [{ type: 'GMS_NOTIFICATION_CLICK',
                      data: { screen: 'chat', partner_id: '9' } }]);
});

test('with several tabs, the focused one is chosen, then a visible one', async () => {
  const mk = (id, focused, vis, log) => ({ id, focused, visibilityState: vis,
    focus: async () => {}, postMessage: () => log.push(id) });
  const log = [];
  const w = loadWorker({ clients: [mk('hidden', false, 'hidden', log),
                                   mk('visible', false, 'visible', log),
                                   mk('focused', true, 'visible', log)] });
  await w.click({ screen: 'chat', partner_id: '9' });
  assert.deepEqual(log, ['focused']);
  const log2 = [];
  const w2 = loadWorker({ clients: [mk('hidden', false, 'hidden', log2),
                                    mk('visible', false, 'visible', log2)] });
  await w2.click({ screen: 'chat', partner_id: '9' });
  assert.deepEqual(log2, ['visible']);
});

test('a refused focus() does not prevent routing', async () => {
  const posted = [];
  const tab = { focused: true, focus: async () => { throw new Error('not allowed'); },
                postMessage: (m) => posted.push(m) };
  const w = loadWorker({ clients: [tab] });
  await w.click({ screen: 'chat', partner_id: '9' });
  assert.equal(posted.length, 1);
});

test('notifications displayed by the Firebase SDK itself (FCM_MSG) are left to the SDK', async () => {
  const w = loadWorker();
  const closed = await w.click({ FCM_MSG: { notification: {} } });
  assert.equal(closed.v, false);
  assert.equal(w.opened.length, 0);
});

test('deep-link URL is built under the worker folder when hosted in a sub-path', async () => {
  const w = loadWorker({ url: 'https://host.example/app/firebase-messaging-sw.js' });
  await w.click({ screen: 'chat', partner_id: '9' });
  assert.ok(w.opened[0].startsWith('https://host.example/app/?'), w.opened[0]);
});
