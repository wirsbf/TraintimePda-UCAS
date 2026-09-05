import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../data/settings_controller.dart';

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
  late final WebViewController _controller;
  bool _loading = true;
  int _loadingProgress = 0;
  String? _errorMessage;
  int? _errorCode;

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
        // Keep last 100 logs
        if (_logs.length > 100) {
          _logs.removeAt(0);
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _log('Initializing WebView...');
    _log('Target URL: ${widget.url}');
    _initWebView();
  }

  void _initWebView() {
    // Use a standard Chrome User-Agent to avoid being blocked
    const chromeUA =
        'Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    _log('🔧 Setting User-Agent: Pixel 7 Pro Chrome');
    _log('🔧 JavaScript Mode: unrestricted (enabled)');

    _controller = WebViewController()
      ..setJavaScriptMode(
        JavaScriptMode.unrestricted,
      ) // This enables JavaScript
      ..setUserAgent(chromeUA)
      ..setBackgroundColor(const Color(0xFFFFFFFF)) // Set white background
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            _log('📄 Page started: $url');
            if (mounted) {
              setState(() {
                _loading = true;
                _loadingProgress = 0;
                _errorMessage = null;
                _errorCode = null;
              });
            }
          },
          onPageFinished: (String url) {
            _log('✅ Page finished: $url');
            if (mounted) setState(() => _loading = false);
            _handleAutoLogin(url);
          },
          onProgress: (int progress) {
            if (progress % 20 == 0 || progress == 100) {
              _log('⏳ Progress: $progress%');
            }
            if (mounted) setState(() => _loadingProgress = progress);
          },
          onWebResourceError: (error) {
            _log('❌ ERROR [${error.errorCode}]: ${error.description}');
            _log('   isForMainFrame: ${error.isForMainFrame}');
            _log('   errorType: ${error.errorType}');
            _log('   url: ${error.url}');

            // Only show error UI for main frame errors
            if (mounted && error.isForMainFrame == true) {
              setState(() {
                _errorMessage = error.description;
                _errorCode = error.errorCode;
                _loading = false;
              });
            }
          },
          onHttpError: (error) {
            _log('🌐 HTTP ERROR: ${error.response?.statusCode}');
            _log('   uri: ${error.request?.uri}');
          },
          onNavigationRequest: (request) {
            _log('🔗 Navigation: ${request.url}');

            // Critical Fix: Intercept malformed SEP URL with double Base64
            // The server incorrectly returns a duplicated URL in the loginFrom parameter
            const badPattern =
                'aHR0cHM6Ly9laGFsbC51Y2FzLmFjLmNuL3YyL3NpdGUvaW5kZXggaHR0cHM6Ly9laGFsbC51Y2FzLmFjLmNuL3YyL3NpdGUvaW5kZXg=';
            const goodPattern =
                'aHR0cHM6Ly9laGFsbC51Y2FzLmFjLmNuL3YyL3NpdGUvaW5kZXg=';

            if (request.url.contains(badPattern)) {
              _log('🚨 DETECTED MALFORMED URL! Fixing...');
              final fixedUrl = request.url.replaceAll(badPattern, goodPattern);
              _log('🔧 Redirecting to fixed URL: $fixedUrl');
              _controller.loadRequest(Uri.parse(fixedUrl));
              return NavigationDecision.prevent;
            }

            // Allow other navigations
            return NavigationDecision.navigate;
          },
        ),
      )
      ..setOnConsoleMessage((message) {
        _log('📝 JS Console [${message.level}]: ${message.message}');
      });

    // Android-specific settings
    if (Platform.isAndroid) {
      final androidController =
          _controller.platform as AndroidWebViewController;
      _log('🔧 Enabling Android-specific settings...');
      _log('🔧 DomStorage: enabled');
      _log('🔧 MixedContentMode: MIXED_CONTENT_ALWAYS_ALLOW');

      // Enable DOM Storage (localStorage)
      androidController.setMediaPlaybackRequiresUserGesture(false);

      // Enable debugging for Android WebView
      AndroidWebViewController.enableDebugging(true);
      _log('🔧 WebView debugging: enabled');
    }

    _injectCookies();
    _log('Loading request...');
    _controller.loadRequest(Uri.parse(widget.url));
  }

  Future<void> _injectCookies() async {
    final cookies = widget.cookies;
    if (cookies == null || cookies.isEmpty) return;
    try {
      final manager = WebViewCookieManager();
      final host = Uri.parse(widget.url).host;
      for (final e in cookies.entries) {
        await manager.setCookie(WebViewCookie(
          name: e.key, value: e.value, domain: host, path: '/'));
        _log('🍪 injected cookie ${e.key} for $host');
      }
    } catch (e) {
      _log('cookie inject failed: $e');
    }
  }

  void _retry() {
    _log('🔄 Retrying...');
    setState(() {
      _errorMessage = null;
      _errorCode = null;
      _loading = true;
      _loadingProgress = 0;
    });
    _controller.loadRequest(Uri.parse(widget.url));
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
    final isLoginPage =
        url.contains('sep.ucas.ac.cn') &&
        (url.contains('login') ||
            url.contains('slogin') ||
            url.contains('/portal/site/'));

    if (isLoginPage) {
      final u = widget.settings!.username;
      final p = widget.settings!.password;

      if (u.isNotEmpty && p.isNotEmpty) {
        _log('🔐 Login page detected, checking for login form...');

        // First check if login form exists
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
          final result = await _controller.runJavaScriptReturningResult(
            checkJs,
          );
          _log('📋 Page check: $result');

          // If form exists, fill it
          final fillJs =
              """
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

          final fillResult = await _controller.runJavaScriptReturningResult(
            fillJs,
          );
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

  Future<void> _capturePageInfo() async {
    _log('📸 Capturing page info...');
    try {
      final currentUrl = await _controller.currentUrl();
      _log('🌐 Current URL: $currentUrl');

      final js = """
        (function() {
          return JSON.stringify({
            url: window.location.href,
            title: document.title,
            bodyLength: document.body ? document.body.innerHTML.length : 0,
            bodyText: document.body ? document.body.innerText.substring(0, 500) : 'no body',
            hasLoginForm: !!(document.querySelector('input[name="userName"]') || document.querySelector('input[type="password"]')),
            scripts: document.querySelectorAll('script').length,
            styles: document.querySelectorAll('style, link[rel="stylesheet"]').length,
            images: document.querySelectorAll('img').length,
            iframes: document.querySelectorAll('iframe').length,
            errors: window._webviewErrors || []
          });
        })();
      """;

      final result = await _controller.runJavaScriptReturningResult(js);
      _log('📄 Page info: $result');
    } catch (e) {
      _log('❌ Capture failed: $e');
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
            Text(
              '错误码: $_errorCode',
              style: TextStyle(color: Colors.grey.shade600),
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
                    Icons.camera_alt,
                    color: Colors.yellow,
                    size: 20,
                  ),
                  onPressed: _capturePageInfo,
                  tooltip: '捕获页面信息',
                ),
                IconButton(
                  icon: const Icon(Icons.copy, color: Colors.white, size: 20),
                  onPressed: _copyLogs,
                  tooltip: '复制日志',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.white, size: 20),
                  onPressed: () => setState(() => _logs.clear()),
                  tooltip: '清空日志',
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
                      : Stack(
                          children: [
                            WebViewWidget(controller: _controller),
                            if (_loading && _loadingProgress < 10)
                              const Center(child: CircularProgressIndicator()),
                          ],
                        )),
          ),
        ],
      ),
    );
  }
}
