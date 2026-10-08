import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'data/procedure_repository.dart';
import 'firebase_options.dart';
import 'services/app_navigator.dart';
import 'services/glow_up_job.dart';
import 'services/glow_up_progress_notification.dart';
import 'services/notification_navigation.dart';
import 'services/notification_service.dart';
import 'services/progress_share_link_handler.dart';
import 'services/saved_bookmarks_store.dart';
import 'ui/splash_screen.dart';

Future<void> main() async {
  // ignore: avoid_print
  print('[GP] main() start');
  WidgetsFlutterBinding.ensureInitialized();
  // ignore: avoid_print
  print('[GP] binding ready');
  await dotenv.load(fileName: '.env');
  // ignore: avoid_print
  print('[GP] dotenv loaded');
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  // Resume a backgrounded glow-up step when its notification is tapped.
  NotificationService.instance.onNotificationTap = NotificationNavigation.handlePayload;
  // ignore: avoid_print
  print('[GP] Firebase ready');
  final repo = ProcedureRepository();
  // ignore: avoid_print
  print('[GP] repo built');
  await GlowUpJobController.instance.initialize();
  await GlowUpProgressNotification.instance.initialize();
  SavedBookmarksStore.instance.startListening();
  // ignore: avoid_print
  print('[GP] glow-up jobs restored');
  await ProgressShareLinkHandler.instance.start();
  runApp(GlowPassApp(repo: repo));
  // ignore: avoid_print
  print('[GP] runApp called');
}

class GlowPassApp extends StatelessWidget {
  const GlowPassApp({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6B5FA8)),
    );

    final textTheme = GoogleFonts.interTextTheme(base.textTheme);

    return MaterialApp(
      title: 'ÆSTHETIC JOURNEY',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appMessengerKey,
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFFEFF2F6),
        textTheme: textTheme,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      ),
      home: SplashScreen(repo: repo),
    );
  }
}
