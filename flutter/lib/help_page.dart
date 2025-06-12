import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:animate_do/animate_do.dart'; 
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'temp_profile_page.dart';

class HelpPage extends StatefulWidget {
  const HelpPage({super.key});

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final Set<String> _notifiedDeviceIds = {};
  final List<Map<String, dynamic>> _emergencyDevices = [];
  String? _activePopupDeviceId;
  bool _isDialogShowing = false;

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
    _initNotification();
    _initializeAppStreams();
  }

  @override
  void dispose() {
    _firestoreSubscription?.cancel();
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  
  Future<void> _initNotification() async {
    await _requestNotificationPermission();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _notificationsPlugin.initialize(initSettings);
  }

  
  Future<void> _requestNotificationPermission() async {
    if (await Permission.notification.isDenied) {
      final status = await Permission.notification.request();
      if (status.isPermanentlyDenied) {
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showPermissionDeniedDialog(
              'Notification access is permanently denied. Please enable it from app settings to receive emergency alerts.',
              'Notification Permission Denied',
            );
          });
        }
      }
    }
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
      _notifiedDeviceIds.clear();
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
        .where('isHelpComing', isEqualTo: false)
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

    
    if (_isLocationStreamInitialized && _isFirestoreStreamInitialized && _isLoadingData) {
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

    final prefs = await SharedPreferences.getInstance();
    final notificationsEnabled = prefs.getBool('notificationsEnabled') ?? true;
    final List<Map<String, dynamic>> tempNearbyDevices = [];
    final Set<String> currentEmergencyDeviceIds = {};

    print('DEBUG: Processing ${this._latestFirestoreDocs.length} Firestore documents for proximity calculation.');

    for (var doc in this._latestFirestoreDocs) {
      final data = doc.data() as Map<String, dynamic>;
      final deviceId = doc.id;
      data['deviceId'] = deviceId;
      currentEmergencyDeviceIds.add(deviceId);

      final lat = data['latitude'];
      final lng = data['longitude'];
      final threshold = (data['emergency_threshold'] as num?)?.toDouble() ?? 0.0;

      print('DEBUG: Device ID: $deviceId, Emergency: ${data['emergency']}, isHelpComing: ${data['isHelpComing']}, Lat: $lat, Lng: $lng, Threshold: $threshold');

      
      if (lat != null &&
          lng != null &&
          threshold > 0 &&
          (data['emergency'] == true) &&
          (data['isHelpComing'] == false)) {
        final distance = Geolocator.distanceBetween(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          lat,
          lng,
        );
        print('DEBUG: Distance to $deviceId: ${distance.toStringAsFixed(2)} meters');

        if (distance <= threshold) {
          tempNearbyDevices.add(data);
          print('DEBUG: Device $deviceId is nearby (${distance.toStringAsFixed(2)}m within ${threshold.toStringAsFixed(2)}m)');
          if (notificationsEnabled && !_notifiedDeviceIds.contains(deviceId)) {
            await _showEmergencyNotification(data);
            _notifiedDeviceIds.add(deviceId);
            print('DEBUG: Notification shown for $deviceId');
          }
        } else {
          print('DEBUG: Device $deviceId is NOT nearby (${distance.toStringAsFixed(2)}m > ${threshold.toStringAsFixed(2)}m)');
        }
      } else {
        print('DEBUG: Device $deviceId failed conditions: lat/lng/threshold invalid, or emergency/isHelpComing mismatch (Emergency: ${data['emergency']}, HelpComing: ${data['isHelpComing']}).');
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
          print('DEBUG: _emergencyDevices content changed (device ID mismatch at index $i). Triggering setState.');
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

    
    if (_activePopupDeviceId != null && _isDialogShowing) {
      if (!currentEmergencyDeviceIds.contains(_activePopupDeviceId)) {
        Navigator.of(context, rootNavigator: true).pop();
        _isDialogShowing = false;
        _activePopupDeviceId = null;
        _showMessage("The emergency you were viewing has ended or is being handled.");
        print('DEBUG: Dialog for $_activePopupDeviceId dismissed because emergency ended/handled.');
      }
    }
  }

  
  Future<void> _showEmergencyNotification(Map<String, dynamic> device) async {
    const androidDetails = AndroidNotificationDetails(
      'emergency_channel',
      'Emergency Notifications',
      channelDescription: 'Emergency alert notifications',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await _notificationsPlugin.show(
      device['deviceId'].hashCode,
      'Emergency Alert!',
      '${device['ownerName'] ?? "Someone"} needs help!',
      details,
      payload: 'emergency',
    );
  }

  
  void _showEmergencyDialog(Map<String, dynamic> device) {
    if (_isDialogShowing) {
      print('DEBUG: Dialog already showing for $_activePopupDeviceId. Skipping new dialog for ${device['deviceId']}.');
      return;
    }
    _activePopupDeviceId = device['deviceId'];
    _isDialogShowing = true;
    print('DEBUG: Attempting to show dialog for device: ${device['deviceId']}');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Emergency Details:'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${device['ownerName']} is in an emergency!'),
            const SizedBox(height: 15),
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
                zoomControlsEnabled: false,
                scrollGesturesEnabled: false,
                zoomGesturesEnabled: false,
              ),
            ),
            const SizedBox(height: 10),
            const Text('Are you available to help?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (mounted) {
                Navigator.of(context, rootNavigator: true).pop();
                _isDialogShowing = false;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => HelpingMapPage(device: device),
                  ),
                );
              }
            },
            child: const Text('Yes'),
          ),
          const SizedBox(width: 15),
          TextButton(
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              _isDialogShowing = false;
            },
            child: const Text('No'),
          ),
        ],
      ),
    ).then((_) {
      _isDialogShowing = false;
      _activePopupDeviceId = null;
      print('DEBUG: Dialog for ${device['deviceId']} dismissed (via .then() callback).');
    });
  }

  
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
  contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
  leading: GestureDetector( // <-- GestureDetector for full-screen image on tap
    onTap: () {
      final imageUrl = device['profilePic'] as String?;
      if (imageUrl != null && imageUrl.isNotEmpty) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => Scaffold(
              backgroundColor: Colors.black, // Dark background for the full-screen image
              appBar: AppBar(
                backgroundColor: Colors.black,
                iconTheme: const IconThemeData(color: Colors.white), // White back arrow
                elevation: 0, // No shadow for app bar
              ),
              body: Center(
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.contain, // Fit the image within the screen without cropping
                  loadingBuilder: (BuildContext context, Widget child, ImageChunkEvent? loadingProgress) {
                    if (loadingProgress == null) return child;
                    return Center(
                      child: CircularProgressIndicator(
                        value: loadingProgress.expectedTotalBytes != null
                            ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                            : null,
                        color: Colors.white, // White progress indicator
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
                        Text('Image failed to load', style: TextStyle(color: Colors.grey)),
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
    child: Container( // <-- Container for the white border
      decoration: BoxDecoration(
        shape: BoxShape.circle, // Ensures the border is circular
        border: Border.all(
          color: Colors.white, // White border color
          width: 1.0, // Border thickness
        ),
      ),
      child: CircleAvatar(
        radius: 24, // Adjust radius as needed for the desired size of the profile picture
        backgroundColor: Colors.white.withOpacity(0.2), // A subtle background for the avatar
        backgroundImage: (device['profilePic'] is String && (device['profilePic'] as String).isNotEmpty)
            ? NetworkImage(device['profilePic'] as String) as ImageProvider<Object>?
            : null, // Use NetworkImage if URL exists
        child: !(device['profilePic'] is String && (device['profilePic'] as String).isNotEmpty)
            ? const Icon(
                Icons.person,
                size: 30, // Icon size if no image is available
                color: Colors.white70,
              )
            : null, // Show default person icon if no image
      ),
    ),
  ),
  title: Text(
    '${device['ownerName']}',
    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w400),
  ),
  subtitle: const Text(
    'Emergency!',
    style: TextStyle(color: Colors.redAccent, fontSize: 14),
  ),
  onTap: () async {
    print('DEBUG: ListTile tapped for device: ${device['deviceId']}');

    final doc = await FirebaseFirestore.instance
        .collection('devices')
        .doc(device['deviceId'])
        .get();
    final currentEmergency = doc.data()?['emergency'] ?? false;
    final currentIsHelpComing = doc.data()?['isHelpComing'] ?? false;

    print(
        'DEBUG: Tapped device ${device['deviceId']} - Current Emergency: $currentEmergency, isHelpComing: $currentIsHelpComing');

    if (!currentEmergency) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("This emergency has already ended.")),
        );
        setState(() {
          // Assuming _emergencyDevices is accessible here
          _emergencyDevices.removeWhere((d) => d['deviceId'] == device['deviceId']);
          print('DEBUG: Removing ${device['deviceId']} from _emergencyDevices.');
        });
      }
      return;
    } else if (currentIsHelpComing) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Help is already on its way for this emergency.")),
        );
        setState(() {
          // Assuming _emergencyDevices is accessible here
          _emergencyDevices.removeWhere((d) => d['deviceId'] == device['deviceId']);
          print('DEBUG: Removing ${device['deviceId']} from _emergencyDevices.');
        });
      }
      return;
    }
    // Assuming _showEmergencyDialog is defined elsewhere
    _showEmergencyDialog(device);
  },
)
                  ),
                );
              },
            ),
    );
  }
}



