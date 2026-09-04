import 'package:flutter/material.dart';
import 'data/settings_controller.dart';
import 'ui/splash_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsController.load();
  runApp(UcasScheduleApp(settings: settings));
}

class UcasScheduleApp extends StatelessWidget {
  const UcasScheduleApp({super.key, required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
