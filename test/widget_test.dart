// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluttermodp/main.dart';
import 'package:fluttermodp/widgets/directory_picker_dialog.dart';

void main() {
  testWidgets('shows empty playlist controls', (WidgetTester tester) async {
    await tester.pumpWidget(const FlutterModp());

    expect(find.text('曲を追加'), findsOneWidget);
    expect(find.text('m3u読込'), findsOneWidget);
    expect(find.textContaining('プレイリストは空です'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('settings sheet shows download directory section',
      (WidgetTester tester) async {
    await tester.pumpWidget(const FlutterModp());

    // 再生設定（テンポ・スピードのシート）を開く。
    await tester.tap(find.byTooltip('再生設定'));
    await tester.pumpAndSettle();

    // 「ダウンロード」セクションはリストの下方にあるためスクロールする。
    final sheetScrollable = find
        .descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('ダウンロード'),
      200,
      scrollable: sheetScrollable,
    );
    await tester.pumpAndSettle();

    expect(find.text('ダウンロード'), findsOneWidget);
    expect(find.text('保存先フォルダ'), findsOneWidget);
    expect(find.text('初期値 (Documents/mods) に戻す'), findsOneWidget);
  });

  testWidgets('repeat and HTTP remote controls moved to the settings sheet',
      (WidgetTester tester) async {
    await tester.pumpWidget(const FlutterModp());

    // メイン画面にはもう表示されない。
    expect(find.text('1曲リピート'), findsNothing);
    expect(find.text('全曲リピート'), findsNothing);
    expect(find.text('HTTPリモコン'), findsNothing);

    // 設定シートを開く。
    await tester.tap(find.byTooltip('再生設定'));
    await tester.pumpAndSettle();

    // シート上部の「リピート再生」セクション。
    expect(find.text('リピート再生'), findsOneWidget);
    expect(find.text('1曲リピート'), findsOneWidget);
    expect(find.text('全曲リピート'), findsOneWidget);

    // 下方向へスクロールすると画面外の項目はツリーから除外されるため、
    // HTTPリモコンはスクロール後に検証する。
    final sheetScrollable = find
        .descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('HTTPリモコン'),
      100,
      scrollable: sheetScrollable,
    );
    await tester.pumpAndSettle();

    expect(find.text('HTTPリモコン'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('directory picker lists folders only and returns the selection',
      (WidgetTester tester) async {
    final tmpRoot = Directory.systemTemp.createTempSync('dirpicker_test');
    addTearDown(() {
      try {
        tmpRoot.deleteSync(recursive: true);
      } catch (_) {}
    });
    final root = Directory('${tmpRoot.path}/root')..createSync();
    final sub = Directory('${root.path}/sub')..createSync();
    File('${root.path}/dummy.txt').writeAsStringSync('x');

    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  picked = await showDialog<String>(
                    context: context,
                    builder: (_) => DirectoryPickerDialog(
                      initialDir: root,
                      rootDir: root,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // サブフォルダは表示され、ファイルは表示されない。
    expect(find.text('sub'), findsOneWidget);
    expect(find.text('dummy.txt'), findsNothing);

    // サブフォルダに入って選択する。
    await tester.tap(find.text('sub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('このフォルダを選択'));
    await tester.pumpAndSettle();

    expect(picked, _normalize(sub.path));
  });

  testWidgets('directory picker can create a new folder',
      (WidgetTester tester) async {
    final tmpRoot = Directory.systemTemp.createTempSync('dirpicker_test');
    addTearDown(() {
      try {
        tmpRoot.deleteSync(recursive: true);
      } catch (_) {}
    });
    final root = Directory('${tmpRoot.path}/root')..createSync();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showDialog<String>(
                  context: context,
                  builder: (_) => DirectoryPickerDialog(
                    initialDir: root,
                    rootDir: root,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新規フォルダ'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'mods');
    await tester.tap(find.text('作成'));
    await tester.pumpAndSettle();

    expect(Directory('${root.path}/mods').existsSync(), isTrue);
    // 作成したフォルダの中に移動し、そのパスが表示される。
    expect(find.textContaining('mods'), findsWidgets);
    expect(find.text('サブフォルダはありません'), findsOneWidget);
  });
}

/// 末尾のセパレーターを除いたパス（Windows 対応）。
String _normalize(String path) {
  var result = path.replaceAll('\\', '/');
  while (result.endsWith('/') && result.length > 1) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

