import 'package:brainframe/engram/engram_paths.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one definition of what counts as engram content, shared by the file
/// browser and the scan.
void main() {
  group('isHiddenEngramPath', () {
    test('hides dotfiles and anything inside a dot-directory', () {
      expect(isHiddenEngramPath('.DS_Store'), isTrue);
      expect(isHiddenEngramPath('notes/.secret.md'), isTrue);
      expect(isHiddenEngramPath('.git/config'), isTrue);
      expect(isHiddenEngramPath('.brainframe/engram.json'), isTrue);
    });

    test('leaves ordinary files and folders visible', () {
      expect(isHiddenEngramPath('welcome.md'), isFalse);
      expect(isHiddenEngramPath('notes/first.md'), isFalse);
      // A dot mid-name (not leading) is not hidden.
      expect(isHiddenEngramPath('release.notes.md'), isFalse);
    });
  });
}
