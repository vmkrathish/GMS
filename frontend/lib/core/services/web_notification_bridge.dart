// Conditional export: real implementation on web, no-ops elsewhere
// (dart:html does not exist on Android/iOS).
export 'web_notification_bridge_stub.dart'
    if (dart.library.html) 'web_notification_bridge_web.dart';
