import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/settings_controller.dart';
import '../data/ucas_client.dart';
import '../ui/webview_page.dart';

/// 打开需要 SEP 登录态的页面：
/// 移动端内部 WebView（注入 JSESSIONID 免登录）；桌面端外部浏览器。
class OpenUrlHelper {
  static Future<void> open(
    BuildContext context,
    String url,
    String title, {
    SettingsController? settings,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final cookie =
          await UcasClient.instance.sepPortal.currentSepCookieValue();
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WebViewPage(
          url: url,
          title: title,
          settings: settings,
          cookies: cookie.isEmpty ? null : {'JSESSIONID': cookie},
        ),
      ));
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
