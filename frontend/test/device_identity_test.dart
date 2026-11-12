// Run:  flutter test test/device_identity_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:GMS/core/services/device_identity.dart';

void main() {
  final valid = RegExp(r'^[A-Za-z0-9_\-]{8,128}$'); // same rule as the backend

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceIdentity.resetCacheForTests();
  });

  test('randomId is 32 hex chars and unique', () {
    final ids = {for (var i = 0; i < 200; i++) DeviceIdentity.randomId()};
    expect(ids.length, 200);
    for (final id in ids) {
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(valid.hasMatch(id), isTrue);
    }
  });

  test('device id is created once and is stable', () async {
    final a = await DeviceIdentity.deviceId();
    final b = await DeviceIdentity.deviceId();
    expect(a, b);
    expect(valid.hasMatch(a), isTrue);
  });

  test('device id persists across an app restart (cache cleared)', () async {
    final a = await DeviceIdentity.deviceId();
    DeviceIdentity.resetCacheForTests();
    expect(await DeviceIdentity.deviceId(), a);
  });

  test('device id survives logout (which removes individual keys only)', () async {
    final a = await DeviceIdentity.deviceId();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('gms_jwt');
    await prefs.remove('gms_user');
    DeviceIdentity.resetCacheForTests();
    expect(await DeviceIdentity.deviceId(), a);
  });

  test('a corrupted stored id is replaced with a valid one', () async {
    SharedPreferences.setMockInitialValues({'gms_device_id': 'bad id!'});
    final id = await DeviceIdentity.deviceId();
    expect(valid.hasMatch(id), isTrue);
  });
}
