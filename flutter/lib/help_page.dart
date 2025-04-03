import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:animate_do/animate_do.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
class HelpPage extends StatefulWidget {
  const HelpPage({super.key});

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  List<Map<String, dynamic>> emergencyDevices = [];
  LatLng thiruporurLocation = const LatLng(12.75, 80.20);
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin(); // Initialize plugin

  @override
  void initState() {
    super.initState();
    _initializeNotifications();
    _requestNotificationPermission();
    _fetchEmergencyDevices();
  }

  Future<void> _initializeNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings(
            '@mipmap/ic_launcher'); // Ensure the icon exists

    final InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        print("Notification clicked: ${response.payload}");
      },
    );
  }

  Future<void> _showNotification(Map<String, dynamic> device) async {
    print("Attempting to show notification for ${device['ownerName']}");

    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'emergency_channel',
      'Emergency Notifications',
      channelDescription: 'Notifications for emergency situations',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
    );

    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      0,
      'Emergency Alert!',
      '${device['ownerName'] ?? "Someone"} is in an emergency!',
      platformChannelSpecifics,
      payload: 'emergency_payload',
    );
  }

  Future<void> _requestNotificationPermission() async {
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  }

  Future<void> _fetchEmergencyDevices() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('devices')
          .where('emergency', isEqualTo: true)
          .where('ishelpcoming', isEqualTo: false)
          .get();

      if (snapshot.docs.isNotEmpty) {
        List<Map<String, dynamic>> devices = [];
        for (var doc in snapshot.docs) {
          for (var doc in snapshot.docs) {
            Map<String, dynamic> data = doc.data();
            data['deviceId'] = doc.id;
            devices.add(data);
          }
        }
        emergencyDevices = devices;
        if (mounted) {
          setState(() {});
          for (var device in emergencyDevices) {
            _showNotification(device); // Show notification for each device
          }
        }
      }
    } catch (e) {
      print("Error fetching emergency devices: $e");
    }
  }

  void _showEmergencyPopup(Map<String, dynamic> device) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color.fromARGB(255, 255, 255, 255),
          title: const Text('Emergency Details:-'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${device['ownerName']} is in an emergency!'),
              SizedBox(height: 15),
              SizedBox(
                height: 170,
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: LatLng(device['latitude'], device['longitude']),
                    zoom: 15.0,
                  ),
                  markers: {
                    Marker(
                      markerId: MarkerId(device['ownerName']),
                      position: LatLng(device['latitude'], device['longitude']),
                    ),
                  },
                ),
              ),
              SizedBox(height: 10),
              const Text('Are you available to help?'),
            ],
          ),
          actions: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  child: const Text('Yes'),
                  onPressed: () async {
                    try {
                      if (device.containsKey('deviceId') &&
                          device['deviceId'] != null) {
                        await FirebaseFirestore.instance
                            .collection('devices')
                            .doc(device['deviceId'])
                            .update({'ishelpcoming': true});

                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool('isHelping', true);

                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                HelpingMapPage(device: device),
                          ),
                        );
                      } else {
                        print('Error: deviceId is missing or null');
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('Error: deviceId is missing!')),
                        );
                      }
                    } catch (e) {
                      print('Firestore update error: $e');
                    }
                  },
                ),
                SizedBox(width: 15),
                TextButton(
                  child: const Text('No'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (emergencyDevices.isNotEmpty) {
      return ListView.builder(
        itemCount: emergencyDevices.length,
        itemBuilder: (context, index) {
          final device = emergencyDevices[index];
          return FadeInUp(
            delay: Duration(milliseconds: 100 * index),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              decoration: BoxDecoration(
                color: const Color.fromARGB(95, 169, 169, 169).withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    spreadRadius: 1,
                    blurRadius: 5,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: ListTile(
                title: Text('${device['ownerName']}:',
                    style: TextStyle(
                        color: const Color.fromARGB(255, 255, 255, 255))),
                subtitle: Text('Emergency!',
                    style:
                        TextStyle(color: Color.fromARGB(255, 255, 255, 255))),
                onTap: () {
                  _showEmergencyPopup(device);
                },
              ),
            ),
          );
        },
      );
    } else {
      return const Center(
        child: Text('No emergency devices found.'),
      );
    }
  }
}