class HelpingMapPage extends StatefulWidget {
  final Map<String, dynamic>? device;

  const HelpingMapPage({super.key, required this.device});

  @override
  State<HelpingMapPage> createState() => _HelpingMapPageState();
}

class _HelpingMapPageState extends State<HelpingMapPage> with SingleTickerProviderStateMixin{
  static const double _resolveButtonThresholdMeters = 10.0;

  bool _isLoading = true;
  LatLng? currentLocation;
  LatLng? _yourLocation;
  final Set<Marker> _markers = {};
  LatLng helpingLocation = LatLng(0.0, 0.0);
  bool _hasValidHelpingLocation = false;
  bool _isEmergencyResolved = false;
  bool isHelping = false;
  late GoogleMapController mapController;
  late AnimationController _resolveButtonAnimationController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  bool _wasResolveButtonVisible = false;

  StreamSubscription<DocumentSnapshot>? _emergencyStatusListener;
  StreamSubscription<Position>? _positionStreamSubscription;
  Timer? _distanceCalculationTimer;

  bool _isExitingPage = false;
  bool _showResolveButton = false;
  BitmapDescriptor? _yourLocationMarkerIcon;
  BitmapDescriptor? _emergencyMarkerIcon;

  @override
  void initState() {
    super.initState();
    _checkDeviceDataAndInitialize();
    _createCustomMarkerIcons();
    _fetchUserLocation();
  _resolveButtonAnimationController = AnimationController(
    vsync: this, // 'this' refers to the SingleTickerProviderStateMixin
    duration: const Duration(milliseconds: 500), // Duration of the animation
  );

  _slideAnimation = Tween<Offset>(
    begin: const Offset(-1.0, 0.0), // Starts off-screen to the left
    end: Offset.zero, // Ends at its normal position
  ).animate(CurvedAnimation(
    parent: _resolveButtonAnimationController,
    curve: Curves.easeOutCubic, // Smooth acceleration/deceleration
  ));

  _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
    CurvedAnimation(
      parent: _resolveButtonAnimationController,
      curve: Curves.easeIn, // Smooth fade-in
    ),
  );

