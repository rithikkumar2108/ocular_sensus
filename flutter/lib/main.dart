import 'dart:async';
import 'dart:ui'; // Used for DartPluginRegistrant.ensureInitialized()
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart'; // Make sure this file exists and is correctly configured
import 'auth_gate.dart'; // Assuming this is your authentication entry point
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart'; // Added for AndroidServiceInstance
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart'; // Import device_info_plus
import 'dart:io';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Store device IDs that have already triggered an EMERGENCY notification.
// This prevents repeated emergency notifications for the same device.
Set<String> _notifiedEmergencyDeviceIds = {};

// Store device IDs for which 'help is coming' notification was sent.
// This prevents repeated 'help is coming' notifications for the same device.
Set<String> _notifiedHelpComingDeviceIds = {};

// Global variables for managing the single grouped notification's state
String _lastNotifiedGroupedEmergencyDevicesString = ""; // Stores sorted device IDs as a string
int _lastNotifiedGroupedEmergencyCount = 0; // Stores the count of the last notified grouped emergencies
const int _GROUPED_EMERGENCY_NOTIFICATION_ID = 998; // A unique ID for the grouped notification

// Keep track of the last time the foreground "scanning" notification was updated
DateTime? _lastForegroundNotificationUpdateTime;
const int _foregroundNotificationUpdateIntervalMinutes = 5; // Update every 5 minutes

// Shared preference key for notification toggle
const String NOTIFICATIONS_ENABLED_KEY = 'notificationsEnabled';
// Shared preference key for logged in devices
const String LOGGED_IN_DEVICES_KEY = 'loggedInDevices'; // Add this new key

// GlobalKey for NavigatorState to show dialogs from non-widget contexts
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// NEW: Store previously active logged-in emergency states for "resolved" notifications
Map<String, String> _previousLoggedInEmergencyStates = {}; // deviceId -> ownerName

Future<void> requestPermissions(BuildContext context) async {
  // Request location permissions first
  await [
    Permission.location,
    Permission.locationAlways, // Request locationAlways for background service
  ].request();

  // For notifications, handle based on Android version or iOS
  if (Theme.of(context).platform == TargetPlatform.android) {
    final AndroidDeviceInfo androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 33) { // Android 13 (API 33) and above
      final status = await Permission.notification.request();
      if (status.isDenied || status.isPermanentlyDenied) {
        print("Notification permission not granted on Android 13+. Guiding user to settings.");
        _showPermissionDialog(
          'Notification Permission Required',
          'To receive emergency alerts and background service status updates, please enable notifications for Ocular Sensus in your device settings.',
            context, // Pass context to the dialog helper
        );
      }
    } else {
      // For older Android versions, permission is often granted by default
      // or implicitly requested when the first notification is shown.
      final status = await Permission.notification.request();
      if (status.isDenied || status.isPermanentlyDenied) {
        print("Notification permission not granted on older Android. Guiding user to settings.");
        _showPermissionDialog(
          'Notification Permission Required',
          'To receive emergency alerts and background service status updates, please enable notifications for Ocular Sensus in your device settings.',
          context, // Pass context to the dialog helper
        );
      }
    }
  } else if (Theme.of(context).platform == TargetPlatform.iOS) { // iOS
    final status = await Permission.notification.request();
    if (status.isDenied || status.isPermanentlyDenied) {
      print("Notification permission not granted on iOS. Guiding user to settings.");
      _showPermissionDialog(
        'Notification Permission Required',
        'To receive emergency alerts and background service status updates, please enable notifications for Ocular Sensus in your device settings.',
        context, // Pass context to the dialog helper
      );
    }
  }

  // General check for locationAlways for all platforms
  if (await Permission.locationAlways.isDenied || await Permission.locationAlways.isPermanentlyDenied) {
    print("Location Always permission not granted or permanently denied. Guiding user to settings.");
    _showPermissionDialog(
      'Location Permission Required',
      'For the app to monitor emergencies in the background, please grant "Allow all the time" location access in your device settings.',
      context, // Pass context to the dialog helper
      isLocation: true,
    );
  }
}