class HelpingMapPage extends StatefulWidget {
  final Map<String, dynamic>? device;

  const HelpingMapPage({super.key, required this.device});

  @override
  State<HelpingMapPage> createState() => _HelpingMapPageState();
}

class _HelpingMapPageState extends State<HelpingMapPage> {
  late LatLng helpingLocation;
  bool isHelping = true;
  late GoogleMapController mapController;
  LatLng? currentLocation;

  @override
  void initState() {
    super.initState();
    _initializeHelpingState();
    helpingLocation = LatLng(
      widget.device?['latitude'] ?? 12.75,
      widget.device?['longitude'] ?? 80.20,
    );
    _getCurrentLocation();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _saveHelpingState(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isHelping', value);
  }

  Future<void> _initializeHelpingState() async {
    final prefs = await SharedPreferences.getInstance();
    bool savedHelpingState = prefs.getBool('isHelping') ?? true;

    setState(() {
      isHelping = savedHelpingState;
    });
  }

  Future<bool> _onWillPop() async {
    return await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Confirm Exit'),
            content: const Text(
                'If you exit this page or close the app, it will be considered as you won\'t be able to help.'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('No'),
              ),
              TextButton(
                onPressed: () async {
                  if (widget.device != null &&
                      widget.device!['deviceId'] != null) {
                    try {
                      await FirebaseFirestore.instance
                          .collection('devices')
                          .doc(widget.device!['deviceId'])
                          .update({'ishelpcoming': false});
                    } catch (e) {
                      print('Firestore update error: $e');
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to update Firestore: $e')),
                      );
                    }
                  }
                  Navigator.of(context).pop(true);
                },
                child: const Text('Yes'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _getCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      setState(() {
        currentLocation = LatLng(position.latitude, position.longitude);
      });
    } catch (e) {
      print('Error getting location: $e');
    }
  }

  Future<void> _launchGoogleMapsDirections() async {
  if (currentLocation != null) {
    final String origin =
        '${currentLocation!.latitude},${currentLocation!.longitude}';
    final String destination =
        '${helpingLocation.latitude},${helpingLocation.longitude}';
    final String googleMapsUrl =
        'https://www.google.com/maps/dir/?api=1&origin=$origin&destination=$destination&travelmode=driving';

    if (await canLaunchUrl(Uri.parse(googleMapsUrl))) {
      await launchUrl(Uri.parse(googleMapsUrl));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not launch Google Maps.')),
      );
    }
  }
}

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        return _onWillPop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Helping Map'),
        ),
        body: Column(
          children: [
            Expanded(
              child: GoogleMap(
                onMapCreated: (GoogleMapController controller) {
                  mapController = controller;
                },
                initialCameraPosition: CameraPosition(
                  target: helpingLocation,
                  zoom: 15.0,
                ),
                markers: {
                  Marker(
                    markerId: MarkerId(
                        widget.device?['ownerName'] ?? 'Emergency Location'),
                    position: LatLng(widget.device?['latitude'] ?? 12.75,
                        widget.device?['longitude'] ?? 80.20),
                  ),
                },
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Helping: '),
                      Switch(
                        value: isHelping,
                        onChanged: (value) async {
                          setState(() {
                            isHelping = value;
                          });
                          await _saveHelpingState(value);

                          if (widget.device != null &&
                              widget.device!['deviceId'] != null) {
                            try {
                              print(
                                  'Updating ishelpcoming to $value for deviceId: ${widget.device!['deviceId']}');
                              await FirebaseFirestore.instance
                                  .collection('devices')
                                  .doc(widget.device!['deviceId'])
                                  .update({'ishelpcoming': value});
                              print('Firestore update successful.');
                            } catch (e) {
                              print('Firestore update error: $e');
                            }
                          }

                          if (!value) {
                            Navigator.pop(context);
                          }
                        },
                      ),
                    ],
                  ),
                  ElevatedButton(
                    onPressed: _launchGoogleMapsDirections,
                    child: const Text('Get Directions'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}