  // --- NEW: Initial check for animation state after first frame ---
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _updateResolveButtonAnimation();
  });
}

  void _updateResolveButtonAnimation() {
  // Assuming 'isHelping' and '_showResolveButton' are state variables
  final bool isCurrentlyVisible = isHelping && _showResolveButton;

  if (isCurrentlyVisible && !_wasResolveButtonVisible) {
    _resolveButtonAnimationController.forward(); // Animate in
  } else if (!isCurrentlyVisible && _wasResolveButtonVisible) {
    _resolveButtonAnimationController.reverse(); // Animate out
  }
  _wasResolveButtonVisible = isCurrentlyVisible; // Update tracker
}

  void _checkDeviceDataAndInitialize() {
    if (widget.device == null ||
        widget.device!['latitude'] == null ||
        widget.device!['longitude'] == null ||
        widget.device!['deviceId'] == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showError('Invalid emergency data. Please try again.');
        _navigateToHomepageAndClearStack();
      });
      return;
    }

    helpingLocation = LatLng(
      widget.device!['latitude'],
      widget.device!['longitude'],
    );

    _initializeHelpingMapPage();
  }
  

  @override
  void dispose() {
    _resolveButtonAnimationController.dispose();
    _isExitingPage = true;
    _emergencyStatusListener?.cancel();
    _positionStreamSubscription?.cancel();
    _distanceCalculationTimer?.cancel();
    if (isHelping) {
      _updateHelperStatus("", false, shouldPop: false);
    }
    super.dispose();
  }

  @override
