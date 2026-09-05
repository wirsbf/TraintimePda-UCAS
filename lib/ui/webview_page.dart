import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../data/settings_controller.dart';

/// 内嵌浏览器页（flutter_inappwebview 实现）。
///
/// 相比 webview_flutter，在小米/HyperOS 等国产 ROM 上稳定性更好
/// （见 flutter/flutter#73337 等长期反馈）。
///
/// 对外接口与旧版完全一致：url / title / settings / cookies。
class WebViewPage extends StatefulWidget {
  const WebViewPage({
    super.key,
    required this.url,
    required this.title,
    this.settings,
    this.cookies,
  });

  final String url;
  final String title;
  final SettingsController? settings;

  /// 注入到 WebView CookieStore 的 Cookie（如 SEP JSESSIONID），
  /// 用于免登录打开需要会话的页面。
  final Map<String, String>? cookies;

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  InAppWebViewController? _controller;
  bool _loading = true;
  int _loadingProgress = 0;
  String? _errorMessage;

  // Debug log list
  final List<String> _logs = [];
  bool _showLogs = false;

  void _log(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    final logEntry = '[$timestamp] $message';
    debugPrint('WebView: $message');
    if (mounted) {
      setState(() {
        _logs.add(logEntry);
        if (_logs.length > 100) {
          _logs.removeAt(0);
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _log('Initializing WebView (inappwebview)...');
    _log('Target URL: ${widget.url}');
    _injectCookies();
  }

  Future<void> _injectCookies() async {
    final cookies = widget.cookies;
    if (cookies == null || cookies.isEmpty) return;
    try {
      final host = Uri.parse(widget.url).host;
      for (final e in cookies.entries) {
        await CookieManager.instance().setCookie(
          url: WebUri('https://$host/'),
          name: e.key,
          value: e.value,
          domain: '.$host',
          path: '/',
        );
        _log('🍪 injected cookie ${e.key} for $host');
      }
    } catch (e) {
      _log('cookie inject failed: $e');
    }
  }

  // Use a standard Chrome User-Agent to avoid being blocked
  static const _chromeUA =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  InAppWebViewSettings get _settings => InAppWebViewSettings(
        javaScriptEnabled: true,
        userAgent: _chromeUA,
        transparentBackground: false,
        supportZoom: true,
        useShouldOverrideUrlLoading: true,
        // 国产 ROM 混合内容与媒体策略更宽松，减少渲染异常
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        mediaPlaybackRequiresUserGesture: false,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text(
                  '$_loadingProgress%',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
          // Log count badge
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: Icon(_showLogs ? Icons.terminal : Icons.bug_report),
                onPressed: () => setState(() => _showLogs = !_showLogs),
                tooltip: '查看日志',
              ),
              if (_logs.isNotEmpty && !_showLogs)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      '${_logs.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _retry,
            tooltip: '刷新',
          ),
        ],
      ),
      body: Column(
        children: [
          // Loading progress bar
          if (_loading)
            LinearProgressIndicator(
              value: _loadingProgress / 100,
              backgroundColor: Colors.grey.shade200,
            ),
          // Main content
          Expanded(
            child: _showLogs
                ? _buildLogPanel()
                : (_errorMessage != null
                    ? _buildErrorWidget()
                    : InAppWebView(
                        initialUrlRequest:
                            URLRequest(url: WebUri(widget.url)),
                        initialSettings: _settings,
                        onWebViewCreated: (controller) {
                          _controller = controller;
                          _log('WebView created');
                          if (Platform.isAndroid) {
                            InAppWebViewController
                                .setWebContentsDebuggingEnabled(true);
                          }
                        },
                        onLoadStart: (controller, url) {
                          _log('📄 Page started: $url');
                          if (mounted) {
                            setState(() {
                              _loading = true;
                              _loadingProgress = 0;
                              _errorMessage = null;
                            });
                          }
                        },
                        onLoadStop: (controller, url) async {
                          _log('✅ Page finished: $url');
                          if (mounted) setState(() => _loading = false);
                          await _handleAutoLogin('$url');
                        },
                        onProgressChanged: (controller, progress) {
                          if (progress % 20 == 0 || progress == 100) {
                            _log('⏳ Progress: $progress%');
                          }
                          if (mounted) {
                            setState(() => _loadingProgress = progress);
                          }
                        },
                        onReceivedError: (controller, request, error) {
                          _log('❌ ERROR [${error.type}]: ${error.description}');
                          if (request.isForMainFrame == true && mounted) {
                            setState(() {
                              _errorMessage = error.description;
                              _loading = false;
                            });
                          }
                        },
                        onConsoleMessage: (controller, message) {
                          _log('📝 JS Console [${message.messageLevel}]: '
                              '${message.message}');
                        },
                        shouldOverrideUrlLoading:
                            (controller, navigationAction) async {
                          final url = '${navigationAction.request.url}';
                          _log('🔗 Navigation: $url');

                          // Critical Fix: Intercept malformed SEP URL with
                          // double Base64 — the server incorrectly returns a
                          // duplicated URL in the loginFrom parameter.
                          const badPattern =
                              'aHR0cHM6Ly9laGFsbC51Y2FzLmFjLmNuL3YyL3NpdGUvaW5kZXggaHR0cHM6Ly9laGFsbC51Y2FzLmFjLmNuL3YyL3NpdGUvaW5kZXg=';
                          const goodPattern =
                              'aHR0cHM6Ly9laGFsbC51Y2FzLmFjLmNuL3YyL3NpdGUvaW5kZXg=';

                          if (url.contains(badPattern)) {
                            _log('🚨 DETECTED MALFORMED URL! Fixing...');
                            final fixedUrl =
                                url.replaceAll(badPattern, goodPattern);
                            _log('🔧 Redirecting to fixed URL: $fixedUrl');
                            controller.loadUrl(
                                urlRequest: URLRequest(url: WebUri(fixedUrl)));
                            return NavigationActionPolicy.CANCEL;
                          }

                          return NavigationActionPolicy.ALLOW;
                        },
                      )),
          ),
        ],
      ),
    );
  }

