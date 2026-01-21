import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class WebViewerScreen extends StatefulWidget {
  final String initialUrl;

  const WebViewerScreen({
    super.key,
    required this.initialUrl,
  });

  @override
  State<WebViewerScreen> createState() => _WebViewerScreenState();
}

class _WebViewerScreenState extends State<WebViewerScreen> {
  WebViewController? _controller;
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;
  int _loadingProgress = 0;
  bool _hasLoadedUrl = false;

  @override
  void initState() {
    super.initState();
    _urlController.text = widget.initialUrl;

    // Only auto-load if we have a real URL
    if (widget.initialUrl.isNotEmpty &&
        widget.initialUrl != 'https://' &&
        widget.initialUrl != 'http://') {
      _initWebView(widget.initialUrl);
    }
  }

  void _initWebView(String url) {
    _controller = WebViewController()
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
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('[WebView] Error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(url));

    setState(() {
      _hasLoadedUrl = true;
    });
  }

  void _loadUrl() {
    String url = _urlController.text.trim();
    if (url.isEmpty) return;

    // Ensure URL has protocol
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
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

  @override
  void dispose() {
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
        automaticallyImplyLeading: false, // No back button on home screen
        actions: [
          if (_hasLoadedUrl)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
              tooltip: 'Refresh',
            ),
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
                      hintText: 'Enter server URL (e.g., https://xxx.trycloudflare.com)',
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