void didUpdateWidget(covariant HelpingMapPage oldWidget) {
  super.didUpdateWidget(oldWidget);
  // --- NEW: Trigger animation when relevant state changes ---
  _updateResolveButtonAnimation();
}


  


  Future<void> _fetchUserLocation() async {
  // Your logic to get the current location, for example using the 'geolocator' package
  // This is just an example, use your actual location implementation
  try {
    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    LatLng userLocation = LatLng(position.latitude, position.longitude);

    // 3. Once location is available, call the function to update the map
    _updateUserLocationMarker(userLocation);

  } catch (e) {
    print("Failed to get user location: $e");
    // Handle location errors (e.g., permissions denied)
  }
}

  Future<void> _initializeHelpingMapPage() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
    });

    await _createCustomMarkerIcons();
    await _getCurrentLocation();

    if (currentLocation == null) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }

    _listenForEmergencyStatusChange();
    _startPeriodicDistanceCalculation();

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<BitmapDescriptor> _getCustomMarkerBitmap({
  required String label,
  required Color color, // Fallback color if no image is available
  String? imageUrl,
  double fontSize = 30,
  double imageSize = 100.0, // Diameter of the profile picture area
  double padding = 10.0, // Padding around the entire marker content
  double borderWidth = 4.0, // Thickness of the white border
  Color borderColor = Colors.white, // Color of the border
}) async {
  final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(pictureRecorder);

  final TextPainter textPainter = TextPainter(
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
    text: TextSpan(
      text: label,
      style: TextStyle(
        color: Colors.black, // Text color
        fontSize: fontSize,
        fontWeight: FontWeight.bold,
        shadows: [
          Shadow(
            color: Colors.white.withOpacity(0.7),
            blurRadius: 3.0,
            offset: const Offset(1.0, 1.0),
          ),
        ],
      ),
    ),
  );
  textPainter.layout();

  // Calculate effective dimensions, accounting for the border
  final double profileCircleRadius = imageSize / 2; // Radius of the actual image content
  final double borderOuterRadius = profileCircleRadius + borderWidth; // Radius including the border

  // Total width/height of the marker icon
  final double contentWidth = textPainter.width > (borderOuterRadius * 2) ? textPainter.width : (borderOuterRadius * 2);
  final double totalWidth = contentWidth + padding * 2;
  final double totalHeight = (borderOuterRadius * 2) + textPainter.height + padding * 2; // Image area + text area + padding

  // Draw transparent background for the entire marker area
  canvas.drawRect(Rect.fromLTWH(0, 0, totalWidth, totalHeight), Paint()..color = Colors.transparent);
  canvas.save();

  ui.Image? profileImage;
  if (imageUrl != null && imageUrl.isNotEmpty) {
    try {
      final http.Response response = await http.get(Uri.parse(imageUrl));
      if (response.statusCode == 200) {
        final ui.Codec codec = await ui.instantiateImageCodec(response.bodyBytes);
        final ui.FrameInfo frameInfo = await codec.getNextFrame();
        profileImage = frameInfo.image;
      }
    } catch (e) {
      print('Error loading image for marker from URL ($imageUrl): $e');
      // If image loading fails, profileImage remains null, and fallback will be used
    }
  }

  // Calculate the center of the image/circle area
  final double imageAreaCenterX = totalWidth / 2;
  final double imageAreaCenterY = padding + profileCircleRadius; // Position image above text, with padding

  // --- Draw the border (if an image is present) ---
  bool hasImageContent = profileImage != null;

  if (hasImageContent) {
    final Paint borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke // Draw only the outline
      ..strokeWidth = borderWidth;
    // Draw the border circle around the *outer* radius
    canvas.drawCircle(Offset(imageAreaCenterX, imageAreaCenterY), borderOuterRadius, borderPaint);
  }

  // --- Clip path for the actual image content (inner circle) ---
  // The image itself should be drawn within 'imageSize' diameter
  canvas.clipPath(Path()..addOval(Rect.fromCircle(center: Offset(imageAreaCenterX, imageAreaCenterY), radius: profileCircleRadius)));

  if (profileImage != null) {
    // Draw the network image
    final Rect srcRect = Rect.fromLTWH(0, 0, profileImage.width.toDouble(), profileImage.height.toDouble());
    // Destination rect for drawing the image within the inner circle
    final Rect dstRect = Rect.fromLTWH(
      imageAreaCenterX - profileCircleRadius, // Left edge of the image
      imageAreaCenterY - profileCircleRadius, // Top edge of the image
      imageSize, // Width of the image
      imageSize, // Height of the image
    );
    canvas.drawImageRect(profileImage, srcRect, dstRect, Paint());
  } else {
    // Fallback: draw a colored circle if no image is provided or loaded
    final Paint circlePaint = Paint()..color = color.withOpacity(0.8);
    canvas.drawCircle(Offset(imageAreaCenterX, imageAreaCenterY), profileCircleRadius, circlePaint);
  }

  canvas.restore(); // Restore the canvas state (removes the clipping path)

  // Paint the label (text) below the image
  final double textX = (totalWidth - textPainter.width) / 2;
  final double textY = padding + (borderOuterRadius * 2) + 5; // Position text below the image/border area + some spacing
  textPainter.paint(canvas, Offset(textX, textY));

  // End recording and convert to BitmapDescriptor
  final ui.Image customMarkerImage = await pictureRecorder.endRecording().toImage(
    totalWidth.toInt(),
    totalHeight.toInt(),
  );
  final ByteData? byteData = await customMarkerImage.toByteData(format: ui.ImageByteFormat.png);
  return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
}

  // Assume this is inside your StatefulWidget's State class,
// and `_yourLocationMarkerIcon`, `_emergencyMarkerIcon`, `_markers` are declared
// as state variables (e.g., late BitmapDescriptor? _yourLocationMarkerIcon;).
// Also assume `widget.device` is accessible and contains 'profilePic', 'ownerName', etc.
// And `context` is available.



