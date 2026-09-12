import 'dart:convert';
import 'dart:io';

import 'package:brainframe/app.dart';
import 'package:brainframe/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/gen_pseudo_arb.dart' as pseudo;
import '../support/localized_app.dart';

/// Message keys in an ARB map — everything except the `@@locale` marker and the
/// `@`-prefixed metadata blocks.
Set<String> _messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

void main() {
  group('pseudoLocalize', () {
    test('accents and brackets text while preserving placeholders', () {
      final result = pseudo.pseudoLocalize('Folder {name}');
      expect(result, startsWith('['));
      expect(result, endsWith(']'));
      expect(result, contains('{name}')); // placeholder untouched
      expect(result, isNot(contains('Folder'))); // letters were accented
    });

    test('leaves ICU-style braces and numbers intact', () {
      final result = pseudo.pseudoLocalize('{width} pixels wide');
      expect(result, contains('{width}'));
    });

    test('keeps a plural block parseable and accents only its case texts', () {
      // The ICU parser needs the argument, the keyword, and every case key
      // verbatim; a generator that accented `other` broke gen-l10n on the
      // first plural the app used.
      final result = pseudo.pseudoLocalize(
        'Its {count, plural, =1{one file} other{{count} files}} here',
      );
      expect(result, contains('{count, plural, =1{'));
      expect(result, contains('other{{count} '));
      expect(result, isNot(contains('one file')));
      expect(result, isNot(contains(' files')));
      expect(result, isNot(contains('here')));
      expect(result, endsWith(']'));
    });

    test('a select block is handled the same way', () {
      final result = pseudo.pseudoLocalize(
        '{kind, select, note{a note} other{a file}}',
      );
      expect(result, contains('{kind, select, note{'));
      expect(result, contains('other{'));
      expect(result, isNot(contains('a note')));
    });

    test('an unclosed brace is passed through rather than mangled', () {
      // Malformed input is gen-l10n's to report; the generator must not turn
      // it into something that parses as a different message.
      final result = pseudo.pseudoLocalize('broken {name');
      expect(result, contains('{name'));
    });
  });

  test('app_en_XA.arb is the generator output (no drift)', () {
    // Guards the checked-in pseudo-locale against hand-edits or a stale template:
    // regenerate from the template in memory and compare byte-for-byte. If this
    // fails, run `dart run tool/gen_pseudo_arb.dart`.
    final template = File('lib/l10n/app_en.arb').readAsStringSync();
    final onDisk = File('lib/l10n/app_en_XA.arb').readAsStringSync();
    expect(onDisk, pseudo.buildPseudoArb(template));
  });

  test('pseudo-locale has exactly the template keys (parity)', () {
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    final xa = jsonDecode(File('lib/l10n/app_en_XA.arb').readAsStringSync())
        as Map<String, dynamic>;
    expect(_messageKeys(xa), equals(_messageKeys(en)));
  });

  group('appSupportedLocales', () {
    test('includes the pseudo-locale off release', () {
      final locales = appSupportedLocales(releaseMode: false);
      expect(locales, contains(const Locale('en')));
      expect(locales, contains(const Locale('en', 'XA')));
    });

    test('drops the pseudo-locale in release', () {
      final locales = appSupportedLocales(releaseMode: true);
      expect(locales, contains(const Locale('en')));
      expect(locales, isNot(contains(const Locale('en', 'XA'))));
    });
  });

  testWidgets('renders pseudo-localized strings under en_XA', (tester) async {
    await tester.pumpWidget(localizedApp(
      locale: const Locale('en', 'XA'),
      home: Builder(
        builder: (context) => Text(AppLocalizations.of(context).switcherHeading),
      ),
    ));
    await tester.pumpAndSettle();

    // The bracket marker proves the layer resolved to the pseudo-locale; the
    // plain English no longer appears.
    expect(find.text('Engrams'), findsNothing);
    expect(find.textContaining('['), findsOneWidget);
  });
}
