import 'package:flutter/material.dart';
import 'data/auth_gate.dart';
import 'data/settings_controller.dart';
import 'data/ucas_client.dart';
import 'ui/splash_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsController.load();

  // Global captcha/login coordination (single dialog, cooldowns).
  AuthGate.instance.configure(settings.username, settings.password);

  // Debug-only: inject an already-authenticated SEP session.
  // flutter run -d windows --dart-define=SEP_SESSION=<JSESSIONID>
  const injectedSepSession = String.fromEnvironment('SEP_SESSION');
  if (injectedSepSession.isNotEmpty) {
    await UcasClient.instance.setSepSessionId(injectedSepSession);
    debugPrint('[E2E] injected SEP session for testing');
  }

  runApp(UcasScheduleApp(settings: settings));
}

class UcasScheduleApp extends StatelessWidget {
  const UcasScheduleApp({super.key, required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: AuthGate.instance.navigatorKey,
      title: 'UCAS 课程表',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4F46E5)),
        useMaterial3: true,
        // iOS/macOS use Cupertino transitions by default; the explicit
        // CupertinoPageTransitionsBuilder was removed in newer Flutter.
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          },
        ),
      ),
      home: SplashPage(settings: settings),
    );
  }
}
