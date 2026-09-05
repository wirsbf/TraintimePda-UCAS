import 'package:flutter/material.dart';
import 'course_reviews_page.dart';
import 'score_page.dart';
import 'exam_page.dart';
import 'widget/swipe_back_route.dart';
import 'webview_page.dart';
import 'auto_select_page.dart';

import '../data/settings_controller.dart';
import '../data/auth_gate.dart';

class FunctionPage extends StatelessWidget {
  final SettingsController settings;

  const FunctionPage({super.key, required this.settings});

  Future<void> _handleServiceHallTap(BuildContext context) async {
    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // Ensure session via the global gate (throttled, single dialog);
      // no forced re-login on every visit - that needlessly burned sessions
      // and triggered extra captcha prompts.
      await AuthGate.instance.ensureLoggedIn();
    } catch (e) {
      debugPrint('Auto-login failed: $e');
      // Continue anyway
    } finally {
      if (context.mounted) {
        Navigator.of(context).pop(); // Close loading
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => WebViewPage(
              url: 'https://ehall.ucas.ac.cn',
              title: '办事大厅',
              settings: settings,
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('功能'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _FunctionTile(
            icon: Icons.score,
            title: '成绩查询',
            subtitle: '查询期末成绩与GPA',
            color: Colors.blue.shade100,
            iconColor: Colors.blue,
            onTap: () {
              Navigator.of(
                context,
              ).push(SwipeBackPageRoute(page: const ScorePage()));
            },
          ),
          const SizedBox(height: 12),
          _FunctionTile(
            icon: Icons.event_note,
            title: '考试安排',
            subtitle: '查看考试时间与地点',
            color: Colors.purple.shade100,
            iconColor: Colors.purple,
            onTap: () {
              Navigator.of(
                context,
              ).push(SwipeBackPageRoute(page: const ExamPage()));
            },
          ),
          const SizedBox(height: 12),
          _FunctionTile(
            icon: Icons.rate_review,
            title: '选课评价',
            subtitle: '查看课程评价与攻略',
            color: Colors.pink.shade100,
            iconColor: Colors.pink,
            onTap: () {
              Navigator.of(
                context,
              ).push(SwipeBackPageRoute(page: const CourseReviewsPage()));
            },
          ),
          const SizedBox(height: 12),
          _FunctionTile(
            icon: Icons.bolt,
            title: '自动抢课',
            subtitle: '7x24小时全自动蹲课脚本',
            color: Colors.red.shade100,
            iconColor: Colors.red,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AutoSelectPage(settings: settings),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _FunctionTile(
            icon: Icons.web,
            title: '办事大厅',
            subtitle: '访问数字果壳办事大厅',
            color: Colors.orange.shade100,
            iconColor: Colors.orange,
            onTap: () => _handleServiceHallTap(context),
          ),
          const SizedBox(height: 12),
          _FunctionTile(
            icon: Icons.forum,
            title: '果壳社区',
            subtitle: '浏览校园社区动态',
            color: Colors.green.shade100,
            iconColor: Colors.green,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => WebViewPage(
                    url: 'https://gkder.ucas.ac.cn/',
                    title: '果壳社区',
                    settings: settings,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _FunctionTile extends StatelessWidget {
  const _FunctionTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.color,
    required this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 28, color: iconColor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: Theme.of(context).colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
