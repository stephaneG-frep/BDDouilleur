// Vérifie le stockage sécurisé RÉEL de la plateforme (trousseau GNOME via
// libsecret sous Linux, Android Keystore sous Android).
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('écriture, relecture et effacement dans le trousseau système', (tester) async {
    final store = SystemSecretStore();
    const key = 'itest.secret';
    final value = 'valeur-${DateTime.now().microsecondsSinceEpoch}';
    await store.write(key, value);
    expect(await store.read(key), value);
    await store.delete(key);
    expect(await store.read(key), isNull);
  });
}
