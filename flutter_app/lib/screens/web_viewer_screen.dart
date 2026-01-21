import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

class WebViewerScreen extends StatefulWidget {
  final String initialUrl;

  const WebViewerScreen({
    super.key,
    required this.initialUrl,
  });

  @override
  State<WebViewerScreen> createState() => _WebViewerScreenState();
}

class _WebViewerScreenState extends State<WebViewerScreen> with WidgetsBindingObserver {
  WebViewController? _controller;
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;
  int _loadingProgress = 0;
  bool _hasLoadedUrl = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _urlController.text = widget.initialUrl;

    // Only auto-load if we have a real URL
    if (widget.initialUrl.isNotEmpty &&
        widget.initialUrl != 'https://' &&
        widget.initialUrl != 'http://') {
      _initWebView(widget.initialUrl);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle app lifecycle - refresh when coming back to foreground
    if (state == AppLifecycleState.resumed && _hasLoadedUrl && _controller != null) {
      // Inject JavaScript to check and reconnect if needed
      _controller!.runJavaScript('if(typeof checkAndReconnect === "function") checkAndReconnect();');
    }
  }

  void _initWebView(String url) {
    final controller = WebViewController();

    // Configure the controller
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            setState(() {
              _loadingProgress = progress;
            });
          },
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
            });
          },
          onPageFinished: (String url) {
            setState(() {
              _isLoading = false;
              _hasLoadedUrl = true;
            });
            // Enable hardware acceleration for video
            _controller?.runJavaScript('''
              document.querySelectorAll('video').forEach(v => {
                v.setAttribute('playsinline', '');
                v.setAttribute('webkit-playsinline', '');
              });
            ''');
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('[WebView] Error: ${error.description}');
            // Auto-retry on network errors
            if (error.errorType == WebResourceErrorType.connect ||
                error.errorType == WebResourceErrorType.timeout ||
                error.errorType == WebResourceErrorType.hostLookup) {
              Future.delayed(const Duration(seconds: 3), () {
                if (mounted) _controller?.reload();
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(url));

    // Enable hardware acceleration on Android
    if (controller.platform is AndroidWebViewController) {
      (controller.platform as AndroidWebViewController)
        ..setMediaPlaybackRequiresUserGesture(false);
    }

    _controller = controller;
    setState(() {
      _hasLoadedUrl = true;
    });
  }

  void _loadUrl() {
    String url = _urlController.text.trim();
    if (url.isEmpty) return;

    // Ensure URL has protocol - default to http for IP addresses
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      // Use http for IP addresses (no SSL), https for domains
      if (RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(url)) {
        url = 'http://$url';
      } else {
        url = 'https://$url';
      }
      _urlController.text = url;
    }

    setState(() {
      _isLoading = true;
    });

    if (_controller == null) {
      _initWebView(url);
    } else {
      _controller!.loadRequest(Uri.parse(url));
    }
  }

  void _refresh() {
    _controller?.reload();
  }

  void _hardRefresh() {
    // Clear cache and reload
    _controller?.clearCache();
    _controller?.reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Stream'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          if (_hasLoadedUrl) ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
              tooltip: 'Refresh',
            ),
            IconButton(
              icon: const Icon(Icons.cleaning_services),
              onPressed: _hardRefresh,
              tooltip: 'Hard Refresh (Clear Cache)',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // URL input bar
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.grey[900],
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      hintText: 'Enter server URL (e.g., http://1.2.3.4:8080)',
                      filled: true,
                      fillColor: Colors.grey[800],
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: const Icon(Icons.link, size: 20, color: Colors.white70),
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                    ),
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _loadUrl(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _loadUrl,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  child: const Text('Go'),
                ),
              ],
            ),
          ),

          // Loading progress indicator
          if (_isLoading)
            LinearProgressIndicator(
              value: _loadingProgress / 100,
              backgroundColor: Colors.grey[800],
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.deepPurple),
            ),

          // WebView or placeholder
          Expanded(
            child: _hasLoadedUrl && _controller != null
                ? WebViewWidget(controller: _controller!)
                : Container(
                    color: Colors.black,
                    child: const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.videocam,
                            size: 64,
                            color: Colors.deepPurple,
                          ),
                          SizedBox(height: 16),
                          Text(
                            'Enter server URL and tap Go',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Example: http://3.110.83.74:8080',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
