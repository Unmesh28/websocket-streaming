import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'direct_webrtc_screen.dart';

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
  bool _micPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _urlController.text = widget.initialUrl;

    // Request microphone permission early
    _requestMicPermission();

    // Only auto-load if we have a real URL
    if (widget.initialUrl.isNotEmpty &&
        widget.initialUrl != 'https://' &&
        widget.initialUrl != 'http://') {
      _initWebView(widget.initialUrl);
    }
  }

  Future<void> _requestMicPermission() async {
    debugPrint('[WebView] Requesting microphone permission...');

    // Request both microphone and camera permissions
    // Some WebViews require both for getUserMedia to work properly
    final micStatus = await Permission.microphone.request();
    final cameraStatus = await Permission.camera.request();

    debugPrint('[WebView] Microphone status: $micStatus');
    debugPrint('[WebView] Camera status: $cameraStatus');

    setState(() {
      _micPermissionGranted = micStatus.isGranted;
    });

    if (micStatus.isGranted) {
      debugPrint('[WebView] Microphone permission GRANTED');
    } else if (micStatus.isDenied) {
      debugPrint('[WebView] Microphone permission DENIED');
    } else if (micStatus.isPermanentlyDenied) {
      debugPrint('[WebView] Microphone permission PERMANENTLY DENIED - user must enable in settings');
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
    late final PlatformWebViewControllerCreationParams params;

    // Platform-specific WebView parameters
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      // iOS/macOS - WKWebView
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final controller = WebViewController.fromPlatformCreationParams(params);

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
            debugPrint('[WebView] Page started: $url');
            setState(() {
              _isLoading = true;
            });
          },
          onPageFinished: (String url) {
            debugPrint('[WebView] Page finished: $url');
            setState(() {
              _isLoading = false;
              _hasLoadedUrl = true;
            });
            // Inject mic permission status and enable video playsinline
            _controller?.runJavaScript('''
              console.log('[Flutter] Page loaded, mic permission: $_micPermissionGranted');
              window.flutterMicGranted = $_micPermissionGranted;
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
      );

    // Platform-specific configuration
    if (controller.platform is AndroidWebViewController) {
      _configureAndroidWebView(controller.platform as AndroidWebViewController);
    } else if (controller.platform is WebKitWebViewController) {
      _configureIOSWebView(controller.platform as WebKitWebViewController);
    }

    // Load the URL
    controller.loadRequest(Uri.parse(url));

    _controller = controller;
    setState(() {
      _hasLoadedUrl = true;
    });
  }

  void _configureAndroidWebView(AndroidWebViewController androidController) {
    debugPrint('[WebView] Configuring Android WebView for media permissions');

    // Allow media playback without user gesture (required for autoplay)
    androidController.setMediaPlaybackRequiresUserGesture(false);

    // Handle permission requests from JavaScript (microphone, camera)
    androidController.setOnPlatformPermissionRequest((request) async {
      debugPrint('[WebView] Permission request from JS: ${request.types}');

      bool hasMic = request.types.contains(WebViewPermissionResourceType.microphone);
      bool hasCamera = request.types.contains(WebViewPermissionResourceType.camera);

      debugPrint('[WebView] Requested - Mic: $hasMic, Camera: $hasCamera');
      debugPrint('[WebView] Current app mic permission: $_micPermissionGranted');

      // Handle microphone permission
      if (hasMic) {
        if (_micPermissionGranted) {
          debugPrint('[WebView] GRANTING microphone permission to WebView (already granted to app)');
          request.grant();
        } else {
          // Try to request permission again from the system
          debugPrint('[WebView] Requesting mic permission from system...');
          final status = await Permission.microphone.request();
          debugPrint('[WebView] System mic permission result: $status');

          if (status.isGranted) {
            setState(() => _micPermissionGranted = true);
            debugPrint('[WebView] GRANTING microphone permission to WebView (just granted)');
            request.grant();
          } else {
            debugPrint('[WebView] DENYING microphone permission to WebView');
            request.deny();

            // Show a snackbar to inform user
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Microphone permission required for talk feature'),
                  action: SnackBarAction(
                    label: 'Settings',
                    onPressed: () => openAppSettings(),
                  ),
                ),
              );
            }
          }
        }
      } else if (hasCamera) {
        // Grant camera permission if requested
        debugPrint('[WebView] GRANTING camera permission');
        request.grant();
      } else {
        // Grant other permissions
        debugPrint('[WebView] GRANTING other permission: ${request.types}');
        request.grant();
      }
    });
  }

  void _configureIOSWebView(WebKitWebViewController iosController) {
    debugPrint('[WebView] Configuring iOS WebView for media permissions');
    // iOS WebView is configured via creation params above
    // Additional iOS-specific settings can be added here if needed
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

  void _openDirectWebRTC() {
    String url = _urlController.text.trim();

    // Validate URL
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a server URL first'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Ensure URL has protocol
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      if (RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(url)) {
        url = 'http://$url';
      } else {
        url = 'https://$url';
      }
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => DirectWebRTCScreen(serverUrl: url),
      ),
    );
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
          // Direct WebRTC button - switches to native WebRTC mode
          IconButton(
            icon: const Icon(Icons.cast_connected),
            onPressed: () => _openDirectWebRTC(),
            tooltip: 'Direct WebRTC (with Mic)',
          ),
          // Microphone status indicator
          if (_hasLoadedUrl)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                _micPermissionGranted ? Icons.mic : Icons.mic_off,
                color: _micPermissionGranted ? Colors.green : Colors.red,
                size: 20,
              ),
            ),
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
                      hintText: 'Enter server URL (e.g., http://3.110.83.74:8080)',
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
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.videocam,
                            size: 64,
                            color: Colors.deepPurple,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Enter server URL and tap Go',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Example: http://3.110.83.74:8080',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 24),
                          // Direct WebRTC option
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.grey[900],
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.deepPurple.withOpacity(0.5)),
                            ),
                            child: Column(
                              children: [
                                const Text(
                                  'For Push-to-Talk with Microphone',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                ElevatedButton.icon(
                                  onPressed: _openDirectWebRTC,
                                  icon: const Icon(Icons.cast_connected),
                                  label: const Text('Use Direct WebRTC'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Native WebRTC with full mic access',
                                  style: TextStyle(
                                    color: Colors.green,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
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
