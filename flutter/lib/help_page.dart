import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:animate_do/animate_do.dart';


typedef OnSwitchTab = void Function(int index, {String? deviceIdToFocus, double? initialLatitude, double? initialLongitude});

class HelpPage extends StatefulWidget {
  final OnSwitchTab onSwitchTab; // Add this parameter

  const HelpPage({super.key, required this.onSwitchTab}); // Update constructor

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  final List<Map<String, dynamic>> _emergencyDevices = [];
  String? _activePopupDeviceId; // This might become redundant if no popups
  final bool _isDialogShowing = false; // This will become redundant if no popups

  Completer<void>? _permissionRequestCompleter;

  String? _locationIssueMessage;
  bool _isLocationStreamInitialized = false;
  bool _isFirestoreStreamInitialized = false;
  bool _isLoadingData = true;

  StreamSubscription<QuerySnapshot>? _firestoreSubscription;
  StreamSubscription<Position>? _positionStreamSubscription;
  Position? _currentPosition;
  List<DocumentSnapshot> _latestFirestoreDocs = [];

  @override
  void initState() {
    super.initState();
    _initializeAppStreams();
  }

  @override
  void dispose() {
    _firestoreSubscription?.cancel();
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeAppStreams() async {
    if (!mounted) return;

    setState(() {
      _isLoadingData = true;
      _isLocationStreamInitialized = false;
      _isFirestoreStreamInitialized = false;
      _emergencyDevices.clear();
      _currentPosition = null;
      _latestFirestoreDocs = [];
      _locationIssueMessage = null;
    });

    if (_permissionRequestCompleter != null &&
        !_permissionRequestCompleter!.isCompleted) {
      print(
          'DEBUG (HelpPage): Location permission request already in progress, waiting for it to complete.');
      await _permissionRequestCompleter!.future;
      if (!mounted) return;
    }

    _permissionRequestCompleter = Completer<void>();
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        print('DEBUG: Location permission currently denied. Requesting again.');
        permission = await Geolocator.requestPermission();
      }

      if (!mounted) return;

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        String message =
            'Location permissions are required to find nearby emergencies. Please enable them in settings.';
        _showError(message);
        if (mounted) {
          setState(() {
            _isLocationStreamInitialized = true;
            _isLoadingData = false;
            _locationIssueMessage = message;
          });
        }
        if (permission == LocationPermission.deniedForever) {
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _showPermissionDeniedDialog(
                'Location access is permanently denied. Please enable it from app settings to use this feature.',
                'Location Permission Denied',
              );
            });
          }
        }
        return;
      }

      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!mounted) return;

      if (!serviceEnabled) {
        String message =
            'Location services are disabled. Please enable them from your device settings.';
        _showError(message);
        if (mounted) {
          setState(() {
            _isLocationStreamInitialized = true;
            _isLoadingData = false;
            _locationIssueMessage = message;
          });
        }
        return;
      }

      try {
        _currentPosition = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 5),
        );
        print('DEBUG: Initial current position obtained: $_currentPosition');
        _locationIssueMessage = null;
      } catch (e) {
        print(
            'ERROR: Failed to get initial current position after permissions/services check: $e');
        _currentPosition = null;
        _locationIssueMessage =
            'Could not get your precise location. Please check GPS signal or device settings and try refreshing.';
        _showError(_locationIssueMessage!);
      } finally {
        if (mounted) {
          setState(() {
            _isLocationStreamInitialized = true;
            _isLoadingData = false;
          });
        }
      }

      _startLocationStream();
      _startFirestoreStream();
    } finally {
      if (_permissionRequestCompleter != null &&
          !_permissionRequestCompleter!.isCompleted) {
        _permissionRequestCompleter!.complete();
      }
    }
  }

  void _startLocationStream() {
    _positionStreamSubscription?.cancel();

    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen(
      (Position position) {
        if (!mounted) return;
        _currentPosition = position;

        if (_locationIssueMessage != null) {
          setState(() {
            _locationIssueMessage = null;
            print(
                'DEBUG: Location stream now successfully providing data, clearing issue message.');
          });
        }

        if (!_isLocationStreamInitialized || _isLoadingData) {
          setState(() {
            _isLocationStreamInitialized = true;
            _isLoadingData = false;
          });
        }
        _updateNearbyDevices();
      },
      onError: (e) {
        print('Error in location stream: $e');
        String message =
            'Real-time location updates failed: ${e.toString()}. Please check settings.';
        _showError(message);
        if (mounted) {
          setState(() {
            _locationIssueMessage = message;
            _currentPosition = null;
            _isLoadingData = false;
          });
        }
      },
      onDone: () => print("Location stream done."),
      cancelOnError: true,
    );
  }

  void _startFirestoreStream() {
    _firestoreSubscription?.cancel();

    _firestoreSubscription = FirebaseFirestore.instance
        .collection('devices')
        .where('emergency', isEqualTo: true)
        .snapshots()
        .listen((snapshot) async {
      if (!mounted) return;
      _latestFirestoreDocs = snapshot.docs;
      if (!_isFirestoreStreamInitialized) {
        setState(() {
          _isFirestoreStreamInitialized = true;
          print('DEBUG: Firestore stream initialized and provided data.');
        });
      }
      _updateNearbyDevices();
    }, onError: (e) {
      print('Error in Firestore stream: $e');
      _showError('Failed to get real-time emergency updates: ${e.toString()}');
      if (mounted) {
        setState(() {
          _isFirestoreStreamInitialized = true;
          _isLoadingData = false;
        });
      }
    });
  }

  void _updateNearbyDevices() async {
    if (!mounted) return;

    print('DEBUG: _updateNearbyDevices called.');
    print(
        'DEBUG: _isLocationStreamInitialized: $_isLocationStreamInitialized');
    print(
        'DEBUG: _isFirestoreStreamInitialized: $_isFirestoreStreamInitialized');
    print('DEBUG: _currentPosition: $_currentPosition');

    if (_isLocationStreamInitialized &&
        _isFirestoreStreamInitialized &&
        _isLoadingData) {
      setState(() {
        _isLoadingData = false;
        print('DEBUG: _isLoadingData set to false. UI should now show content.');
      });
    }

    if (_currentPosition == null) {
      print(
          'DEBUG: _currentPosition is null. Cannot calculate distances. Displaying location issue message.');
      if (mounted) {
        setState(() {
          _emergencyDevices.clear();
        });
      }
      return;
    }

    final List<Map<String, dynamic>> tempNearbyDevices = [];
    final Set<String> currentEmergencyDeviceIds = {};

    print(
        'DEBUG: Processing ${_latestFirestoreDocs.length} Firestore documents for proximity calculation.');

    for (var doc in _latestFirestoreDocs) {
      final data = doc.data() as Map<String, dynamic>;
      final deviceId = doc.id;
      data['deviceId'] = deviceId;
      currentEmergencyDeviceIds.add(deviceId);

      final lat = data['latitude'];
      final lng = data['longitude'];
      final threshold = (data['emergency_threshold'] as num?)?.toDouble() ?? 0.0;

      print(
          'DEBUG: Device ID: $deviceId, Emergency: ${data['emergency']}, Lat: $lat, Lng: $lng, Threshold: $threshold');

      if (lat != null &&
          lng != null &&
          (data['emergency'] == true) ) {
        final distance = Geolocator.distanceBetween(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          lat,
          lng,
        );
        print('DEBUG: Distance to $deviceId: ${distance.toStringAsFixed(2)} meters');
        data['distance'] = distance;

        if (threshold == 0.0 || distance <= threshold) {
          tempNearbyDevices.add(data);
          print(
              'DEBUG: Device $deviceId is nearby (${distance.toStringAsFixed(2)}m within ${threshold.toStringAsFixed(2)}m)');
        } else {
          print(
              'DEBUG: Device $deviceId is NOT nearby (${distance.toStringAsFixed(2)}m > ${threshold.toStringAsFixed(2)}m)');
        }
      } else {
        print(
            'DEBUG: Device $deviceId failed conditions: lat/lng invalid, or emergency/isHelpComing mismatch (Emergency: ${data['emergency']}.');
      }
    }

    bool devicesChanged = false;
    if (_emergencyDevices.length != tempNearbyDevices.length) {
      devicesChanged = true;
      print('DEBUG: _emergencyDevices length changed. Triggering setState.');
    } else {
      for (int i = 0; i < tempNearbyDevices.length; i++) {
        if (_emergencyDevices[i]['deviceId'] != tempNearbyDevices[i]['deviceId']) {
          devicesChanged = true;
          print(
              'DEBUG: _emergencyDevices content changed (device ID mismatch at index $i). Triggering setState.');
          break;
        }
      }
    }

    if (mounted && devicesChanged) {
      setState(() {
        _emergencyDevices
          ..clear()
          ..addAll(tempNearbyDevices);
        print('DEBUG: _emergencyDevices updated via setState. New count: ${_emergencyDevices.length}');
      });
    } else {
      print('DEBUG: _emergencyDevices not changed, no setState called.');
    }

    // Removed the activePopupDeviceId and _isDialogShowing logic as the popup is gone.
    // The conditional check for currentEmergencyDeviceIds.contains(_activePopupDeviceId) is no longer needed here.
  }

  // This method is no longer used, but kept for context.
  // void _showEmergencyDialog(Map<String, dynamic> device) {
  //   // ... (existing dialog logic, but this method will not be called)
  // }

  void _showMessage(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red));
    }
  }

  String _formatDistance(double distanceInMeters) {
  if (distanceInMeters < 1000) {
    return '${distanceInMeters.toStringAsFixed(0)} m';
  } else {
    return '${(distanceInMeters / 1000).toStringAsFixed(1)} km';
  }
}

  void _showPermissionDeniedDialog(String message, String title) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingData) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _initializeAppStreams,
      child: _emergencyDevices.isEmpty
          ? ListView(
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Text(
                      _locationIssueMessage ??
                          (_currentPosition == null
                              ? 'Waiting for your location to find nearby emergencies.\n(Please ensure location services are enabled and GPS signal is good.)'
                              : 'No emergency devices found nearby that require help.'),
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
                    ),
                  ),
                )
              ],
            )
          : ListView.builder(
              itemCount: _emergencyDevices.length,
              itemBuilder: (context, index) {
                final device = _emergencyDevices[index];
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
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      leading: GestureDetector(
                        onTap: () {
                          final imageUrl = device['profilePic'] as String?;
                          if (imageUrl != null && imageUrl.isNotEmpty) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => Scaffold(
                                  backgroundColor: Colors.black,
                                  appBar: AppBar(
                                    backgroundColor: Colors.black,
                                    iconTheme: const IconThemeData(color: Colors.white),
                                    elevation: 0,
                                  ),
                                  body: Center(
                                    child: Image.network(
                                      imageUrl,
                                      fit: BoxFit.contain,
                                      loadingBuilder: (BuildContext context, Widget child,
                                          ImageChunkEvent? loadingProgress) {
                                        if (loadingProgress == null) return child;
                                        return Center(
                                          child: CircularProgressIndicator(
                                            value: loadingProgress.expectedTotalBytes != null
                                                ? loadingProgress.cumulativeBytesLoaded /
                                                    loadingProgress.expectedTotalBytes!
                                                : null,
                                            color: Colors.white,
                                          ),
                                        );
                                      },
                                      errorBuilder: (context, error, stackTrace) {
                                        print('Error loading full-screen image: $error');
                                        return const Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.broken_image, color: Colors.grey, size: 50),
                                            SizedBox(height: 8),
                                            Text('Image failed to load',
                                                style: TextStyle(color: Colors.grey)),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white,
                              width: 1.0,
                            ),
                          ),
                          child: CircleAvatar(
                            radius: 24,
                            backgroundColor: Colors.white.withOpacity(0.2),
                            backgroundImage: (device['profilePic'] is String &&
                                    (device['profilePic'] as String).isNotEmpty)
                                ? NetworkImage(device['profilePic'] as String)
                                    as ImageProvider<Object>?
                                : null,
                            child: !(device['profilePic'] is String &&
                                    (device['profilePic'] as String).isNotEmpty)
                                ? const Icon(
                                    Icons.person,
                                    size: 30,
                                    color: Colors.white70,
                                  )
                                : null,
                          ),
                        ),
                      ),
                      title: Text(
                        '${device['ownerName']}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 18, fontWeight: FontWeight.w400),
                      ),
                      subtitle: Builder(
  builder: (BuildContext context) {
    final distance = device['distance'] as double?;
    String distanceText = '';
    if (distance != null) {
      distanceText = ' - ${_formatDistance(distance)}';
    }
    return RichText( // CHANGE THIS LINE from Text to RichText
      text: TextSpan(
        children: [
          TextSpan(
            text: 'Emergency',
            style: TextStyle(color: Colors.redAccent, fontSize: 13), // "Emergency" in red
          ),
          TextSpan(
            text: distanceText,
            style: TextStyle(color: Colors.white, fontSize: 13), // Distance in white
          ),
        ],
      ),
    );
  },
),
                      onTap: () async {
                        print('DEBUG: ListTile tapped for device: ${device['deviceId']}');

                        final doc = await FirebaseFirestore.instance
                            .collection('devices')
                            .doc(device['deviceId'])
                            .get();
                        final currentEmergency = doc.data()?['emergency'] ?? false;

                        print(
                            'DEBUG: Tapped device ${device['deviceId']} - Current Emergency: $currentEmergency');

                        if (!currentEmergency) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("This emergency has already ended.")),
                            );
                            setState(() {
                              _emergencyDevices
                                  .removeWhere((d) => d['deviceId'] == device['deviceId']);
                              print('DEBUG: Removing ${device['deviceId']} from _emergencyDevices.');
                            });
                          }
                          return;
                        } 

                        // *** MODIFIED LOGIC HERE ***
                        // Store the device ID and switch to the Radar tab
                        SharedPreferences prefs = await SharedPreferences.getInstance();
                        await prefs.setString('focusedDeviceId', device['deviceId']);
                        print('DEBUG: Stored deviceId ${device['deviceId']} in SharedPreferences.');

                        // Call the callback to switch tabs (e.g., to index 1 for Radar)
                        widget.onSwitchTab(
  1, // Index for RadarPage (assuming it's tab 1)
  deviceIdToFocus: device['deviceId'],
  initialLatitude: device['latitude'] as double?, // Add this line
  initialLongitude: device['longitude'] as double?, // Add this line
);
                        // *** END MODIFIED LOGIC ***
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }
}
