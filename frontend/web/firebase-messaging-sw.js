// ═══════════════════════════════════════════════════════════
//  firebase-messaging-sw.js
//
//  Web push when the GMS tab is hidden, in the background, or closed.
//
//  ONE DISPLAY STRATEGY — this worker shows every web notification
//  itself, exactly once:
//
//    • The backend (app/services/notify.py build_message) sends web
//      tokens DATA-ONLY: title/body travel in `data`, with NO
//      `notification` block. Firebase's SDK therefore never
//      auto-displays anything, and this file is the only place that
//      calls showNotification().
//      (Mixing both — a `notification` payload AND a manual
//      showNotification — is what produced duplicates before.)
//
//    • If a message with a `notification` block ever does arrive (for
//      example a test sent from the Firebase console), Firebase has
//      already displayed it, so we deliberately DO NOT display again.
//
//  Foreground (tab visible): Firebase does not invoke the handler
//  below; it forwards the message to the page instead, and the Flutter
//  app shows its own in-page popup (foreground_notifier_web.dart).
//  Hidden-but-open tabs and closed browsers come through here.
//
//  Clicks route to the right chat/booking: an already-open tab is
//  focused and told (postMessage) where to go; otherwise a new window
//  opens at the app root with ?gms_screen=…&gms_partner_id=… which the
//  Flutter app reads on start (see web_notification_bridge_web.dart).
// ═══════════════════════════════════════════════════════════

importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

const firebaseConfig = {
  apiKey: "AIzaSyDGetZsU0ydKz5ws4ONS0zg9rAIMJhvGSg",
  authDomain: "gms---get-my-service.firebaseapp.com",
  projectId: "gms---get-my-service",
  storageBucket: "gms---get-my-service.firebasestorage.app",
  messagingSenderId: "585041395098",
  appId: "1:585041395098:web:7cad9fa106146e11264e23",
};

firebase.initializeApp(firebaseConfig);
const messaging = firebase.messaging();

// The folder this worker is served from == the Flutter app's root
// (index.html sits beside it), so this also works under a sub-path.
const APP_ROOT = new URL('./', self.location.href);
const CLICK_MESSAGE_TYPE = 'GMS_NOTIFICATION_CLICK';

function openUrlFor(data) {
  const url = new URL(APP_ROOT.href);
  if (data.screen) url.searchParams.set('gms_screen', data.screen);
  if (data.partner_id) url.searchParams.set('gms_partner_id', data.partner_id);
  if (data.booking_id) url.searchParams.set('gms_booking_id', data.booking_id);
  if (data.recipient_id) url.searchParams.set('gms_recipient_id', data.recipient_id);
  return url.href;
}

// ── Display: exactly one notification per push ──────────────
messaging.onBackgroundMessage((payload) => {
  // Firebase already displayed a `notification`-block message; showing
  // it again here would be the duplicate we are fixing.
  if (payload && payload.notification) return;

  const d = (payload && payload.data) || {};
  const title = d.title || 'GMS';
  const body = d.body || 'You have a new notification';

  // Called synchronously (not after any await): browsers expect the
  // notification to be shown while the push event is still alive.
  return self.registration.showNotification(title, {
    body,
    icon: new URL('icons/Icon-192.png', APP_ROOT).href,
    // Per-notification tag: if the very same push were ever delivered
    // twice (two registrations, a retry), the browser collapses them
    // into ONE visible notification. Distinct messages get distinct
    // tags, so a burst of chats is not squashed into one.
    tag: d.notif_id ? 'gms-n-' + d.notif_id : undefined,
    data: d,
  });
});

// ── Click: focus an open tab and route it, or open one ──────
self.addEventListener('notificationclick', (event) => {
  const data = (event.notification && event.notification.data) || {};

  // Notifications displayed by Firebase's own SDK carry FCM_MSG and are
  // handled by the SDK. Ours never do — leave the SDK's alone.
  if (data.FCM_MSG) return;

  event.notification.close();
  event.waitUntil(routeClick(data));
});

async function routeClick(data) {
  const windows = await self.clients.matchAll({
    type: 'window',
    includeUncontrolled: true,
  });

  const target =
    windows.find((c) => c.focused) ||
    windows.find((c) => c.visibilityState === 'visible') ||
    windows[0];

  if (target) {
    try {
      if ('focus' in target) await target.focus();
    } catch (_) { /* focus can be refused; routing still matters */ }
    target.postMessage({ type: CLICK_MESSAGE_TYPE, data });
    return;
  }

  if (self.clients.openWindow) {
    return self.clients.openWindow(openUrlFor(data));
  }
}