Future<void> _createCustomMarkerIcons() async {
  // --- Your Location Marker (Reverted to custom bitmap for text on circle) ---
  _yourLocationMarkerIcon = await _getCustomMarkerBitmap(
    label: 'You',
    color: const Color.fromARGB(255, 0, 42, 69),
    fontSize: 25,
    imageSize: 70.0,
    padding: 8.0,
    borderWidth: 0.0,
  );

  // Get profile picture URL for the emergency marker
  final String? profilePicUrl = widget.device?['profilePic'];

  // --- Emergency Marker (with profile picture and white border) ---
  _emergencyMarkerIcon = await _getCustomMarkerBitmap(
    label: widget.device?['ownerName'] ?? 'Emergency',
    color: Colors.red,
    imageUrl: profilePicUrl,
    fontSize: 25,
    imageSize: 80.0,
    padding: 8.0,
    borderWidth: 4.0,
    borderColor: Colors.white,
  );

  // --- Initial Placement of Emergency Marker (Corrected Marker ID) ---
  final double lat = widget.device?['latitude'] ?? 0;
  final double lng = widget.device?['longitude'] ?? 0;

  final Marker emergencyMarker = Marker(
    markerId: const MarkerId('emergency_device_marker'), // <<< CORRECTED ID HERE
    position: LatLng(lat, lng),
    icon: _emergencyMarkerIcon!,
    onTap: () {
      print('***** EMERGENCY MARKER TAP DETECTED *****');
      print('DEBUG: Emergency marker tapped. Profile Pic URL: $profilePicUrl');
    },
  );

  setState(() {
    _markers.clear(); // Clear all markers to start fresh (important for initial load)
    _markers.add(emergencyMarker);

    // --- Initial Placement of User Location Marker ---
    if (_yourLocation != null) {
      _markers.add(Marker(
        markerId: const MarkerId('your_location'),
        position: _yourLocation!,
        icon: _yourLocationMarkerIcon!,
      ));
    }
  });

  print('DEBUG: Total markers in _markers set: ${_markers.length}');
  _markers.forEach((m) {
    print('DEBUG: Marker ID: ${m.markerId.value}, Position: ${m.position.latitude}, ${m.position.longitude}');
  });
}
  

  void _updateUserLocationMarker(LatLng userLocation) {
  // Ensure the icon has been created
  if (_yourLocationMarkerIcon == null) return;

  final Marker userMarker = Marker(
    markerId: const MarkerId('your_location'),
    position: userLocation,
    icon: _yourLocationMarkerIcon!,
  );

  setState(() {
    // Store the location
    _yourLocation = userLocation;
    // Remove old 'your_location' marker if it exists and add the new one
    _markers.removeWhere((m) => m.markerId.value == 'your_location');
    _markers.add(userMarker);
  });
}

  void _updateDeviceLocationMarker(LatLng deviceLocation) {
  // Ensure the emergency marker icon has been successfully created.
  if (_emergencyMarkerIcon == null) {
    print('Warning: _emergencyMarkerIcon is null. Cannot update device marker.');
    return;
  }

  final Marker deviceMarker = Marker(
    markerId: const MarkerId('emergency_device_marker'), // Use a consistent ID
    position: deviceLocation,
    icon: _emergencyMarkerIcon!,
    onTap: () {
      print('***** EMERGENCY MARKER TAP DETECTED *****');
      print('DEBUG: Emergency marker tapped. Position: ${deviceLocation.latitude}, ${deviceLocation.longitude}');
    },
  );

  setState(() {
    helpingLocation = deviceLocation; // Update the state variable that holds device location
    _markers.removeWhere((m) => m.markerId.value == 'emergency_device_marker');
    _markers.add(deviceMarker);
  });

  print('DEBUG: Emergency device marker updated to: $deviceLocation');
}

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showError('Location services are disabled. Please enable them to provide help.');
      currentLocation = null;
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showError('Location permissions are denied. Cannot get your location.');
        currentLocation = null;
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      _showError('Location permissions are permanently denied. Please enable them from app settings.');
      currentLocation = null;
      return;
    }

    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      if (mounted) {
        setState(() {
          currentLocation = LatLng(position.latitude, position.longitude);
        });
      }
    } catch (e) {
      _showError('Failed to get your current location: $e');
      currentLocation = null;
    }
  }

  void _startPeriodicDistanceCalculation() {
    _distanceCalculationTimer?.cancel();
    _distanceCalculationTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted || _isExitingPage || currentLocation == null || _isLoading || !isHelping) {
        return;
      }

      try {
        Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 5),
        );

        if (!mounted || _isExitingPage) return;

        setState(() {
          currentLocation = LatLng(position.latitude, position.longitude);
        });
        print(1);
        _listenForEmergencyStatusChange();
        print(2);
        _fetchUserLocation(); //please
        print(3);

        double distance = Geolocator.distanceBetween(
          currentLocation!.latitude,
          currentLocation!.longitude,
          helpingLocation.latitude,
          helpingLocation.longitude,
        );

        print('Calculated distance periodically: $distance meters');
        

        bool shouldShowButton = (distance <= _resolveButtonThresholdMeters);
        print(_showResolveButton);
        if (_showResolveButton != shouldShowButton) {
          setState(() {
            _showResolveButton = shouldShowButton;
            _updateResolveButtonAnimation();
          });
        }
      } catch (e) {
        print('Error getting periodic location or calculating distance: $e');
      }
    });
  }

  void _handleEmergencyEnded(bool shouldUpdateHelperStatus) async {
  _showMessage('The emergency has ended. You are no longer helping.');
  if (isHelping && shouldUpdateHelperStatus) {
    await _updateHelperStatus("", false, shouldPop: false);
  }
  _navigateToHomepageAndClearStack();
}

