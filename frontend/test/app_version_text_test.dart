// Run with:  flutter test test/app_version_text_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:GMS/core/services/app_version_text.dart';

void main() {
  test('version and build number', () {
    expect(AppVersionText.format('1.0.0', '1'), '1.0.0 (build 1)');
    expect(AppVersionText.format('1.2.3', '45'), '1.2.3 (build 45)');
  });
  test('no build number (pubspec without +N, or platform omits it)', () {
    expect(AppVersionText.format('1.0.0', ''), '1.0.0');
    expect(AppVersionText.format(' 1.0.0 ', ' '), '1.0.0');
  });
  test('build number equal to version is not repeated', () {
    expect(AppVersionText.format('7', '7'), '7');
  });
  test('nothing readable', () {
    expect(AppVersionText.format('', ''), 'unavailable');
    expect(AppVersionText.format('', '3'), 'unavailable');
  });
}
