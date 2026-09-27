import 'dart:io';

import 'package:brainframe/engram/built_in_engrams.dart';
import 'package:brainframe/engram/engram.dart';
import 'package:brainframe/engram/engram_repository.dart';
import 'package:brainframe/engram/engram_scope.dart';
import 'package:brainframe/engram/engram_store.dart';
import 'package:brainframe/engram/fs/folder_access.dart';
import 'package:brainframe/engram/fs/fs_store.dart';
import 'package:brainframe/engram/path_folder_access.dart';
import 'package:brainframe/engram/ui/engram_switcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../support/fake_folder_access.dart';
import '../../support/localized_app.dart';

/// A no-op store for fake engrams — these tests exercise the switcher widget,
/// not content access.
class _FakeStore extends EngramStore {
  @override
  Future<List<String>> list() async => const [];
  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);
  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
}

Engram _engram(String id, String name, {bool readOnly = false}) =>
    Engram(id: id, displayName: name, readOnly: readOnly, store: _FakeStore());

/// A repository whose discovery/create are canned, so the switcher can be
/// driven under `testWidgets` without real filesystem I/O (which would hang the
/// fake-async test zone). Repository I/O correctness lives in
/// engram_repository_test.
class _FakeRepo extends EngramRepository {
  _FakeRepo({required this.discovery})
      : super(
          preferences: SharedPreferencesAsync(),
          containerPathResolver: () async => throw UnsupportedError('no fs'),
        );

  /// What [discover] returns; a test replaces it to play a change on disk.
  EngramDiscovery discovery;

  @override
  Future<EngramDiscovery> discover() async => discovery;

  @override
  Future<Engram> create(String displayName) async =>
      _engram('created-$displayName', displayName);

  /// Folders adopted through the "Open folder…" flow, by path.
  final List<String> adopted = [];

  @override
  Future<Engram> adoptFolder(
    EngramLocation location, {
    String? displayName,
    String? bookmark,
  }) async {
    adopted.add(location.path);
    return _engram('adopted-${location.path}', displayName ?? 'Adopted');
  }
}

