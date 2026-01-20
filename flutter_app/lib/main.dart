import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/webrtc_service.dart';
import 'screens/stream_viewer_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PiCameraApp());
}

class PiCameraApp extends StatelessWidget {
  const PiCameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => WebRTCService(),
      child: MaterialApp(
        title: 'Pi Camera Viewer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const StreamViewerScreen(),
      ),
    );
  }
}