  void _retry() {
    _log('🔄 Retrying...');
    setState(() {
      _errorMessage = null;
      _loading = true;
      _loadingProgress = 0;
    });
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(widget.url)));
  }

  void _copyLogs() {
    final logText = _logs.join('\n');
    Clipboard.setData(ClipboardData(text: logText));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('日志已复制到剪贴板'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _handleAutoLogin(String url) async {
    if (widget.settings == null) return;

    // Check if on SEP Login page - expanded pattern matching
    final isLoginPage = url.contains('sep.ucas.ac.cn') &&
        (url.contains('login') ||
            url.contains('slogin') ||
            url.contains('/portal/site/'));

    if (isLoginPage) {
      final u = widget.settings!.username;
      final p = widget.settings!.password;

      if (u.isNotEmpty && p.isNotEmpty) {
        _log('🔐 Login page detected, checking for login form...');

        final checkJs = """
          (function() {
            var u = document.querySelector('input[name="userName"]');
            var p = document.querySelector('input[name="pwd"]');
            var btn = document.getElementById('sb');
            return JSON.stringify({
              hasUserField: !!u,
              hasPassField: !!p,
              hasButton: !!btn,
              bodyLength: document.body ? document.body.innerHTML.length : 0,
              title: document.title || 'no title'
            });
          })();
        """;

        try {
          final controller = _controller;
          if (controller == null) return;
          final result = await controller.evaluateJavascript(source: checkJs);
          _log('📋 Page check: $result');

          final fillJs = """
            (function() {
              var u = document.querySelector('input[name="userName"]');
              var p = document.querySelector('input[name="pwd"]');
              var btn = document.getElementById('sb');

              if (u && p && btn) {
                u.value = '$u';
                p.value = '$p';
                setTimeout(function() {
                  btn.click();
                }, 500);
                return 'filled';
              }
              return 'no_form';
            })();
          """;

          final fillResult =
              await controller.evaluateJavascript(source: fillJs);
          _log('🔐 Auto-login result: $fillResult');

          if (fillResult.toString().contains('filled') && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('正在自动登录...'),
                duration: Duration(seconds: 1),
              ),
            );
          }
        } catch (e) {
          _log('❌ Auto-login check failed: $e');
        }
      }
    }
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            const Text(
              '页面加载失败',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _errorMessage ?? '未知错误',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
            const SizedBox(height: 16),
            Text(
              '提示：请检查网络连接，或点击右上角查看日志',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogPanel() {
    return Container(
      color: Colors.black87,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: Colors.black,
            child: Row(
              children: [
                const Text(
                  '调试日志',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(
                    Icons.copy,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: _copyLogs,
                  tooltip: '复制日志',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.white, size: 20),
                  onPressed: () => setState(() => _logs.clear()),
                  tooltip: '清空',
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 20),
                  onPressed: () => setState(() => _showLogs = false),
                  tooltip: '关闭',
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final log = _logs[index];
                Color textColor = Colors.white70;
                if (log.contains('❌') || log.contains('ERROR')) {
                  textColor = Colors.red.shade300;
                } else if (log.contains('✅')) {
                  textColor = Colors.green.shade300;
                } else if (log.contains('⏳')) {
                  textColor = Colors.blue.shade300;
                }
                return Text(
                  log,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