void main() {
  final tutorial = _engram(builtinTutorialId, 'Tutorial', readOnly: true);
  final help = _engram(builtinHelpId, 'Help', readOnly: true);

  EngramDiscovery discovery({List<UnavailableEngram> unavailable = const []}) =>
      EngramDiscovery(available: [tutorial, help], unavailable: unavailable);

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Widget harness(
    EngramRepository repository,
    Engram initial, {
    Future<String?> Function()? folderPicker,
    FolderAccess? folderAccess,
  }) =>
      localizedApp(
        home: EngramScope(
          initialEngram: initial,
          child: Scaffold(
            body: Builder(builder: (context) {
              final active = EngramScope.of(context).engram;
              return Column(
                children: [
                  Text('active:${active.id}'),
                  const Spacer(),
                  EngramSwitcher(
                    repository: repository,
                    current: active,
                    folderAccess: folderAccess ??
                        (folderPicker == null
                            ? null
                            : PathFolderAccess(picker: folderPicker)),
                  ),
                ],
              );
            }),
          ),
        ),
      );

  testWidgets('footer shows the engram name and a read-only lock',
      (tester) async {
    await tester.pumpWidget(harness(_FakeRepo(discovery: discovery()), tutorial));
    expect(find.text('Tutorial'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('a writable engram has no lock', (tester) async {
    final mine = _engram('mine', 'Mine');
    await tester.pumpWidget(harness(_FakeRepo(discovery: discovery()), mine));
    expect(find.byIcon(Icons.lock_outline), findsNothing);
  });

  testWidgets('opening the sheet lists engrams; selecting one switches',
      (tester) async {
    await tester.pumpWidget(harness(_FakeRepo(discovery: discovery()), tutorial));

    await tester.tap(find.text('Tutorial'));
    await tester.pumpAndSettle();
    expect(find.text('Help'), findsOneWidget);
    expect(find.text('New engram'), findsOneWidget);

    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    expect(find.text('active:$builtinHelpId'), findsOneWidget);
  });

  testWidgets('New engram prompts for a name, creates, and switches',
      (tester) async {
    await tester.pumpWidget(harness(_FakeRepo(discovery: discovery()), tutorial));

    await tester.tap(find.text('Tutorial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New engram'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Journal');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('active:created-Journal'), findsOneWidget);
    expect(find.text('Journal'), findsWidgets); // footer renamed
  });

  testWidgets('an unavailable registry root is listed but disabled',
      (tester) async {
    final repo = _FakeRepo(
      discovery: discovery(unavailable: [
        const UnavailableEngram(
          id: 'gone',
          displayName: 'Archived',
          location: EngramLocation('/missing'),
        ),
      ]),
    );
    await tester.pumpWidget(harness(repo, tutorial));

    await tester.tap(find.text('Tutorial'));
    await tester.pumpAndSettle();

    expect(find.text('Archived'), findsOneWidget);
    expect(find.textContaining('Unavailable'), findsOneWidget);
    // Tapping a disabled row does nothing — still on the tutorial.
    await tester.tap(find.text('Archived'));
    await tester.pumpAndSettle();
    expect(find.text('active:$builtinTutorialId'), findsOneWidget);
  });

  testWidgets('Open folder… appears only on desktop', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(harness(_FakeRepo(discovery: discovery()), tutorial));
    await tester.tap(find.text('Tutorial'));
    await tester.pumpAndSettle();
    expect(find.text('Open folder…'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20)); // dismiss the sheet
    await tester.pumpAndSettle();

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(harness(_FakeRepo(discovery: discovery()), tutorial));
    await tester.tap(find.text('Tutorial'));
    await tester.pumpAndSettle();
    expect(find.text('Open folder…'), findsNothing);

    // Reset before the body ends: testWidgets checks foundation debug vars are
    // unset before group tearDown runs.
    debugDefaultTargetPlatformOverride = null;
  });

  group('adopting a folder', () {
    // The picker returns a real temporary folder, so the preview counts real
    // files; the repository is faked so no marker is written by the test.
    late Directory folder;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('switcher_adopt');
      await File('${folder.path}/one.md').writeAsString('1\r\n');
      await File('${folder.path}/two.md').writeAsString('2\n');
      await Directory('${folder.path}/.obsidian').create();
      await File('${folder.path}/.obsidian/app.json').writeAsString('{}');
    });

    tearDown(() {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    });

    Future<void> openFolder(WidgetTester tester) async {
      await tester.tap(find.text('Tutorial'));
      await tester.pumpAndSettle();
      // The preview lists the folder for real, so the tap and the I/O it
      // starts run under real time rather than the test's fake clock — and
      // so does the frame that puts the dialog up, so that it is listening
      // for the preview in the zone the preview completes in.
      await tester.runAsync(() async {
        await tester.tap(find.text('Open folder…'));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('asks first, naming the folder and counting its notes', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final repo = _FakeRepo(discovery: discovery());
      await tester.pumpWidget(
        harness(repo, tutorial, folderPicker: () async => folder.path),
      );

      await openFolder(tester);

      expect(find.text('Adopt this folder?'), findsOneWidget);
      final name = folder.path.split('/').last;
      expect(
        find.textContaining('“$name” will become an engram'),
        findsOneWidget,
      );
      expect(find.textContaining('2 files become notes'), findsOneWidget);
      expect(
        find.textContaining(
          'One of them uses Windows line endings and will be converted to LF '
          'now.',
        ),
        findsOneWidget,
        reason: 'the one-time rewrite, with its count, before it happens',
      );
      expect(repo.adopted, isEmpty, reason: 'nothing until confirmed');

      // The rest of the flow was started under real time, so its
      // continuation runs there too.
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, 'Adopt'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      expect(repo.adopted, [folder.path]);
      expect(find.text('active:adopted-${folder.path}'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a folder with no CRLF files says nothing about line endings',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      // Synchronous: real async I/O started in the test zone never completes.
      File('${folder.path}/one.md').writeAsStringSync('1\n');
      final repo = _FakeRepo(discovery: discovery());
      await tester.pumpWidget(
        harness(repo, tutorial, folderPicker: () async => folder.path),
      );

      await openFolder(tester);

      expect(find.text('Adopt this folder?'), findsOneWidget);
      expect(find.textContaining('line endings'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Cancel adopts nothing and stays put', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final repo = _FakeRepo(discovery: discovery());
      await tester.pumpWidget(
        harness(repo, tutorial, folderPicker: () async => folder.path),
      );

      await openFolder(tester);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      expect(repo.adopted, isEmpty);
      expect(find.text('active:$builtinTutorialId'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a cancelled picker asks nothing', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final repo = _FakeRepo(discovery: discovery());
      await tester.pumpWidget(
        harness(repo, tutorial, folderPicker: () async => null),
      );

      await openFolder(tester);

      expect(find.text('Adopt this folder?'), findsNothing);
      expect(repo.adopted, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('file access (Android)', () {
    Future<void> tapOpenFolder(WidgetTester tester) async {
      await tester.tap(find.text('Tutorial'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open folder…'));
      await tester.pumpAndSettle();
    }

    testWidgets('Open folder… follows the access, not the platform',
        (tester) async {
      await tester.pumpWidget(harness(
        _FakeRepo(discovery: discovery()),
        tutorial,
        folderAccess: FakeFolderAccess(canPick: false),
      ));
      await tester.tap(find.text('Tutorial'));
      await tester.pumpAndSettle();
      expect(find.text('Open folder…'), findsNothing);
    });

    testWidgets('without access, explains first; Cancel asks nothing more',
        (tester) async {
      final access = FakeFolderAccess(broadAccess: false);
      final repo = _FakeRepo(discovery: discovery());
      await tester.pumpWidget(harness(repo, tutorial, folderAccess: access));

      await tapOpenFolder(tester);
      expect(find.text('Allow access to your files?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(access.requests, 0, reason: 'Android is never asked');
      expect(access.picks, 0, reason: 'the chooser never opens');
      expect(repo.adopted, isEmpty);
    });

    testWidgets('Continue asks the platform, then opens the chooser',
        (tester) async {
      final access = FakeFolderAccess(broadAccess: false); // picks nothing
      await tester.pumpWidget(harness(
        _FakeRepo(discovery: discovery()),
        tutorial,
        folderAccess: access,
      ));

      await tapOpenFolder(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Continue'));
      await tester.pumpAndSettle();

      expect(access.requests, 1);
      expect(access.picks, 1);
    });

    testWidgets('access turned down on the system screen: no chooser',
        (tester) async {
      final access = FakeFolderAccess(broadAccess: false)..grants = false;
      await tester.pumpWidget(harness(
        _FakeRepo(discovery: discovery()),
        tutorial,
        folderAccess: access,
      ));

      await tapOpenFolder(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Continue'));
      await tester.pumpAndSettle();

      expect(access.requests, 1);
      expect(access.picks, 0);
    });

    testWidgets('a folder not on the device is refused, saying why',
        (tester) async {
      final access = FakeFolderAccess()
        ..pickError = const FolderNotLocalException('content://drive/…');
      final repo = _FakeRepo(discovery: discovery());
      await tester.pumpWidget(harness(repo, tutorial, folderAccess: access));

      await tapOpenFolder(tester);

      expect(find.text('This folder can’t be opened'), findsOneWidget);
      expect(find.textContaining('can only open a folder it can reach'),
          findsOneWidget);
      expect(find.textContaining('content://'), findsNothing,
          reason: 'the platform text is for the log');
      await tester.tap(find.widgetWithText(TextButton, 'OK'));
      await tester.pumpAndSettle();
      expect(repo.adopted, isEmpty);
    });

    for (final (label, error) in [
      ('an error the flow has no case for',
          PlatformException(code: 'noPicker', message: 'native words')),
      ('no platform side at all', MissingPluginException('native words')),
    ]) {
      testWidgets('a picker that fails — $label — says so, in words',
          (tester) async {
        final access = FakeFolderAccess()..pickError = error;
        final repo = _FakeRepo(discovery: discovery());
        await tester.pumpWidget(harness(repo, tutorial, folderAccess: access));

        await tapOpenFolder(tester);

        expect(find.text('Couldn’t choose a folder'), findsOneWidget);
        expect(find.textContaining('native words'), findsNothing,
            reason: 'the platform text is for the log');
        await tester.tap(find.widgetWithText(TextButton, 'OK'));
        await tester.pumpAndSettle();
        expect(repo.adopted, isEmpty);
        expect(find.text('active:$builtinTutorialId'), findsOneWidget);
      });
    }

    group('an engram that lost access', () {
      const far = UnavailableEngram(
        id: 'far',
        displayName: 'Field Notes',
        location: EngramLocation('/storage/emulated/0/Notes'),
        reason: UnreachableReason.accessNeeded,
      );

      Future<void> tapFar(WidgetTester tester) async {
        await tester.tap(find.text('Tutorial'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Field Notes'));
        await tester.pumpAndSettle();
      }

      testWidgets('says so, and differs from a lost folder or bookmark',
          (tester) async {
        await tester.pumpWidget(harness(
          _FakeRepo(
            discovery: discovery(unavailable: [
              far,
              const UnavailableEngram(
                id: 'moved',
                displayName: 'Moved',
                location: EngramLocation('/x'),
                reason: UnreachableReason.bookmarkInvalid,
              ),
            ]),
          ),
          tutorial,
        ));
        await tester.tap(find.text('Tutorial'));
        await tester.pumpAndSettle();

        expect(find.text('Needs access to your files — tap to grant'),
            findsOneWidget);
        expect(
          find.text(
              'Its folder can’t be found — open it again with Open folder…'),
          findsOneWidget,
        );
        final moved = tester.widget<ListTile>(find.ancestor(
          of: find.text('Moved'),
          matching: find.byType(ListTile),
        ));
        expect(moved.enabled, isFalse);
      });

      testWidgets('tapping it grants access and opens it', (tester) async {
        final access = FakeFolderAccess(broadAccess: false);
        final repo = _FakeRepo(discovery: discovery(unavailable: [far]));
        await tester.pumpWidget(harness(repo, tutorial, folderAccess: access));

        await tapFar(tester);
        expect(find.text('Allow access to your files?'), findsOneWidget);

        // With access, the folder resolves on the next discovery.
        repo.discovery = EngramDiscovery(
          available: [tutorial, help, _engram('far', 'Field Notes')],
          unavailable: const [],
        );
        await tester.tap(find.widgetWithText(TextButton, 'Continue'));
        await tester.pumpAndSettle();

        expect(access.requests, 1);
        expect(find.text('active:far'), findsOneWidget);
      });

      testWidgets('turning the explanation down changes nothing',
          (tester) async {
        final access = FakeFolderAccess(broadAccess: false);
        final repo = _FakeRepo(discovery: discovery(unavailable: [far]));
        await tester.pumpWidget(harness(repo, tutorial, folderAccess: access));

        await tapFar(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        expect(access.requests, 0);
        expect(find.text('active:$builtinTutorialId'), findsOneWidget);
      });

      testWidgets('granted, but the folder is gone too: stays put',
          (tester) async {
        final access = FakeFolderAccess(broadAccess: false);
        final repo = _FakeRepo(discovery: discovery(unavailable: [far]));
        await tester.pumpWidget(harness(repo, tutorial, folderAccess: access));

        await tapFar(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Continue'));
        await tester.pumpAndSettle();

        expect(access.requests, 1);
        expect(find.text('active:$builtinTutorialId'), findsOneWidget);
      });

      testWidgets('access refused on the system screen: stays put',
          (tester) async {
        final access = FakeFolderAccess(broadAccess: false)..grants = false;
        final repo = _FakeRepo(discovery: discovery(unavailable: [far]));
        await tester.pumpWidget(harness(repo, tutorial, folderAccess: access));

        await tapFar(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Continue'));
        await tester.pumpAndSettle();

        expect(access.requests, 1);
        expect(find.text('active:$builtinTutorialId'), findsOneWidget);
      });

      for (final error in [
        PlatformException(code: 'busy', message: 'native words'),
        MissingPluginException('native words'),
      ]) {
        testWidgets(
            'a request for access that fails says so '
            '(${error.runtimeType})', (tester) async {
          final access = FakeFolderAccess(broadAccess: false)
            ..requestError = error;
          final repo = _FakeRepo(discovery: discovery(unavailable: [far]));
          await tester.pumpWidget(
              harness(repo, tutorial, folderAccess: access));

          await tapFar(tester);
          await tester.tap(find.widgetWithText(TextButton, 'Continue'));
          await tester.pumpAndSettle();

          expect(find.text('Couldn’t choose a folder'), findsOneWidget);
          expect(find.textContaining('native words'), findsNothing);
          expect(find.text('active:$builtinTutorialId'), findsOneWidget);
        });
      }
    });
  });
}
