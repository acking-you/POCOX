import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/git_diff.dart';

void main() {
  group('languageHintForPath', () {
    test('is the extension, without the dot', () {
      expect(languageHintForPath('lib/src/main.dart'), 'dart');
    });

    test('splits on either separator, so a host path from Windows works', () {
      expect(languageHintForPath(r'C:\repo\lib\main.dart'), 'dart');
    });

    test('is empty where there is no extension to name', () {
      // A dotfile's leading dot does not start an extension, and an
      // extensionless name has none — the highlighter leaves both plain.
      expect(languageHintForPath('.gitignore'), '');
      expect(languageHintForPath('Dockerfile'), '');
      expect(languageHintForPath('src/LICENSE'), '');
    });
  });
}