void _handleOtherHelperTookOver() async {
  _showMessage('Someone else is now helping this emergency. You are no longer helping.');
  if (isHelping) {
    await _updateHelperStatus("", false, shouldPop: false);
  }
  _navigateToHomepageAndClearStack();
}

  void _listenForEmergencyStatusChange() {
  // Use widget.deviceId directly, assuming it's correctly passed to HelpingMapPage
  final deviceId = widget.device?['deviceId'];

  if (deviceId == null || deviceId.isEmpty) { // Added check for empty deviceId too
    print('Error: deviceId is null or empty for emergency status listener.');
    _navigateToHomepageAndClearStack();
    return;
  }

  // Cancel any existing listener to prevent duplicates
  _emergencyStatusListener?.cancel();

  _emergencyStatusListener = FirebaseFirestore.instance
      .collection('devices')
      .doc(deviceId)
      .snapshots()
      .listen((snapshot) async {
    if (!mounted || _isExitingPage) {
      return;
    }

    if (snapshot.exists) {
      final data = snapshot.data() as Map<String, dynamic>;

      // Extract emergency status fields
      final bool currentEmergencyStatus = data['emergency'] as bool? ?? false;
      final bool currentIsHelpComing = data['isHelpComing'] as bool? ?? false;
      final String currentHelper = data['helper'] as String? ?? "";

      // Extract latitude and longitude for the device
      final double? lat = data['latitude'];
      final double? lng = data['longitude'];

      // --- Handle Device Location Update ---
      if (lat != null && lng != null) {
        // If location data is valid and has changed
        // Check if current data is different from stored, OR if stored was previously invalid
        if (!_hasValidHelpingLocation || helpingLocation.latitude != lat || helpingLocation.longitude != lng) {
  final newHelpingLocation = LatLng(lat, lng); // Create the new LatLng here
  setState(() {
    helpingLocation = newHelpingLocation; // Assign the actual valid LatLng
    _hasValidHelpingLocation = true; // Mark as valid
  });
          _updateDeviceLocationMarker(newHelpingLocation); // Pass the variable directly

  print('Firebase Emergency Device Location Updated: $helpingLocation (VALID)');

  // ... (rest of your logic like starting distance calculation timer) ...
  if (_distanceCalculationTimer == null || !_distanceCalculationTimer!.isActive) {
    _startPeriodicDistanceCalculation();
    print('Starting periodic distance calculation due to new Firebase device location.');
  }
  _updateResolveButtonAnimation();
}
      } else {
        // If location data is invalid/missing from Firebase (lat or lng are null)
        // AND if our stored location was previously valid, then update it to the dummy value.
        if (_hasValidHelpingLocation) {
          setState(() {
            helpingLocation = LatLng(0.0, 0.0); // <<< Assign your default/dummy LatLng
            _hasValidHelpingLocation = false; // <<< Mark as INVALID (placeholder)
          });
          print('Firebase device location data for lat/lng is null or invalid. helpingLocation set to dummy.');
          _distanceCalculationTimer?.cancel(); // Stop distance checks if location is gone
          _updateResolveButtonAnimation();
        }
      }

      // --- Handle Emergency Status Changes ---
      if (!currentEmergencyStatus) {
        // Emergency has explicitly ended (emergency field is false)
        _handleEmergencyEnded(true);
        return;
      } else {
        // Emergency is still active, check helper status
        final prefs = await SharedPreferences.getInstance();
        final String ourHelperName = prefs.getString('currentHelperName') ?? "";

        bool newIsHelpingState = currentIsHelpComing && (currentHelper == ourHelperName);

        if (isHelping != newIsHelpingState) {
          setState(() {
            isHelping = newIsHelpingState;
          });
        }

        if (currentIsHelpComing && currentHelper != ourHelperName && isHelping) {
          _handleOtherHelperTookOver();
          return;
        }
      }
    } else {
      // Document no longer exists (implies emergency has ended/resolved)
      _handleEmergencyEnded(true);
    }
  }, onError: (error) {
    print('Error receiving emergency updates from Firestore: $error');
    _showError('Failed to receive emergency updates. Please check connection.');
    _handleEmergencyEnded(true); // Treat error as emergency ended and clean up
  });
}

  Future<void> _toggleHelping(bool value) async {
  if (!mounted || _isExitingPage) return;

  if (value) {
    final helperName = await _promptForHelperName();
    if (helperName != null && helperName.isNotEmpty) {
      setState(() {
        isHelping = true;
      });
      await _updateHelperStatus(helperName, true);
      _startPeriodicDistanceCalculation(); // CORRECT PLACE: Start timer here
    } else {
      _showMessage("Please provide your name to help.");
      if (mounted) {
        setState(() {
          isHelping = false;
          _showResolveButton = false; // Ensure button is hidden if user cancels
        });
      }
    }
  } else {
    // When isHelping is toggled OFF
    setState(() {
      isHelping = false;
      _showResolveButton = false; // Explicitly set to false here
    });
    _distanceCalculationTimer?.cancel(); // Stop the periodic checks
    await _updateHelperStatus("", false);
    _showMessage("You are no longer helping this emergency.");
  }
  _updateResolveButtonAnimation(); // CORRECT PLACE: This call correctly reflects the updated state
}
  Future<void> _updateHelperStatus(String name, bool status, {bool shouldPop = false}) async {
    if (widget.device?['deviceId'] == null || !mounted || _isExitingPage) return;

    final deviceId = widget.device!['deviceId'];
    final prefs = await SharedPreferences.getInstance();

    try {
      if (status) {
        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final docRef = FirebaseFirestore.instance.collection('devices').doc(deviceId);
          final docSnapshot = await transaction.get(docRef);

          if (!docSnapshot.exists) {
            throw Exception("Emergency document no longer exists.");
          }

          final currentData = docSnapshot.data() as Map<String, dynamic>;
          final currentIsHelpComing = currentData['isHelpComing'] as bool? ?? false;
          final currentHelper = currentData['helper'] as String? ?? "";

          if (currentIsHelpComing && currentHelper != name) {
            throw Exception("This emergency is already being handled by someone else.");
          }

          transaction.update(docRef, {
            'isHelpComing': true,
            'helper': name,
          });
        });
        await prefs.setString('currentHelperName', name);
      } else {
        final ourHelperName = prefs.getString('currentHelperName') ?? "";
        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final docRef = FirebaseFirestore.instance.collection('devices').doc(deviceId);
          final docSnapshot = await transaction.get(docRef);

          if (!docSnapshot.exists) return;

          final currentData = docSnapshot.data() as Map<String, dynamic>;
          final currentHelper = currentData['helper'] as String? ?? "";

          if (currentHelper == ourHelperName) {
            transaction.update(docRef, {
              'isHelpComing': false,
              'helper': "",
            });
          }
        });
        await prefs.remove('currentHelperName');
      }
    } catch (e) {
      _showError('Failed to update help status: ${e.toString()}');
      if (mounted) {
        setState(() {
          isHelping = !status;
        });
      }
    } finally {
      if (shouldPop && mounted && !Navigator.of(context).canPop()) {
        _navigateToHomepageAndClearStack();
      }
    }
  }

  Future<String?> _promptForHelperName() async {
    String? helperName;
    await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        TextEditingController nameController = TextEditingController();
        return AlertDialog(
          title: const Text('Your Name'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(hintText: 'Enter your name'),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                helperName = nameController.text.trim();
                Navigator.of(context).pop(helperName);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    return helperName;
  }

  Future<bool> _markEmergencyAsResolved() async {
  final deviceId = widget.device?['deviceId'];
  if (deviceId == null || !mounted || _isExitingPage) {
    return false; // Return false if deviceId is null or page is exiting
  }

  final bool? confirm = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Confirm Resolution'),
      content: const Text('Are you sure you want to mark this emergency as resolved?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Yes, Resolved'),
        ),
      ],
    ),
  );

  if (confirm != true) {
    return false; // Return false if the user cancels the confirmation
  }

  try {
    await FirebaseFirestore.instance.collection('devices').doc(deviceId).update({
      'emergency': false,
      'isHelpComing': false,
      'helper': '',
    });
    _showMessage('Emergency successfully marked as resolved.');
    return true; // Return true on successful resolution
  } catch (e) {
    _showError('Failed to mark emergency as resolved: $e');
    return false; // Return false if an error occurs during resolution
  }
}

  Future<bool> _onWillPop() async {
    if (!mounted || _isExitingPage) return true;

    if (isHelping) {
      final bool? confirmExit = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Stop Helping?'),
          content: const Text('Are you sure you want to stop helping and leave this page?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('No'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Yes'),
            ),
          ],
        ),
      );
      if (confirmExit == true) {
        await _updateHelperStatus("", false, shouldPop: false);
        return true;
      } else {
        return false;
      }
    }
    return true;
  }

  void _navigateToHomepageAndClearStack() {
    if (!mounted || _isExitingPage) return;
    _isExitingPage = true;

    Navigator.of(context).pushNamedAndRemoveUntil('/', (Route<dynamic> route) => false);
  }

  void _showMessage(String msg) {
    if (mounted && !_isExitingPage) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _showError(String msg) {
    if (mounted && !_isExitingPage) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (!didPop && mounted) {
          final shouldPop = await _onWillPop();
          if (shouldPop && mounted) {
            _navigateToHomepageAndClearStack();
          }
        }
      },
      child: Scaffold(
  backgroundColor: Colors.transparent,
  // Extends the body (GoogleMap) behind the AppBar
  extendBodyBehindAppBar: true,
  appBar: AppBar(
        title: Text(
                '${widget.device?['ownerName'] ?? 'Unknown'} is in Emergency!',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
                textAlign: TextAlign.left,
              ),
        backgroundColor: const Color.fromARGB(219, 14, 47, 60),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
  IconButton(
    icon: const Icon(Icons.person),
    color: Colors.white,
    onPressed: () {
      // Safely extract the deviceId from widget.device
      final String? passedDeviceId = widget.device?['deviceId'];

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => TempProfilePage(
            deviceId: passedDeviceId, // <<< Pass the data here!
          ),
        ),
      );
    },
  ),
],
      ),
  body: Stack(
    children: [
      // --- 1. Google Map: Positioned to fill the entire background ---
      Positioned.fill(
        child: GoogleMap(
          initialCameraPosition: CameraPosition(
            target: helpingLocation, // Make sure helpingLocation is defined in your State
            zoom: 15.0,
          ),
          onMapCreated: (GoogleMapController controller) {
            mapController = controller; // Make sure mapController is declared in your State
            // Animates the camera to show both locations if currentLocation is available
            if (currentLocation != null) { // Make sure currentLocation is defined in your State
              mapController.animateCamera(
                CameraUpdate.newLatLngBounds(
                  LatLngBounds(
                    southwest: LatLng(
                      (currentLocation!.latitude < helpingLocation.latitude
                          ? currentLocation!.latitude
                          : helpingLocation.latitude),
                      (currentLocation!.longitude < helpingLocation.longitude
                          ? currentLocation!.longitude
                          : helpingLocation.longitude),
                    ),
                    northeast: LatLng(
                      (currentLocation!.latitude > helpingLocation.latitude
                          ? currentLocation!.latitude
                          : helpingLocation.latitude),
                      (currentLocation!.longitude > helpingLocation.longitude
                          ? currentLocation!.longitude
                          : helpingLocation.longitude),
                    ),
                  ),
                  100.0, // Padding around the bounds
                ),
              );
            } else {
              // If currentLocation isn't available, just center on helpingLocation
              mapController.animateCamera(CameraUpdate.newLatLngZoom(helpingLocation, 15.0));
            }
          },
          markers: _markers, // **Crucial**: This links to your _markers state variable
          // You can add other map properties here if needed, e.g.,
          // myLocationEnabled: true,
          // myLocationButtonEnabled: true,
          // zoomControlsEnabled: false,
        ),
      ),

      // --- 2. Container: "Emergency from..." - Placed just below the AppBar ---
      Positioned(
        // 'top' is calculated to be below the AppBar, accounting for system status bar
        top: MediaQuery.of(context).padding.top + kToolbarHeight + 0.0,
        left:0.0, // Horizontal margin from left
        right: 0.0, // Horizontal margin from right (makes it less wide and centered)
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
          decoration: BoxDecoration(
  color: const Color.fromARGB(219, 14, 47, 60),
  borderRadius: const BorderRadius.only( // <<< Change is here
    topLeft: Radius.circular(0.0),      // Top-left corner is sharp
    topRight: Radius.circular(0.0),     // Top-right corner is sharp
    bottomLeft: Radius.circular(0.0),  // Bottom-left corner is rounded
    bottomRight: Radius.circular(0.0), // Bottom-right corner is rounded
  ),
 
),
          child: Column(
            mainAxisSize: MainAxisSize.min, // Column takes minimum vertical space
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'I am Helping:',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  Switch(
                    value: isHelping, // Make sure isHelping and _toggleHelping are defined in your State
                    onChanged: _toggleHelping,
                    activeColor: const Color.fromARGB(0, 76, 173, 175),
                    inactiveThumbColor: const Color.fromARGB(0, 255, 255, 255),
                    inactiveTrackColor: const Color.fromARGB(0, 255, 255, 255),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),

      // --- 3. Container: "Emergency Resolved" - Placed in the bottom-left ---
      if (isHelping && _showResolveButton) 
      Positioned(
        // 'bottom' is calculated from the bottom edge, accounting for system safe area
        bottom: MediaQuery.of(context).padding.bottom + 10.0,
        left: 0.0, // Margin from the left edge
        child: SlideTransition(
        position: _slideAnimation, // <--- ADD THIS WIDGET
        child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 2.0),
          decoration: BoxDecoration(
            color: const Color.fromARGB(219, 14, 47, 60),// Consistent semi-transparent background
            borderRadius: const BorderRadius.only(
              topLeft: Radius.zero,       // Sharp
              bottomLeft: Radius.zero,    // Sharp
              topRight: Radius.circular(30.0),
              bottomRight: Radius.circular(30.0),
            ),boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                spreadRadius: 1,
                blurRadius: 5,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min, // Row takes minimum horizontal space
            mainAxisAlignment: MainAxisAlignment.start, // Aligns content to the start (left)
            children: [
              const Text(
                'Emergency Resolved?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
             
              Switch(
                value: _isEmergencyResolved, // Make sure _isEmergencyResolved, _showResolveButton, _markEmergencyAsResolved are defined in your State
                onChanged: (isHelping && _showResolveButton)
                    ? (value) async {
                        if (value) {
                          bool resolved = await _markEmergencyAsResolved();
                          if (resolved) {
                            setState(() {
                              _isEmergencyResolved = true;
                            });
                          }
                        } else {
                          setState(() {
                            _isEmergencyResolved = false;
                          });
                        }
                        _updateResolveButtonAnimation();
                      }
                    : null, // Switch is disabled if conditions are not met
                thumbColor: MaterialStateProperty.resolveWith<Color?>((Set<MaterialState> states) {
                  if (states.contains(MaterialState.disabled)) {
                    return Colors.black54; // Thumb color when disabled
                  }
                  if (states.contains(MaterialState.selected)) {
                    return Colors.white; // Thumb color when active (on) and enabled
                  }
                  return const Color.fromARGB(255, 255, 255, 255); // Thumb color when inactive (off) and enabled
                }),
                trackColor: MaterialStateProperty.resolveWith<Color?>((Set<MaterialState> states) {
                  if (states.contains(MaterialState.disabled)) {
                    return Colors.white12; // Track color when disabled
                  }
                  if (states.contains(MaterialState.selected)) {
                    return const Color.fromARGB(255, 76, 173, 175); // Track color when active (on) and enabled
                  }
                  return Colors.grey.withOpacity(0.5); // Track color when inactive (off) and enabled
                }),
              ),
            ],
          ),
        ),
      ),
        ))
    ],
  ),
)
    );
  }
}





