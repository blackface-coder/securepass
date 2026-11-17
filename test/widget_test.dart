import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

import 'package:code_serure/main.dart';

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  late FlutterSecureStoragePlatform originalPlatform;
  late Map<String, String> secureData;

  setUp(() {
    originalPlatform = FlutterSecureStoragePlatform.instance;
    secureData = {};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      secureData,
    );
  });

  tearDown(() {
    FlutterSecureStoragePlatform.instance = originalPlatform;
  });

  testWidgets('creates a confirmed code and opens an empty vault', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await tester.pumpWidget(const PasswordVaultApp());
    await tester.pumpAndSettle();

    expect(find.text('Créez votre code principal'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(0), 'moncodefort');
    await tester.enterText(find.byType(TextFormField).at(1), 'paspareil');
    await tapVisible(tester, find.text('Créer mon coffre'));
    expect(find.text('Les codes ne correspondent pas.'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(1), 'moncodefort');
    await tapVisible(tester, find.text('Créer mon coffre'));
    final recoveryKey = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    await tapVisible(tester, find.text('Copier la clé'));
    expect(find.text('Clé de récupération copiée.'), findsNWidgets(2));
    expect(copiedText, recoveryKey);
    await tester.tap(find.text('J’ai conservé ma clé'));
    await tester.pumpAndSettle();

    expect(find.text('Votre coffre est vide'), findsOneWidget);
    expect(find.text('Ajouter'), findsOneWidget);
  });

  testWidgets('adds, edits, deletes an entry and locks the vault', (
    tester,
  ) async {
    await tester.pumpWidget(const PasswordVaultApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'moncodefort');
    await tester.enterText(find.byType(TextFormField).at(1), 'moncodefort');
    await tapVisible(tester, find.text('Créer mon coffre'));
    await tapVisible(tester, find.text('J’ai conservé ma clé'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ajouter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Exemple');
    await tester.enterText(find.byType(TextFormField).at(1), 'moi@example.com');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret123');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(find.text('Exemple'), findsOneWidget);
    expect(find.text('secret123'), findsNothing);

    await tester.tap(find.text('Exemple'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Exemple modifié');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(find.text('Exemple modifié'), findsOneWidget);

    await tester.tap(find.text('Exemple modifié'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer').last);
    await tester.pumpAndSettle();
    expect(find.text('Votre coffre est vide'), findsOneWidget);

    await tester.tap(find.byTooltip('Verrouiller le coffre'));
    await tester.pumpAndSettle();
    expect(find.text('Bienvenue'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, 'mauvaiscode');
    await tapVisible(tester, find.text('Déverrouiller'));
    expect(find.textContaining('Code incorrect.'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, 'moncodefort');
    await tapVisible(tester, find.text('Déverrouiller'));
    expect(find.text('Votre coffre est vide'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const PasswordVaultApp());
    await tester.pumpAndSettle();
    expect(find.text('Bienvenue'), findsOneWidget);
  });

  testWidgets('requires explicit reset after ten incorrect codes', (
    tester,
  ) async {
    await tester.pumpWidget(const PasswordVaultApp());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'moncodefort');
    await tester.enterText(find.byType(TextFormField).at(1), 'moncodefort');
    await tapVisible(tester, find.text('Créer mon coffre'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('J’ai conservé ma clé'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ajouter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Compte privé');
    await tester.enterText(find.byType(TextFormField).at(1), 'moi@example.com');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret123');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Verrouiller le coffre'));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.enterText(find.byType(TextFormField).first, 'codeincorrect');
      await tapVisible(tester, find.text('Déverrouiller'));
    }

    expect(find.text('Bienvenue'), findsOneWidget);
    expect(find.textContaining('Dix codes incorrects'), findsOneWidget);
    expect(secureData, isNotEmpty);

    await tapVisible(tester, find.text('Réinitialiser le coffre'));
    expect(
      find.text(
        'Cette action effacera définitivement toutes les entrées enregistrées sur cet appareil. Elles ne pourront pas être récupérées. N’utilisez cette option que si vous ne pouvez pas retrouver votre clé de récupération.',
      ),
      findsOneWidget,
    );
    await tapVisible(tester, find.text('Effacer et réinitialiser'));
    expect(find.text('Créez votre code principal'), findsOneWidget);
    expect(secureData, isEmpty);
  });

  testWidgets('recovers the master code and preserves vault entries', (
    tester,
  ) async {
    await tester.pumpWidget(const PasswordVaultApp());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'moncodefort');
    await tester.enterText(find.byType(TextFormField).at(1), 'moncodefort');
    await tapVisible(tester, find.text('Créer mon coffre'));
    final recoveryKey = (tester.widget<SelectableText>(
      find.byType(SelectableText),
    )).data!;
    expect(recoveryKey, matches(RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{8}){7}$')));
    await tester.tap(find.text('J’ai conservé ma clé'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ajouter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Exemple');
    await tester.enterText(find.byType(TextFormField).at(1), 'moi@example.com');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret123');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Verrouiller le coffre'));
    await tester.pumpAndSettle();

    await tapVisible(tester, find.text('Code principal oublié ?'));
    await tester.enterText(find.byType(TextFormField).at(1), 'cleincorrecte');
    await tapVisible(tester, find.text('Vérifier la clé'));
    expect(find.text('Clé de récupération incorrecte.'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(1), recoveryKey);
    await tapVisible(tester, find.text('Vérifier la clé'));
    await tester.enterText(find.byType(TextFormField).at(1), 'nouveaucode');
    await tester.enterText(find.byType(TextFormField).at(2), 'nouveaucode');
    await tapVisible(tester, find.text('Définir le nouveau code'));

    expect(find.text('Exemple'), findsOneWidget);
    await tester.tap(find.byTooltip('Verrouiller le coffre'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'nouveaucode');
    await tapVisible(tester, find.text('Déverrouiller'));
    expect(find.text('Exemple'), findsOneWidget);
  });
}
