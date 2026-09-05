import 'package:flutter/material.dart';
import '../data/settings_controller.dart';
import '../data/cache_manager.dart';
import '../data/auth_gate.dart';
import '../data/ucas_client.dart';
import 'home_shell.dart';
import 'login_page.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key, required this.settings});

  final SettingsController settings;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  String _status = '正在启动...';
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();
    _startApp();
  }

  Future<void> _startApp() async {
    // Wait for the first frame: navigation and dialogs (AuthGate captcha)
    // must not race the initial route assembly.
    await WidgetsBinding.instance.endOfFrame;

    // 1. Check Login
    if (widget.settings.username.isEmpty) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => LoginPage(settings: widget.settings)),
        );
      }
      return;
    }

    // 2. Initialize Client (Pre-fetch all sessions)
    try {
      setState(() {
        _status = '正在验证身份...';
        _progress = 0.2;
      });

      final client = UcasClient.instance;
      
      // Use initialize() to pre-authenticate all systems
      try {
        await client.initialize(
          widget.settings.username,
          widget.settings.password,
        );
        
        setState(() {
          _status = '正在同步数据...';
          _progress = 0.5;
        });
      } on CaptchaRequiredException {
        // One coordinated captcha via the global gate; after a successful
        // solve, re-run initialize() so subsystem (jwxk/xkgo) sessions are
        // established serially BEFORE the parallel data fetches.
        if (await AuthGate.instance.ensureLoggedIn()) {
          try {
            await client.initialize(
              widget.settings.username,
              widget.settings.password,
            );
          } catch (_) {
            // Subsystem auth issues surface again in the fetch phase.
          }
        }
        // Proceed either way - pages fall back to cache when not logged in.
      } catch (e) {
        debugPrint('Initialization warning: $e');
        // Continue - individual pages will auto-retry
      }

      setState(() {
        _status = '正在加载数据...';
        _progress = 0.6;
      });

      // 3. Fetch Data in Parallel (using cached sessions)
      final fetchSchedule = client.fetchSchedule().then((val) {
        CacheManager().saveSchedule(val);
        return true;
      }).catchError((e) {
        debugPrint('Splash Schedule Error: $e');
        return false;
      });

      final fetchLectures = client.fetchLectures().then((val) {
        CacheManager().saveLectures(val);
        return true;
      }).catchError((e) {
        debugPrint('Splash Lectures Error: $e');
        return false;
      });

      final fetchExams = client.fetchExams().then((val) {
        CacheManager().saveExams(val);
        return true;
      }).catchError((e) {
        debugPrint('Splash Exams Error: $e');
        return false;
      });

      // Wait for all fetches
      final results = await Future.wait([fetchSchedule, fetchLectures, fetchExams]);
      
      // Update cache timestamp if at least one succeeded
      if (results.any((success) => success)) {
        await CacheManager().saveLastUpdateTime();
      }

    } catch (e) {
      debugPrint('Splash Error: $e');
      // Proceed to app - Dashboard will show cached data or retry UI
    } finally {
      if (mounted) {
        setState(() {
          _status = '完成！';
          _progress = 1.0;
        });
        // Small delay for visual feedback
        await Future.delayed(const Duration(milliseconds: 500));
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => HomeShell(settings: widget.settings),
            transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
            transitionDuration: const Duration(milliseconds: 600)
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Logo
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.school_rounded,
                size: 60,
                color: Theme.of(context).primaryColor,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'UCAS 课程表',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.grey[800],
              ),
            ),
            const SizedBox(height: 48),
            // Progress Bar
            SizedBox(
              width: 200,
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                backgroundColor: Colors.grey[200],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _status,
              style: TextStyle(color: Colors.grey[600], fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
