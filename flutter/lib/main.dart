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

// This set tracks device IDs for which an emergency notification has already been shown.
// It is static so its state persists across background service runs.
Set<String> _notifiedEmergencyDeviceIds = {};

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
  // Ensure that plugins are initialized for this background isolate
  DartPluginRegistrant.ensureInitialized();

  // Initialize Firebase for the background isolate
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }

  // Initialize FlutterLocalNotificationsPlugin for the background isolate
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher'); // Use your app's launcher icon
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  if (service is AndroidServiceInstance) {
    // Explicitly cast and assign to a local variable to ensure type promotion
    final androidService = service;

    androidService.on('stopService').listen((event) {
      androidService.stopSelf();
    });

    androidService.on('setAsForeground').listen((event) {
      androidService.setAsForegroundService();
    });

    androidService.on('setAsBackground').listen((event) {
      androidService.setAsBackgroundService();
    });

    // Set initial notification for the foreground service.
    androidService.setForegroundNotificationInfo(
      title: "Ocular Sensus: Helping Nearby",
      content: "Scanning for emergencies around you...",
    );
  }

  // Actual emergency check every 1 minute.
  Timer.periodic(const Duration(minutes: 1), (timer) async {
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
        .where('emergency', isEqualTo: true) // Using 'emergency' field
        .get();

    bool emergencyNearbyFound = false;
    String? nearestEmergencyOwner;
    double? nearestEmergencyThreshold;
    
    // Create a temporary set for emergencies found in this scan
    final Set<String> currentScanEmergencyIds = {};

    for (var doc in querySnapshot.docs) {
      final data = doc.data();
      final deviceId = doc.id; // Get the document ID for tracking
      final deviceLat = data['latitude'];
      final deviceLng = data['longitude'];
      final ownerName = data['ownerName'];
      final isHelpComing = data['isHelpComing'] == true;

      // Retrieve emergency_threshold; default to 0.0 if not found or invalid
      // This ensures that missing 'emergency_threshold' defaults to "no limit".
      final double threshold = (data['emergency_threshold'] as num?)?.toDouble() ?? 0.0;

      if (deviceLat != null && deviceLng != null && !isHelpComing) {
        final distance = Geolocator.distanceBetween(
          userLat, userLng, deviceLat, deviceLng,
        );

        // Logic: If threshold is 0.0, any distance is considered "nearby".
        // Otherwise, standard distance comparison applies.
        if (threshold == 0.0 || distance <= threshold) {
          emergencyNearbyFound = true;
          nearestEmergencyOwner = ownerName;
          nearestEmergencyThreshold = threshold;
          currentScanEmergencyIds.add(deviceId); // Add to set of currently active emergencies

          // Construct the content string based on the threshold
          String notificationContent;
          if (nearestEmergencyThreshold != null && nearestEmergencyThreshold == 0.0) {
            notificationContent = "$nearestEmergencyOwner needs help (emergency threshold is disabled).";
          } else if (nearestEmergencyThreshold != null) {
            notificationContent = "$nearestEmergencyOwner needs help within "
                                  "${(nearestEmergencyThreshold / 1000).toStringAsFixed(1)}km.";
          } else {
            notificationContent = "$nearestEmergencyOwner needs help."; // Fallback
          }

          // Only update the foreground service notification if we haven't already notified for this specific device
          // and let this be the primary alert.
          if (!_notifiedEmergencyDeviceIds.contains(deviceId)) {
            if (service is AndroidServiceInstance) {
              final androidService = service;
              androidService.setForegroundNotificationInfo(
                title: "⚠️ Emergency Nearby!",
                content: notificationContent, // Use the new content string
              );
            }
            // Removed the flutterLocalNotificationsPlugin.show() call here
            // to prevent duplicate notifications for the same emergency.
            _notifiedEmergencyDeviceIds.add(deviceId); // Mark as notified
          }
          // We don't break here so we can process all potentially active emergencies
          // and correctly manage _notifiedEmergencyDeviceIds.
        }
      }
    }

    // Remove device IDs from our 'notified' set if they are no longer active emergencies
    _notifiedEmergencyDeviceIds.retainWhere((id) => currentScanEmergencyIds.contains(id));

    if (service is AndroidServiceInstance && !emergencyNearbyFound) {
      final androidService = service;
      // If no emergency was found in this scan, revert foreground notification
      // to its initial state to indicate no active issues.
      androidService.setForegroundNotificationInfo(
        title: "Ocular Sensus: Helping Nearby",
        content: "Scanning for emergencies around you...",
      );
    }
  } catch (e) {
    print("❌ Error during emergency scan: $e");
    if (service is AndroidServiceInstance) {
      final androidService = service;
      androidService.setForegroundNotificationInfo(
        title: "Ocular Sensus: Scan Error",
        content: "Could not perform emergency scan.",
      );
    }
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
