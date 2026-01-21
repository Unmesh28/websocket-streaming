import 'package:flutter/material.dart';
import 'screens/web_viewer_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PiCameraApp());
}

class PiCameraApp extends StatelessWidget {
  const PiCameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pi Camera Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const WebViewerScreen(initialUrl: 'https://'),
    );
  }
}
