import 'package:integration_test/integration_test.dart';

import '../test/self_host_navigation_test.dart' show selfHostNavigationTests;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  selfHostNavigationTests();
}
