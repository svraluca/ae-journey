import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../firebase_options.dart';
import 'notifications_store.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('[Notif] background message: ${message.messageId}');
}

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final _messaging = FirebaseMessaging.instance;
  final _local = FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Routes a tapped notification's payload (e.g. resume a glow-up step).
  /// Set from `main.dart` after services are wired up.
  void Function(String payload)? onNotificationTap;

  Future<void> initialize({bool requestPermission = true}) async {
    if (_initialized) return;
    _initialized = true;

    await _initLocalNotifications();
    if (requestPermission) {
      await _requestFcmPermissions();
    }
    await _syncFcmTokenToUser();
    _listenForForegroundMessages();
    _listenForNotificationOpens();
  }

  /// Call once the home shell is mounted (e.g. from [AppShell]) to route cold-start taps.
  Future<void> handleInitialMessage() async {
    await initialize(requestPermission: false);
    final message = await _messaging.getInitialMessage();
    if (message == null) return;
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      _handleRemoteOpen(message);
    });
  }

  /// Call after login/sign-up success to show the iOS permission dialog.
  Future<void> requestPermissionAfterAuth() async {
    // Ensure local notifications are configured before requesting permissions.
    await initialize(requestPermission: false);
    await _requestFcmPermissions();
    await _syncFcmTokenToUser();
  }

  /// True when the user has already allowed push (or provisional on iOS).
  Future<bool> hasNotificationPermission() async {
    await initialize(requestPermission: false);
    final settings = await _messaging.getNotificationSettings();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  Future<void> _initLocalNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(android: android, iOS: ios);
    await _local.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          onNotificationTap?.call(payload);
        }
      },
    );

    if (Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        'glowpass_notifications',
        'ÆSTHETIC JOURNEY notifications',
        description: 'ÆSTHETIC JOURNEY reminders and updates',
        importance: Importance.high,
      );
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
    }
  }

  Future<void> _requestFcmPermissions() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    debugPrint('[Notif] permission: ${settings.authorizationStatus}');

    if (Platform.isIOS) {
      await _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }
  }

  /// Waits for APNs registration (required on iOS before FCM returns a token).
  Future<void> _ensureIosPushReady() async {
    if (!Platform.isIOS) return;
    for (var i = 0; i < 20; i++) {
      final apns = await _messaging.getAPNSToken();
      if (apns != null) {
        debugPrint('[Notif] APNs token: ok');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    debugPrint('[Notif] APNs token: still missing after wait');
  }

  Future<void> _syncFcmTokenToUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      if (Platform.isIOS) {
        await _ensureIosPushReady();
      }
      String? token = await _messaging.getToken();
      if ((token ?? '').isEmpty && Platform.isIOS) {
        await Future<void>.delayed(const Duration(seconds: 2));
        token = await _messaging.getToken();
      }
      debugPrint('[Notif] FCM token: ${token != null ? "${token.substring(0, 12)}…" : "null"}');
      if ((token ?? '').isEmpty) return;
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        {
          'fcmToken': token,
          'lastTokenUpdate': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('[Notif] token sync failed: $e');
    }

    _messaging.onTokenRefresh.listen((t) async {
      final u = FirebaseAuth.instance.currentUser;
      if (u == null || t.isEmpty) return;
      try {
        await FirebaseFirestore.instance.collection('users').doc(u.uid).set(
          {
            'fcmToken': t,
            'lastTokenUpdate': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      } catch (e) {
        debugPrint('[Notif] token refresh save failed: $e');
      }
    });
  }

  void _listenForForegroundMessages() {
    FirebaseMessaging.onMessage.listen((message) async {
      try {
        await _showLocalNotification(message);
      } catch (e) {
        debugPrint('[Notif] local show failed: $e');
      }
    });
  }

  void _listenForNotificationOpens() {
    FirebaseMessaging.onMessageOpenedApp.listen(_handleRemoteOpen);
  }

  void _handleRemoteOpen(RemoteMessage message) {
    final data = message.data;
    final type = (data['type'] as String?)?.trim();
    final notificationId = (data['notificationId'] as String?)?.trim();

    if (notificationId != null && notificationId.isNotEmpty) {
      unawaited(NotificationsStore.markAsRead(notificationId));
    }

    if (type != null && type.isNotEmpty) {
      onNotificationTap?.call(type);
      return;
    }

    final payload = _payloadFromData(data);
    if (payload != null && payload.isNotEmpty) {
      onNotificationTap?.call(payload);
    }
  }

  String? _payloadFromData(Map<String, dynamic> data) {
    if (data.isEmpty) return null;
    if (data.length == 1 && data.containsKey('type')) {
      return data['type'] as String?;
    }
    return jsonEncode(data);
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    final n = message.notification;
    if (n == null) return;

    final android = AndroidNotificationDetails(
      'glowpass_notifications',
      'ÆSTHETIC JOURNEY notifications',
      channelDescription: 'ÆSTHETIC JOURNEY reminders and updates',
      importance: Importance.high,
      priority: Priority.high,
    );
    const ios = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final id = DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);
    await _local.show(
      id,
      n.title,
      n.body,
      NotificationDetails(android: android, iOS: ios),
      payload: message.data.isNotEmpty ? _payloadFromData(message.data) : null,
    );
  }

  /// Fires a local notification from the app itself (e.g. when a background
  /// glow-up step finishes). Shows in foreground and background on iOS.
  Future<void> showLocalNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    await initialize(requestPermission: false);

    final android = AndroidNotificationDetails(
      'glowpass_notifications',
      'ÆSTHETIC JOURNEY notifications',
      channelDescription: 'ÆSTHETIC JOURNEY reminders and updates',
      importance: Importance.high,
      priority: Priority.high,
    );
    const ios = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final id = DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);
    await _local.show(
      id,
      title,
      body,
      NotificationDetails(android: android, iOS: ios),
      payload: payload,
    );
  }
}