// Helper function to show permission dialogs
void _showPermissionDialog(String title, String content, BuildContext context, {bool isLocation = false}) {
  // Use the passed context directly
  if (context.mounted) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) { // Use dialogContext for the builder
        return AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: <Widget>[
            TextButton(
              child: const Text('Go to Settings'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                openAppSettings(); // This opens app settings
              },
            ),
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        );
      },
    );
  } else {
    // Fallback if context is not available immediately (e.g., very early app startup)
    openAppSettings();
  }
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel foregroundChannel = AndroidNotificationChannel(
    'my_foreground',
    'Ocular Sensus Background Service',
    description: 'This channel is used for the persistent background service notification.',
    importance: Importance.low, // Low importance for the persistent status notification
  );

  const AndroidNotificationChannel emergencyChannel = AndroidNotificationChannel(
    'emergency_alerts_channel',
    'Emergency Alerts',
    description: 'Notifications for nearby emergencies',
    importance: Importance.max, // High importance for actual emergencies
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(foregroundChannel);
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(emergencyChannel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: false, // Set to false, controlled by main app
      notificationChannelId: foregroundChannel.id, // Use the foreground channel
      initialNotificationTitle: 'Ocular Sensus: Initializing', // Can be updated
      initialNotificationContent: 'Starting background services...', // Can be updated
      foregroundServiceNotificationId: 888, // Persistent notification ID
    ),
    iosConfiguration: IosConfiguration(
      onForeground: onStart,
      onBackground: (_) async => true, // Allows execution in background
    ),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // This is crucial for using Flutter plugins in a background isolate
  DartPluginRegistrant.ensureInitialized();

  // Initialize Firebase always for the background isolate.
  // Each isolate needs its own Firebase context.
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize notifications for the background isolate
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  // Clear tracking sets on service start to ensure fresh state
  // These are only cleared once when the service starts, NOT every 10 seconds.
  _notifiedEmergencyDeviceIds.clear();
  _notifiedHelpComingDeviceIds.clear();
  _lastNotifiedGroupedEmergencyDevicesString = ""; // Clear on service start
  _lastNotifiedGroupedEmergencyCount = 0; // Clear on service start
  _lastForegroundNotificationUpdateTime = null; // Reset timer for foreground notification
  _previousLoggedInEmergencyStates.clear(); // Clear previous states on service start

  if (service is AndroidServiceInstance) {
    final androidService = service;

    androidService.on('stopService').listen((event) {
      androidService.stopSelf();
    });

    androidService.on('setNotificationEnabled').listen((event) {
      final bool? enabled = event?['enabled'];
      if (enabled != null) {
        SharedPreferences.getInstance().then((prefs) {
          prefs.setBool(NOTIFICATIONS_ENABLED_KEY, enabled);
          print("Background service: Notifications ${enabled ? 'enabled' : 'disabled'} via message.");
        });
        if (!enabled) {
          flutterLocalNotificationsPlugin.cancelAll();
          _notifiedEmergencyDeviceIds.clear();
          _notifiedHelpComingDeviceIds.clear();
          _lastNotifiedGroupedEmergencyDevicesString = ""; // Clear grouped state
          _lastNotifiedGroupedEmergencyCount = 0; // Clear grouped state
          _previousLoggedInEmergencyStates.clear(); // Clear resolved state
          androidService.setForegroundNotificationInfo(
            title: "Ocular Sensus: Monitoring",
            content: "Notifications are paused.",
          );
        } else {
            androidService.setForegroundNotificationInfo(
            title: "Ocular Sensus: Monitoring",
            content: "Scanning for emergencies around you...",
          );
        }
      }
    });

    androidService.setForegroundNotificationInfo(
      title: "Ocular Sensus: Monitoring",
      content: "Scanning for emergencies around you...",
    );
  }

  // Changed the refresh rate to 10 seconds as requested
  Timer.periodic(const Duration(seconds: 10), (timer) async {
    final prefs = await SharedPreferences.getInstance();
    final bool notificationsEnabled = prefs.getBool(NOTIFICATIONS_ENABLED_KEY) ?? true;
    final Set<String> loggedInDevices = (prefs.getStringList(LOGGED_IN_DEVICES_KEY) ?? []).toSet();

    final currentUser = FirebaseAuth.instance.currentUser;

    if (currentUser == null) {
      print("Background service: No user logged in, stopping service.");
      if (service is AndroidServiceInstance) {
        service.stopSelf();
      }
      timer.cancel();
      return;
    }

    if (!notificationsEnabled) {
      print("Background service: Notifications disabled, skipping emergency checks.");
      return;
    }

    print("Background service: Performing emergency scan...");
    await _performBackgroundEmergencyScan(service, loggedInDevices);
  });
}

