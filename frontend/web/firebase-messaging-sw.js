// ═══════════════════════════════════════════════════════════
//  firebase-messaging-sw.js
//
//  Handles Web push when the GMS tab is closed or in the
//  background — the browser's own equivalent of Android's
//  background message handler.
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

// Background messages: FCM includes a `notification` payload for
// chat/booking/payment/reminder events (see app/services/notify.py),
// so the browser shows this automatically in most cases — this
// handler is here for messages that arrive data-only, and as an
// explicit safety net.
messaging.onBackgroundMessage((payload) => {
  const title = payload.notification?.title || 'GMS';
  const body = payload.notification?.body || '';
  self.registration.showNotification(title, {
    body,
    icon: '/icons/Icon-192.png',
    data: payload.data || {},
  });
});

// Clicking the browser notification focuses/opens the GMS tab.
// Deep-link routing to a specific chat/booking happens inside the
// Flutter app itself once it's foregrounded (see fcm_service.dart's
// onMessageOpenedApp / getInitialMessage) — this just gets the tab
// in front of the person.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windowClients) => {
      for (const client of windowClients) {
        if ('focus' in client) return client.focus();
      }
      if (clients.openWindow) return clients.openWindow('/');
    })
  );
});
