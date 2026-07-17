import 'package:dio/dio.dart';
import 'package:fitness_app/core/update_gate.dart';
import 'package:fitness_app/core/version_check_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeVersionCheckService implements VersionCheckService {
  _FakeVersionCheckService({this.minBuild = 0, this.error});

  final int minBuild;
  final Object? error;

  @override
  Future<int> fetchMinSupportedBuild() async {
    final error = this.error;
    if (error != null) throw error;
    return minBuild;
  }
}

DioException _networkError() => DioException(
  requestOptions: RequestOptions(path: '/health/'),
  type: DioExceptionType.connectionError,
);

Future<void> _pumpGate(
  WidgetTester tester, {
  required VersionCheckService service,
  Future<String> Function()? loadBuildNumber,
  Future<bool> Function(Uri url)? openUrl,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: UpdateGate(
        versionService: service,
        loadBuildNumber: loadBuildNumber ?? () async => '1',
        openUrl: openUrl ?? (_) async => true,
        child: const Scaffold(body: Text('app content')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Simulates the Android system back button the way the engine delivers it.
Future<void> _pressSystemBack(WidgetTester tester) async {
  final message = const JSONMethodCodec().encodeMethodCall(
    const MethodCall('popRoute'),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (_) {},
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('build below the minimum shows the blocking dialog', (
    tester,
  ) async {
    await _pumpGate(
      tester,
      service: _FakeVersionCheckService(minBuild: 42),
      loadBuildNumber: () async => '41',
    );

    expect(find.text('Update required'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Update'), findsOneWidget);
  });

  testWidgets('the dialog survives system back and barrier taps', (
    tester,
  ) async {
    await _pumpGate(
      tester,
      service: _FakeVersionCheckService(minBuild: 42),
      loadBuildNumber: () async => '41',
    );

    await _pressSystemBack(tester);
    expect(find.text('Update required'), findsOneWidget);

    // Tap outside the dialog — the barrier must not dismiss it either.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Update required'), findsOneWidget);
  });

  testWidgets('build at the minimum starts normally', (tester) async {
    await _pumpGate(
      tester,
      service: _FakeVersionCheckService(minBuild: 42),
      loadBuildNumber: () async => '42',
    );

    expect(find.text('Update required'), findsNothing);
    expect(find.text('app content'), findsOneWidget);
  });

  testWidgets('network error fails open — the app starts normally', (
    tester,
  ) async {
    await _pumpGate(
      tester,
      service: _FakeVersionCheckService(error: _networkError()),
      loadBuildNumber: () async => '1',
    );

    expect(find.text('Update required'), findsNothing);
    expect(find.text('app content'), findsOneWidget);
  });

  testWidgets('unparsable build number fails open', (tester) async {
    await _pumpGate(
      tester,
      service: _FakeVersionCheckService(minBuild: 42),
      loadBuildNumber: () async => 'not-a-number',
    );

    expect(find.text('Update required'), findsNothing);
    expect(find.text('app content'), findsOneWidget);
  });

  testWidgets('minimum of 0 skips the build-number lookup entirely', (
    tester,
  ) async {
    var buildNumberQueried = false;
    await _pumpGate(
      tester,
      service: _FakeVersionCheckService(minBuild: 0),
      loadBuildNumber: () async {
        buildNumberQueried = true;
        return '1';
      },
    );

    expect(find.text('Update required'), findsNothing);
    expect(buildNumberQueried, isFalse);
  });

  testWidgets('Update opens the Play listing', (tester) async {
    Uri? opened;
    await _pumpGate(
      tester,
      service: _FakeVersionCheckService(minBuild: 42),
      loadBuildNumber: () async => '41',
      openUrl: (url) async {
        opened = url;
        return true;
      },
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();

    expect(opened, Uri.parse(kPlayStoreUrl));
    // Coming back from the store without updating leaves the gate up.
    expect(find.text('Update required'), findsOneWidget);
  });
}
