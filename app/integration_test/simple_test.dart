import 'package:flutter_test/flutter_test.dart';
import 'package:talkye_app/main.dart';
import 'package:talkye_app/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());
  testWidgets('Can call rust function', (WidgetTester tester) async {
    await tester.pumpWidget(const TalkyeApp());
    await tester.pumpAndSettle();
    expect(find.text('Talkye Meet'), findsOneWidget);
  });
}
