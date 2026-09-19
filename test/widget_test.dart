import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zunoai_admin/features/auth/presentation/admin_login_screen.dart';

void main() {
  testWidgets('Admin login screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: AdminLoginScreen()),
      ),
    );

    expect(find.text('Zuno AI Admin'), findsOneWidget);
    expect(find.text('Login to Dashboard'), findsOneWidget);
  });
}
