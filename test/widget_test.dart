import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:safher/app.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      const ProviderScope(
        child: SafHerApp(),
      ),
    );

    // Initial load might be async if there are future providers but the shell route should render.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
