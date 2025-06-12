import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'auth_gate.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> requestPermissions() async {
  await [
    Permission.location,
    Permission.locationAlways,
    Permission.notification,
  ].request();

  if (await Permission.locationAlways.isDenied) {
    openAppSettings();
  }
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'my_foreground',
    'Foreground Service Notifications',
    description: 'This channel is used for important background service notifications.',
    importance: Importance.high,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: true,
      notificationChannelId: 'my_foreground',
      initialNotificationTitle: 'Ocular Sensus: Helping Nearby',
      initialNotificationContent: 'Scanning for emergencies around you...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      onForeground: onStart,
      onBackground: (_) async => true,
    ),
  );

  await service.startService();
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }

  if (service is AndroidServiceInstance) {
    service.on('stopService').listen((event) {
      service.stopSelf();
    });

    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });

    service.setForegroundNotificationInfo(
      title: "Ocular Sensus: Helping Nearby",
      content: "Scanning for emergencies around you...",
    );
  }

  // Updates foreground notification every 5 seconds
  Timer.periodic(const Duration(seconds: 5), (timer) async {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "Ocular Sensus: Still Watching...",
        content: "Background emergency check active",
      );
    }
  });

  // Actual emergency check every 5 minutes
  Timer.periodic(const Duration(minutes: 5), (timer) async {
    await _performBackgroundEmergencyScan(service);
  });
}

Future<void> _performBackgroundEmergencyScan(ServiceInstance service) async {
  try {
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    final userLat = position.latitude;
    final userLng = position.longitude;

    final querySnapshot = await FirebaseFirestore.instance
        .collection('devices')
        .where('isEmergency', isEqualTo: true)
        .get();

    bool emergencyNearby = false;
    String? nearestOwner;

    for (var doc in querySnapshot.docs) {
      final data = doc.data();
      final deviceLat = data['latitude'];
      final deviceLng = data['longitude'];
      final ownerName = data['ownerName'];

      final distance = Geolocator.distanceBetween(
        userLat, userLng, deviceLat, deviceLng,
      );

      if (distance < 1000) {
        emergencyNearby = true;
        nearestOwner = ownerName;
        break;
      }
    }

    if (service is AndroidServiceInstance) {
      if (emergencyNearby) {
        service.setForegroundNotificationInfo(
          title: "⚠️ Emergency Nearby!",
          content: "$nearestOwner needs help within 1km.",
        );

        await flutterLocalNotificationsPlugin.show(
          999,
          "⚠️ Emergency Nearby!",
          "$nearestOwner is in danger near you.",
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'my_foreground',
              'Emergency Alerts',
              importance: Importance.max,
              priority: Priority.high,
              showWhen: true,
            ),
          ),
        );
      } else {
        service.setForegroundNotificationInfo(
          title: "Ocular Sensus: Still Watching...",
          content: "No emergencies detected nearby.",
        );
      }
    }
  } catch (e) {
    print("❌ Error during emergency scan: $e");
  }
}


@pragma('vm:entry-point')
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await requestPermissions();
  await initializeService();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 224, 249, 254),
        ),
      ),
      home: AuthGate(),
    );
  }
}
