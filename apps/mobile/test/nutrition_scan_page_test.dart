import 'package:fitness_app/features/nutrition/nutrition_scan_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Overrides every platform-channel-touching member so the page can be
/// mounted in widget tests; state is driven directly through [value].
class _FakeScannerController extends MobileScannerController {
  _FakeScannerController(MobileScannerState initial) {
    value = initial;
  }

  int startCalls = 0;

  @override
  Future<void> start({CameraFacing? cameraDirection}) async {
    startCalls++;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> toggleTorch() async {
    value = value.copyWith(
      torchState: value.torchState == TorchState.on
          ? TorchState.off
          : TorchState.on,
    );
  }

  // super.dispose() tears down platform-channel resources that don't exist
  // in tests.
  @override
  // ignore: must_call_super
  Future<void> dispose() async {}
}

MobileScannerState _errorState(MobileScannerErrorCode code) {
  return MobileScannerState.uninitialized(CameraFacing.back).copyWith(
    isInitialized: true,
    error: MobileScannerException(errorCode: code),
  );
}

void main() {
  Future<void> pumpScanPage(
    WidgetTester tester,
    _FakeScannerController controller, {
    Future<void> Function()? openAppSettings,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: NutritionScanPage(
          controller: controller,
          openAppSettings: openAppSettings,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('permission denied shows explanation with Open settings', (
    WidgetTester tester,
  ) async {
    final controller = _FakeScannerController(
      _errorState(MobileScannerErrorCode.permissionDenied),
    );
    var settingsOpened = false;

    await pumpScanPage(
      tester,
      controller,
      openAppSettings: () async => settingsOpened = true,
    );

    expect(find.textContaining('Camera access is turned off'), findsOneWidget);

    await tester.tap(find.text('Open settings'));
    expect(settingsOpened, isTrue);
  });

  testWidgets('Try again restarts the camera after an error', (
    WidgetTester tester,
  ) async {
    final controller = _FakeScannerController(
      _errorState(MobileScannerErrorCode.permissionDenied),
    );

    await pumpScanPage(tester, controller);
    final startCallsAfterMount = controller.startCalls;

    await tester.tap(find.text('Try again'));
    expect(controller.startCalls, startCallsAfterMount + 1);
  });

  testWidgets('generic camera error gets retry but no settings action', (
    WidgetTester tester,
  ) async {
    final controller = _FakeScannerController(
      _errorState(MobileScannerErrorCode.genericError),
    );

    await pumpScanPage(tester, controller);

    expect(find.textContaining('could not start'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Open settings'), findsNothing);
  });

  testWidgets('torch button is hidden while the torch is unavailable', (
    WidgetTester tester,
  ) async {
    final controller = _FakeScannerController(
      MobileScannerState.uninitialized(CameraFacing.back),
    );

    await pumpScanPage(tester, controller);

    expect(find.byIcon(Icons.flash_off), findsNothing);
    expect(find.byIcon(Icons.flash_on), findsNothing);
  });

  testWidgets('torch button toggles between off and on', (
    WidgetTester tester,
  ) async {
    final controller = _FakeScannerController(
      MobileScannerState.uninitialized(
        CameraFacing.back,
      ).copyWith(torchState: TorchState.off),
    );

    await pumpScanPage(tester, controller);

    expect(find.byIcon(Icons.flash_off), findsOneWidget);

    await tester.tap(find.byIcon(Icons.flash_off));
    await tester.pump();

    expect(find.byIcon(Icons.flash_on), findsOneWidget);
    expect(find.byIcon(Icons.flash_off), findsNothing);
  });
}