Future<void> _performBackgroundEmergencyScan(ServiceInstance service, Set<String> loggedInDevices) async {
  try {
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 10),
    );
    final userLat = position.latitude;
    final userLng = position.longitude;

    final querySnapshot = await FirebaseFirestore.instance
        .collection('devices')
        .where('emergency', isEqualTo: true)
        .get(
          const GetOptions(source: Source.serverAndCache),
        );

    final Set<String> currentlyActiveEmergencyIds = {};
    final Set<String> currentlyHelpedEmergencyIds = {};

    final Map<String, Map<String, dynamic>> loggedInEmergencies = {};
    final Set<String> finalGroupedEmergencyDevices = {}; // This set now combines relevant non-logged-in and logged-in devices for the grouped count

    for (var doc in querySnapshot.docs) {
      final data = doc.data();
      final deviceId = doc.id;
      final deviceLat = data['latitude'];
      final deviceLng = data['longitude'];
      final isEmergency = data['emergency'] == true;
      final isHelpComing = data['isHelpComing'] == true;
      final threshold = (data['emergency_threshold'] as num?)?.toDouble() ?? 0.0;

      if (isEmergency) {
        currentlyActiveEmergencyIds.add(deviceId);
        if (isHelpComing) {
          currentlyHelpedEmergencyIds.add(deviceId);
        }

        if (loggedInDevices.contains(deviceId)) {
          // Logged-in devices always get individual notifications if in emergency
          loggedInEmergencies[deviceId] = data;

          // If this logged-in device also meets the geographic criteria AND is not being helped,
          // then add it to the count for the grouped notification.
          if (!isHelpComing && deviceLat != null && deviceLng != null) {
            final distance = Geolocator.distanceBetween(userLat, userLng, deviceLat, deviceLng);
            if (threshold == 0.0 || distance <= threshold) {
              finalGroupedEmergencyDevices.add(deviceId);
            }
          }
        } else {
          // Non-logged-in devices: apply distance threshold check
          if (deviceLat != null && deviceLng != null) {
            final distance = Geolocator.distanceBetween(userLat, userLng, deviceLat, deviceLng);
            if ((threshold == 0.0 || distance <= threshold) && !isHelpComing) {
              finalGroupedEmergencyDevices.add(deviceId);
            }
          }
        }
      }
    }

    // --- 1. Process Logged-in Devices (Individual Notifications) ---
    for (var entry in loggedInEmergencies.entries) {
      final deviceId = entry.key;
      final data = entry.value;
      final ownerName = data['ownerName'] as String? ?? 'Your device'; // Use more specific default
      final isHelpComing = data['isHelpComing'] == true;

      final int notificationId = deviceId.hashCode; // Unique ID for each device's notification

      if (isHelpComing) {
        if (!_notifiedHelpComingDeviceIds.contains(deviceId)) {
          print("DEBUG: Triggering 'Help is on the way!' notification for device $deviceId (Owner: $ownerName). ID: $notificationId");
          // Cancel any existing individual emergency notification for this device if help is coming
          if (_notifiedEmergencyDeviceIds.contains(deviceId)) {
            await flutterLocalNotificationsPlugin.cancel(notificationId);
            print("DEBUG: Canceled previous emergency notification for $deviceId.");
          }
          await flutterLocalNotificationsPlugin.show(
            notificationId,
            "✅ Help is on the way!",
            "Your device ('$ownerName') is being helped.", // Personalized content
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'emergency_alerts_channel',
                'Emergency Alerts',
                channelDescription: 'Notifications for nearby emergencies',
                importance: Importance.defaultImportance,
                priority: Priority.defaultPriority,
                ticker: 'help_coming',
                color: Colors.green,
              ),
            ),
            payload: deviceId,
          );
          _notifiedHelpComingDeviceIds.add(deviceId);
          _notifiedEmergencyDeviceIds.remove(deviceId); // Remove from emergency notified
        } else {
          print("DEBUG: Already notified 'Help is on the way!' for device $deviceId. Skipping new notification.");
        }
      } else { // Not 'help is coming', so it's an active emergency
        if (!_notifiedEmergencyDeviceIds.contains(deviceId)) {
          print("DEBUG: Triggering 'Emergency Detected!' notification for device $deviceId (Owner: $ownerName). ID: $notificationId");
          // Cancel any existing individual 'help is coming' notification if it's now an emergency
          if (_notifiedHelpComingDeviceIds.contains(deviceId)) {
            await flutterLocalNotificationsPlugin.cancel(notificationId);
            print("DEBUG: Canceled previous 'help coming' notification for $deviceId.");
          }
          await flutterLocalNotificationsPlugin.show(
            notificationId,
            "⚠️ Emergency Detected!", // Updated title for logged-in devices
            "Your logged-in device of $ownerName is in emergency!", // Personalized content
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'emergency_alerts_channel',
                'Emergency Alerts',
                channelDescription: 'Notifications for nearby emergencies',
                importance: Importance.max,
                priority: Priority.high,
                ticker: 'emergency',
                color: Colors.red,
              ),
            ),
            payload: deviceId,
          );
          _notifiedEmergencyDeviceIds.add(deviceId);
          _notifiedHelpComingDeviceIds.remove(deviceId);
        } else {
          print("DEBUG: Already notified 'Emergency Detected!' for device $deviceId. Skipping new notification.");
        }
      }
    }

    // --- 2. Process Grouped Notification (using finalGroupedEmergencyDevices) ---
    // Sort device IDs for a stable string representation for comparison
    List<String> sortedGroupedDevices = finalGroupedEmergencyDevices.toList()..sort();
    String currentGroupedDevicesString = sortedGroupedDevices.join(','); // Create a comma-separated string
    int currentGroupedCount = finalGroupedEmergencyDevices.length;

    if (currentGroupedCount > 0) {
      if (_lastNotifiedGroupedEmergencyCount != currentGroupedCount ||
          _lastNotifiedGroupedEmergencyDevicesString != currentGroupedDevicesString) {
        print("DEBUG: Grouped notification state changed. Current: $currentGroupedDevicesString ($currentGroupedCount), Previous: $_lastNotifiedGroupedEmergencyDevicesString ($_lastNotifiedGroupedEmergencyCount). ID: $_GROUPED_EMERGENCY_NOTIFICATION_ID");

        // Only cancel if there was a previous notification (count > 0) AND it was different
        if (_lastNotifiedGroupedEmergencyCount > 0) {
            await flutterLocalNotificationsPlugin.cancel(_GROUPED_EMERGENCY_NOTIFICATION_ID);
            print("DEBUG: Canceled old grouped notification for update.");
        }

        String content;
        if (currentGroupedCount == 1) {
          content = "An emergency detected near you.";
        } else {
          content = "$currentGroupedCount emergencies detected nearby.";
        }

        await flutterLocalNotificationsPlugin.show(
          _GROUPED_EMERGENCY_NOTIFICATION_ID, // Use fixed ID for the grouped notification
          "⚠️ Emergency Nearby!",
          content,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'emergency_alerts_channel',
              'Emergency Alerts',
              channelDescription: 'Notifications for nearby emergencies',
              importance: Importance.max,
              priority: Priority.high,
              ticker: 'grouped_emergency',
              color: Colors.orange, // Different color for grouped
            ),
          ),
          payload: null, // No specific deviceId payload for a grouped notification
        );
        _lastNotifiedGroupedEmergencyDevicesString = currentGroupedDevicesString;
        _lastNotifiedGroupedEmergencyCount = currentGroupedCount;
      } else {
        print("DEBUG: Grouped Emergency Notification state unchanged (content-wise). Skipping new notification.");
      }
    } else { // currentGroupedCount == 0
      // No relevant other emergencies found, if a grouped notification was active, cancel it.
      if (_lastNotifiedGroupedEmergencyCount > 0) {
        print("DEBUG: No nearby emergencies. Canceling grouped notification.");
        await flutterLocalNotificationsPlugin.cancel(_GROUPED_EMERGENCY_NOTIFICATION_ID);
        _lastNotifiedGroupedEmergencyDevicesString = "";
        _lastNotifiedGroupedEmergencyCount = 0;
      } else {
        print("DEBUG: No nearby emergencies and no grouped notification active. Skipping.");
      }
    }

    // --- 3. Cleanup: Remove device IDs from tracking sets that are no longer active ---
    // For _notifiedEmergencyDeviceIds, retain only those that are currently active emergencies AND NOT helped
    _notifiedEmergencyDeviceIds.retainWhere((id) =>
        currentlyActiveEmergencyIds.contains(id) && !currentlyHelpedEmergencyIds.contains(id));

    // For _notifiedHelpComingDeviceIds, retain only those that are currently active AND are being helped
    _notifiedHelpComingDeviceIds.retainWhere((id) =>
        currentlyActiveEmergencyIds.contains(id) && currentlyHelpedEmergencyIds.contains(id));

    print("DEBUG: _notifiedEmergencyDeviceIds after cleanup: $_notifiedEmergencyDeviceIds");
    print("DEBUG: _notifiedHelpComingDeviceIds after cleanup: $_notifiedHelpComingDeviceIds");

    // --- 4. Handle Logged-in Emergency Resolution Notifications ---
    // Find device IDs that were in _previousLoggedInEmergencyStates but are NOT in current loggedInEmergencies
    // This indicates their emergency status changed from true to false.
    Set<String> resolvedDeviceIds = _previousLoggedInEmergencyStates.keys.toSet().difference(loggedInEmergencies.keys.toSet());

    for (String deviceId in resolvedDeviceIds) {
      String ownerName = _previousLoggedInEmergencyStates[deviceId] ?? 'A logged-in device'; // Get name from previous state
      print("DEBUG: Emergency resolved for logged-in device: $deviceId (Owner: $ownerName). Sending notification.");

      // Send "Emergency Resolved" notification
      await flutterLocalNotificationsPlugin.show(
        deviceId.hashCode, // Use the same ID as its individual emergency notif
        "✅ Emergency Resolved!",
        "The emergency for '$ownerName' has been resolved.",
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'emergency_alerts_channel',
            'Emergency Alerts',
            channelDescription: 'Notifications for nearby emergencies',
            importance: Importance.low, // Lower importance for resolved
            priority: Priority.low,
            ticker: 'emergency_resolved',
            color: Colors.green,
          ),
        ),
        payload: deviceId,
      );

      // Removed the line below. The 'show' call with the same ID will update/replace the previous notification.
      // There's no need to explicitly cancel it right after showing the resolved notification.
      // await flutterLocalNotificationsPlugin.cancel(deviceId.hashCode);
    }

    // --- 5. Update _previousLoggedInEmergencyStates for the next scan ---
    _previousLoggedInEmergencyStates.clear(); // Clear previous state
    loggedInEmergencies.forEach((deviceId, data) {
      _previousLoggedInEmergencyStates[deviceId] = data['ownerName'] as String? ?? 'Your device';
    });
    print("DEBUG: _previousLoggedInEmergencyStates updated to: $_previousLoggedInEmergencyStates");

    // Update foreground service notification less frequently
    if (service is AndroidServiceInstance) {
      final androidService = service;
      final now = DateTime.now();

      if (_lastForegroundNotificationUpdateTime == null ||
          now.difference(_lastForegroundNotificationUpdateTime!).inMinutes >=
              _foregroundNotificationUpdateIntervalMinutes) {

        // Calculate total unhelped emergencies for foreground status
        Set<String> allUnhelpedEmergenciesForForegroundStatus = Set.from(finalGroupedEmergencyDevices);
        loggedInEmergencies.forEach((deviceId, data) {
          if (data['emergency'] == true && data['isHelpComing'] != true) {
            allUnhelpedEmergenciesForForegroundStatus.add(deviceId);
          }
        });
        bool hasUnhelpedEmergency = allUnhelpedEmergenciesForForegroundStatus.isNotEmpty;

        print("DEBUG: Updating foreground service notification. Has unhelped emergency: $hasUnhelpedEmergency");
        if (hasUnhelpedEmergency) {
          androidService.setForegroundNotificationInfo(
            title: "Ocular Sensus: Emergency Active!",
            content: "Monitoring for urgent help requests.",
          );
        } else {
          androidService.setForegroundNotificationInfo(
            title: "Ocular Sensus: Monitoring",
            content: "Scanning for emergencies around you...",
          );
        }
        _lastForegroundNotificationUpdateTime = now; // Update timestamp
      } else {
        print("DEBUG: Foreground notification update skipped (too soon).");
      }
    }
  } catch (e) {
    print("❌ Error during emergency scan: $e");
    if (service is AndroidServiceInstance) {
        final androidService = service;
        androidService.setForegroundNotificationInfo(
          title: "Ocular Sensus: Scan Error",
          content: "Could not perform emergency scan: ${e.toString().substring(0, min(e.toString().length, 50))}...",
        );
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  await initializeService();

  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey, // Assign the global key here
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 224, 249, 254),
        ),
        cardTheme: const CardThemeData(
          color: Color.fromARGB(180, 0, 0, 0),
          shadowColor: Colors.transparent,
        ),
      ),
      home: AuthGateWrapper(), // Use a wrapper widget to call requestPermissions
    );
  }
}

// Create a new StatefulWidget to handle permission requests
class AuthGateWrapper extends StatefulWidget {
  const AuthGateWrapper({super.key});

  @override
  State<AuthGateWrapper> createState() => _AuthGateWrapperState();
}

class _AuthGateWrapperState extends State<AuthGateWrapper> {
  @override
  void initState() {
    super.initState();
    // Call requestPermissions here, where context is available
    _initPermissions();
  }

  Future<void> _initPermissions() async {
    // Ensure the widget is still mounted before using context
    if (mounted) {
      await requestPermissions(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthGate(); // Your existing AuthGate
  }
}