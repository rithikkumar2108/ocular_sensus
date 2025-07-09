import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'helpmappage/helping_map_page.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';

class MapMarker {
  final String id;
  String label;
  LatLng position;
  final GlobalKey<_MarkerWidgetState> markerKey = GlobalKey();
  bool isEmergency;
  String? profilePicUrl; // New field for profile picture URL
  String? ownerName; // New field for owner's name
  double? distance; // ADDED: New field for distance

  MapMarker({
    required this.id,
    required this.label,
    required this.position,
    this.isEmergency = false,
    this.profilePicUrl,
    this.ownerName,
    this.distance, // ADDED: Initialize distance
  });
}

// Helper Tween for LatLng to enable smooth interpolation
class LatLngTween extends Tween<LatLng> {
  LatLngTween({required LatLng begin, required LatLng end})
      : super(begin: begin, end: end);

  @override
  LatLng lerp(double t) {
    return LatLng(
      begin!.latitude + (end!.latitude - begin!.latitude) * t,
      begin!.longitude + (end!.longitude - begin!.longitude) * t,
    );
  }
}

class RadarPage extends StatefulWidget {
  final String? deviceIdToFocus;
  final double? initialLatitude; // ADDED
  final double? initialLongitude;
  final bool isFullScreen;

  const RadarPage({
    super.key,
    this.deviceIdToFocus,
    this.initialLatitude, // ADDED
    this.initialLongitude, // ADDED
    required this.isFullScreen,
  });

  @override
  State<RadarPage> createState() => _RadarPageState();
}

class _RadarPageState extends State<RadarPage> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  double _currentZoom = 13.0; // Default zoom
  static const double _markerIconSize = 48;
  AnimationController? _cameraAnimationController;
  final String _mainPulsatingMarkerId = 'user_location';
  bool _isFocusingOnDevice = false;
  StreamSubscription? _mapEventStreamSubscription;
  bool _isMapReady = false;

  late final Map<String, GlobalKey<_MarkerWidgetState>> _markerKeys;

  final Map<String, MapMarker> _markers = {};
  LatLng? _currentUserLocation;
  StreamSubscription<Position>? _positionStreamSubscription;
  StreamSubscription<QuerySnapshot>? _firestoreStreamSubscription;
  LatLng _initialCameraPosition = LatLng(13.0827, 80.2707);

  String? _pendingFocusDeviceId;
  bool _isEmergencyDialogShowing = false; // <-- NEW STATE VARIABLE

  List<DocumentSnapshot> _latestFirestoreDocs = []; // ADDED: To store raw Firestore docs

  // ADDED: Distance formatting helper function
  String _formatDistance(double distanceInMeters) {
    if (distanceInMeters < 1000) {
      return '${distanceInMeters.toStringAsFixed(0)} m';
    } else {
      return '${(distanceInMeters / 1000).toStringAsFixed(1)} km';
    }
  }

  @override
  void initState() {
    super.initState();
    print('DEBUG: RadarPage initState. Received deviceIdToFocus: ${widget.deviceIdToFocus}');
    _markerKeys = {};

    _pendingFocusDeviceId = widget.deviceIdToFocus;

    if (widget.initialLatitude != null && widget.initialLongitude != null) {
      _initialCameraPosition = LatLng(widget.initialLatitude!, widget.initialLongitude!);
      print('DEBUG: Using initial coordinates from navigation for camera: $_initialCameraPosition');
    } else {
      _initialCameraPosition = LatLng(13.0827, 80.2707);
    }

    // This is the CORRECTED and GUARDED listener.
    // Ensure you have REMOVED any other _mapController.mapEventStream.listen() call from initState.
    _mapEventStreamSubscription = _mapController.mapEventStream.listen((event) {
      if (mounted) {
        setState(() => _currentZoom = _mapController.camera.zoom);
      }
    });

    _initializeLocationAndFirestore();
  }

 @override
void didUpdateWidget(covariant RadarPage oldWidget) {
  super.didUpdateWidget(oldWidget);
  print('DEBUG: RadarPage didUpdateWidget. New deviceIdToFocus: ${widget.deviceIdToFocus}, Old: ${oldWidget.deviceIdToFocus}');

  if (widget.deviceIdToFocus != oldWidget.deviceIdToFocus) {
    _pendingFocusDeviceId = widget.deviceIdToFocus;
    print('DEBUG: New deviceIdToFocus detected: ${widget.deviceIdToFocus}. Setting pending focus.');
    _resolveCameraFocus(); // Call after new focus ID is set
  }
}
  Future<void> _initializeLocationAndFirestore() async {
    print('DEBUG: _initializeLocationAndFirestore called.');
    await _determinePosition();
    _listenToEmergencyDevices();
    _updateVisibleMarkers(); // ADDED: Ensure initial markers are processed
  }

  Future<void> _determinePosition() async {
    print('DEBUG: _determinePosition called.');
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showSnackbar('Location services are disabled. Please enable them to use the radar.');
      print('DEBUG: Location services disabled.');
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showSnackbar('Location permissions are denied. The radar functionality may be limited.');
        print('DEBUG: Location permissions denied after request.');
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      _showSnackbar('Location permissions are permanently denied. Please enable them from app settings.');
      print('DEBUG: Location permissions permanently denied.');
      return Future.error(
          'Location permissions are permanently denied, we cannot request permissions.');
    }

    Position initialPosition = await Geolocator.getCurrentPosition();
    _updateUserLocation(initialPosition);

    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position position) {
      _updateUserLocation(position);
    });
  }

  // In your _resolveCameraFocus() method
void _resolveCameraFocus() {
  if (!_isMapReady) {
    print('DEBUG: _resolveCameraFocus: Map not ready. Deferring focus attempt.');
    return;
  }

  // If we just successfully focused on a device, do not re-center on user immediately
  if (_isFocusingOnDevice) {
    print('DEBUG: _resolveCameraFocus: Currently focusing on device, skipping immediate re-center.');
    return; // Exit early if a device focus just occurred
  }

  // Prioritize focusing on a pending device if set and marker exists
  if (_pendingFocusDeviceId != null && _markers.containsKey(_pendingFocusDeviceId!)) {
    print('DEBUG: _resolveCameraFocus: Found pending device $_pendingFocusDeviceId. Focusing...');
    _centerCamera(_markers[_pendingFocusDeviceId!]!.position, zoom: 15.0);
    _pendingFocusDeviceId = null; // Clear after successful focus

    // Set flag and reset after a short delay
    _isFocusingOnDevice = true;
    Future.delayed(const Duration(seconds: 1), () { // Adjust delay if needed
      if (mounted) { // Ensure widget is still mounted before setting state
        setState(() {
          _isFocusingOnDevice = false;
        });
      }
    });
  } else if (_currentUserLocation != null) {
    // Fallback to user's current location if no specific device is pending focus
    print('DEBUG: _resolveCameraFocus: No pending device to focus or marker not found. Centering on user location.');
    _centerCamera(_currentUserLocation!, zoom: 13.0);
  } else {
    print('DEBUG: _resolveCameraFocus: No user location available and no pending device. Cannot center map.');
  }
}
  // In your _updateUserLocation() method
// In your _updateUserLocation() method
void _updateUserLocation(Position position) {
  if (mounted) {
    setState(() {
      _currentUserLocation = LatLng(position.latitude, position.longitude);
      if (!_markers.containsKey(_mainPulsatingMarkerId)) {
        _markers[_mainPulsatingMarkerId] = MapMarker(
          id: _mainPulsatingMarkerId,
          label: 'You',
          position: _currentUserLocation!,
          ownerName: 'You',
        );
      } else {
        _markers[_mainPulsatingMarkerId]!.position = _currentUserLocation!;
      }
      _markerKeys[_mainPulsatingMarkerId] = _markers[_mainPulsatingMarkerId]!.markerKey;

      // After updating user location, re-evaluate and filter emergency markers.
      // This will also try to focus on the pending device if it becomes visible.
      _updateVisibleMarkers();

      // **REMOVE THIS ENTIRE LINE:**
      // _resolveCameraFocus(); // This is causing the map to jump back to user after a successful device focus.
    });
  }
}
  void _listenToEmergencyDevices() {
    print('DEBUG: Listening to emergency devices.');
    _firestoreStreamSubscription = FirebaseFirestore.instance
        .collection('devices')
        .where('emergency', isEqualTo: true)
        .snapshots()
        .listen((QuerySnapshot snapshot) {
      if (mounted) { // <-- ADDED mounted check here
        _latestFirestoreDocs = snapshot.docs; // ADDED: Store the latest documents
        _updateVisibleMarkers(); // ADDED: Call the new method to process and filter
      }
    }, onError: (error) {
      print("Error listening to emergency devices: $error");
      _showSnackbar('Failed to load emergency devices: $error');
    });
    // REMOVED: The old for (var change in snapshot.docChanges) loop contents
  }

  // ADDED: New method to update visible markers based on location and threshold
  // In your _updateVisibleMarkers() method
  // In your _updateVisibleMarkers() method
void _updateVisibleMarkers() {
  if (!mounted) return;

  final Map<String, MapMarker> newEmergencyMarkers = {};
  final currentEmergencyDeviceIds = <String>{};

  // Keep user marker
  if (_markers.containsKey(_mainPulsatingMarkerId)) {
    newEmergencyMarkers[_mainPulsatingMarkerId] = _markers[_mainPulsatingMarkerId]!;
    _markerKeys[_mainPulsatingMarkerId] = newEmergencyMarkers[_mainPulsatingMarkerId]!.markerKey;
  }

  if (_currentUserLocation == null) {
    print('DEBUG: _updateVisibleMarkers: _currentUserLocation is null. Cannot apply distance threshold yet.');
  } else {
    for (var doc in _latestFirestoreDocs) {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) continue;

      final deviceId = doc.id;
      final latitude = data['latitude'] as double?;
      final longitude = data['longitude'] as double?;
      final ownerName = data['ownerName'] as String? ?? deviceId;
      final profilePicUrl = data['profilePic'] as String?;
      final threshold = (data['emergency_threshold'] as num?)?.toDouble() ?? 0.0; // Retrieve threshold

      if (latitude == null || longitude == null) {
        print('Warning: Emergency device $deviceId has missing latitude or longitude.');
        continue;
      }

      final devicePosition = LatLng(latitude, longitude);
      final distance = Geolocator.distanceBetween(
        _currentUserLocation!.latitude,
        _currentUserLocation!.longitude,
        latitude,
        longitude,
      );

      // Apply the threshold logic, but always include the pending focus device
      if (threshold == 0.0 || distance <= threshold || deviceId == _pendingFocusDeviceId) {
        newEmergencyMarkers[deviceId] = MapMarker(
          id: deviceId,
          label: ownerName,
          position: devicePosition,
          isEmergency: true,
          ownerName: ownerName,
          profilePicUrl: profilePicUrl,
          distance: distance,
        );
        _markerKeys[deviceId] = newEmergencyMarkers[deviceId]!.markerKey;
        currentEmergencyDeviceIds.add(deviceId);
        // Trigger pulse for newly added/retained markers
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _markerKeys[deviceId]?.currentState?.startSecondaryPulse();
        });
      } else {
        print('DEBUG: Device $deviceId is NOT nearby (${_formatDistance(distance)} > ${_formatDistance(threshold)}) and will not be displayed.');
      }
    }
  }

  setState(() {
    _markers
      ..clear()
      ..addAll(newEmergencyMarkers);

    // Logic to remove marker keys for devices that are no longer present
    _markerKeys.keys.toList().forEach((key) {
      if (key != _mainPulsatingMarkerId && !currentEmergencyDeviceIds.contains(key)) {
        _markerKeys.remove(key);
      }
    });

    print('DEBUG: _markers updated via _updateVisibleMarkers. New count: ${_markers.length}');

    // **REPLACE THE ENTIRE IF/ELSE IF/ELSE BLOCK HERE WITH THIS:**
    if (_pendingFocusDeviceId != null) {
        print('DEBUG: _updateVisibleMarkers calling _attemptFocusOnPendingDevice for $_pendingFocusDeviceId');
        _attemptFocusOnPendingDevice(); // This will try to focus and clear if successful
    }
  });
}

  // In your _attemptFocusOnPendingDevice() method
void _attemptFocusOnPendingDevice() {
  if (_pendingFocusDeviceId != null && _isMapReady && _markers.containsKey(_pendingFocusDeviceId!)) {
    print('DEBUG: Successfully focusing on $_pendingFocusDeviceId at ${_markers[_pendingFocusDeviceId!]!.position} with zoom 15.0');
    _centerCamera(_markers[_pendingFocusDeviceId!]!.position, zoom: 15.0);
    _pendingFocusDeviceId = null; // Clear after successful focus

    // Set flag and reset after a short delay
    _isFocusingOnDevice = true;
    Future.delayed(const Duration(seconds: 1), () { // Adjust delay if needed
      if (mounted) { // Ensure widget is still mounted before setting state
        setState(() {
          _isFocusingOnDevice = false;
        });
      }
    });
  } else {
    print('DEBUG: Cannot focus on $_pendingFocusDeviceId. Map ready: $_isMapReady, Marker exists: ${_markers.containsKey(_pendingFocusDeviceId!)}');
  }
}

  @override
  void dispose() {
    print('DEBUG: RadarPage dispose.');
    _mapController.dispose();
    _positionStreamSubscription?.cancel();
    _firestoreStreamSubscription?.cancel();
    _cameraAnimationController?.dispose(); // <-- Keep this dispose call ONLY here
    _mapEventStreamSubscription?.cancel();
    super.dispose();
  }

  void _onMapReady() {
  if (mounted) {
    setState(() {
      _isMapReady = true;
    });
    print('DEBUG: Map is ready! _isMapReady: $_isMapReady');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveCameraFocus(); // Attempt to focus once the map is ready
      // Also start pulses for existing markers if any
      if (_currentUserLocation != null) {
        _markerKeys[_mainPulsatingMarkerId]?.currentState?.startMainPulse();
      }
      for (var marker in _markers.values) {
        if (marker.isEmergency) {
          _markerKeys[marker.id]?.currentState?.startSecondaryPulse();
        }
      }
    });
  }
}

  void _centerCamera(LatLng latLng, {double? zoom}) {
    if (!_isMapReady) {
      print('DEBUG: _centerCamera: Map not ready, cannot move camera.');
      return;
    }
    print('DEBUG: _centerCamera: Moving map to $latLng with zoom ${zoom ?? _currentZoom}');

    final LatLngTween latLngTween = LatLngTween(
      begin: _mapController.camera.center,
      end: latLng,
    );
    final Tween<double> zoomTween = Tween<double>(
      begin: _mapController.camera.zoom,
      end: zoom ?? _currentZoom,
    );

    _cameraAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    final Animation<double> animation = CurvedAnimation(
      parent: _cameraAnimationController!,
      curve: Curves.easeInOut,
    );

    _cameraAnimationController!.addListener(() {
      _mapController.move(latLngTween.evaluate(animation), zoomTween.evaluate(animation));
    });

    _cameraAnimationController!.forward();
  }

  void _showSnackbar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  // In your _showEmergencyDeviceDetails() method
void _showEmergencyDeviceDetails(MapMarker marker) {
  if (_isEmergencyDialogShowing || !mounted) return;

  setState(() {
    _isEmergencyDialogShowing = true;
  });

  showDialog(
    context: context,
    barrierDismissible: true, // Allow dismissing by tapping outside
    builder: (BuildContext context) {
      return AlertDialog(
        backgroundColor:const Color.fromARGB(208, 27, 73, 75).withOpacity(0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text(
          'Emergency Details: ${marker.ownerName ?? marker.id}',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: ListBody(
            children: <Widget>[
              if (marker.profilePicUrl != null && marker.profilePicUrl!.isNotEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: CircleAvatar(
                      radius: 40,
                      backgroundImage: NetworkImage(marker.profilePicUrl!),
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                ),
              Text(
                'Name: ${marker.ownerName ?? 'N/A'}',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                'Latitude: ${marker.position.latitude.toStringAsFixed(4)}',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                'Longitude: ${marker.position.longitude.toStringAsFixed(4)}',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 8),
              if (marker.distance != null)
                Text(
                  'Distance: ${_formatDistance(marker.distance!)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
              const SizedBox(height: 8),
              RichText(
  text: TextSpan(
    // You can set a default style for the entire RichText here if needed,
    // otherwise, children's styles will take precedence.
    style: const TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      // Default color for RichText if not specified in children, e.g., Colors.white
    ),
    children: <TextSpan>[
      const TextSpan(
        text: 'Status: ',
        style: TextStyle(
          color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w400// Specific color for "Status:"
        ),
      ),
      TextSpan(
        text: marker.isEmergency ? 'Emergency' : 'Normal',
        style: TextStyle(
          color: marker.isEmergency ? const Color.fromARGB(255, 255, 78, 78) : Colors.white70, // Conditional color for 'Emergency'/'Normal'
        ),
      ),
    ],
  ),
),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            child: const Text(
              'Help',
              style: TextStyle(color: Color.fromARGB(255, 123, 255, 145), fontWeight: FontWeight.bold),
            ),
            onPressed: () {
              Navigator.of(context).pop(); // Close the current dialog
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => HelpingMapPage(
                    initialHelpingDeviceId: marker.id, // <--- ADD THIS
                    initialHelpingDeviceLocation: marker.position, // <--- ADD THIS
                  ),
                ),
              );
            },
          ),
          const SizedBox(width:80),
          TextButton(
            child: const Text(
              'Close',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
        ],
      );
    },
  ).then((_) {
    // This 'then' block runs after the dialog is dismissed
    if (mounted) {
      setState(() {
        _isEmergencyDialogShowing = false;
      });
    }
  });
}
  @override
  Widget build(BuildContext context) {
    final visualPulseRadius = 450.0;

    List<Marker> mapMarkers = _markers.values.map((marker) {
      final isMainPulsator = marker.id == _mainPulsatingMarkerId;
      return Marker(
        point: marker.position,
        width: 70,
        height: 70,
        child: GestureDetector(
          onTap: () {
            print('DEBUG: Marker tapped: ${marker.id}. Centering camera.');
            _centerCamera(marker.position, zoom: _currentZoom); // Focus on tap

            // --- ADDED LOGIC FOR POPUP ---
            if (marker.isEmergency && !_isEmergencyDialogShowing) {
              _showEmergencyDeviceDetails(marker);
            }
            // --- END ADDED LOGIC ---
          },
          child: MarkerWidget(
            key: marker.markerKey,
            marker: marker,
            isMainPulsator: isMainPulsator,
            isEmergency: marker.isEmergency,
            pulseRadius: isMainPulsator ? visualPulseRadius : _markerIconSize * 2.5,
            profilePicUrl: marker.profilePicUrl,
            ownerName: marker.ownerName,
          ),
        ),
      );
    }).toList();

    if (_currentUserLocation == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(15.0),
      ),
      child: ClipRRect(
        borderRadius: widget.isFullScreen // <-- START OF CHANGES FOR CLIPRRECT
            ? BorderRadius.circular(15.0)
            : BorderRadius.circular(25.0), // Match parent's radius for clipping
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentUserLocation!,
                initialZoom: _currentZoom,
                minZoom: 5,
                maxZoom: 18,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
                onMapReady: _onMapReady,
              ),
              children: [
                TileLayer(
                  urlTemplate: "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png",
                  subdomains: const ['a', 'b', 'c'],
                  userAgentPackageName: 'com.example.app',
                  retinaMode: RetinaMode.isHighDensity(context),
                ),
                MarkerLayer(
                  markers: mapMarkers,
                ),
              ],
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: const Color.fromARGB(255, 45, 138, 157).withOpacity(0.3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MarkerWidget extends StatefulWidget {
  final MapMarker marker;
  final bool isMainPulsator;
  final bool isEmergency;
  final double pulseRadius;
  final String? profilePicUrl; // New field
  final String? ownerName; // New field

  const MarkerWidget({
    super.key,
    required this.marker,
    required this.isMainPulsator,
    required this.isEmergency,
    required this.pulseRadius,
    this.profilePicUrl,
    this.ownerName,
  });

  @override
  State<MarkerWidget> createState() => _MarkerWidgetState();
}

class _MarkerWidgetState extends State<MarkerWidget> with TickerProviderStateMixin {
  late AnimationController _mainPulseController;
  late Animation<double> _mainRipple1;
  late Animation<double> _mainOpacity1;
  late Animation<double> _mainRipple2;
  late Animation<double> _mainOpacity2;

  late AnimationController _secondaryPulseController;
  late Animation<double> _secondaryRipple;
  late Animation<double> _secondaryOpacity;

  static const double _markerIconSize = 32;
  static const double _avatarRadius = _markerIconSize / 2;

  @override
  void initState() {
    super.initState();

    _mainPulseController = AnimationController(vsync: this, duration: const Duration(seconds: 4));
    _setupMainPulseAnimations();

    _secondaryPulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    _setupSecondaryPulseAnimations();

    if (widget.isMainPulsator) {
      _mainPulseController.repeat();
    }
    if (widget.isEmergency) {
      _secondaryPulseController.repeat();
    }
  }

  String _processLabel(String? originalLabel, {int maxLength = 15}) {
    if (originalLabel == null || originalLabel.isEmpty) {
      return '';
    }
    String processedLabel = originalLabel.split(' ').first;

    if (processedLabel.length > maxLength) {
      return '${processedLabel.substring(0, maxLength - 3)}...';
    }
    return processedLabel;
  }

  void _setupMainPulseAnimations() {
    _mainRipple1 = Tween<double>(begin: _markerIconSize, end: widget.pulseRadius).animate(
      CurvedAnimation(parent: _mainPulseController, curve: const Interval(0.0, 1.0, curve: Curves.easeOut)),
    );
    _mainOpacity1 = Tween<double>(begin: 0.5, end: 0.0).animate(_mainPulseController);

    _mainRipple2 = Tween<double>(begin: _markerIconSize, end: widget.pulseRadius).animate(
      CurvedAnimation(parent: _mainPulseController, curve: const Interval(0.3, 1.0, curve: Curves.easeOut)),
    );
    _mainOpacity2 = Tween<double>(begin: 0.3, end: 0.0).animate(_mainPulseController);
  }

  void _setupSecondaryPulseAnimations() {
    _secondaryRipple = Tween<double>(begin: _markerIconSize, end: widget.pulseRadius).animate(
      CurvedAnimation(parent: _secondaryPulseController, curve: Curves.easeOut),
    );
    _secondaryOpacity = Tween<double>(begin: 0.8, end: 0.0).animate(_secondaryPulseController);
  }

  void startMainPulse() {
    if (widget.isMainPulsator) {
      _mainPulseController.repeat();
    }
  }

  void startSecondaryPulse() {
    if (widget.isEmergency) {
      _secondaryPulseController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant MarkerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.pulseRadius != oldWidget.pulseRadius) {
      _setupMainPulseAnimations();
      _setupSecondaryPulseAnimations();
      if (_mainPulseController.isAnimating) _mainPulseController.repeat();
      if (_secondaryPulseController.isAnimating) _secondaryPulseController.repeat();
    }

    if (widget.isMainPulsator != oldWidget.isMainPulsator) {
      if (widget.isMainPulsator) {
        _mainPulseController.repeat();
      } else {
        _mainPulseController.stop();
        _mainPulseController.value = 0.0;
      }
    }

    if (widget.isEmergency != oldWidget.isEmergency) {
      if (widget.isEmergency) {
        _secondaryPulseController.repeat();
      } else {
        _secondaryPulseController.stop();
        _secondaryPulseController.value = 0.0;
      }
    }
  }

  

  @override
  void dispose() {
    _mainPulseController.dispose();
    _secondaryPulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            if (widget.isMainPulsator) ...[
              AnimatedBuilder(
                animation: _mainPulseController,
                builder: (_, __) {
                  return Opacity(
                    opacity: _mainOpacity2.value,
                    child: Transform.scale(
                      scale: _mainRipple2.value / _markerIconSize,
                      child: Container(
                        width: _markerIconSize,
                        height: _markerIconSize,
                        decoration: BoxDecoration(
                          color: const Color.fromARGB(255, 85, 226, 198).withOpacity(0.6),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                },
              ),
              AnimatedBuilder(
                animation: _mainPulseController,
                builder: (_, __) {
                  return Opacity(
                    opacity: _mainOpacity1.value,
                    child: Transform.scale(
                      scale: _mainRipple1.value / _markerIconSize,
                      child: Container(
                        width: _markerIconSize,
                        height: _markerIconSize,
                        decoration: BoxDecoration(
                          color: const Color.fromARGB(255, 85, 226, 198).withOpacity(0.6),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
            if (widget.isEmergency)
              AnimatedBuilder(
                animation: _secondaryPulseController,
                builder: (_, __) {
                  return Opacity(
                    opacity: _secondaryOpacity.value,
                    child: Transform.scale(
                      scale: _secondaryRipple.value / _markerIconSize,
                      child: Container(
                        width: _markerIconSize,
                        height: _markerIconSize,
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.6),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                },
              ),
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 5,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: CircleAvatar(
                radius: _avatarRadius,
                backgroundColor: Colors.white.withOpacity(0.2),
                backgroundImage: (widget.profilePicUrl is String && (widget.profilePicUrl as String).isNotEmpty)
                    ? NetworkImage(widget.profilePicUrl as String) as ImageProvider<Object>?
                    : null,
                child: !(widget.profilePicUrl is String && (widget.profilePicUrl as String).isNotEmpty)
                    ? const Icon(
                        Icons.person,
                        size: 30,
                        color: Colors.white70,
                      )
                    : null,
              ),
            ),
          ],
        ),
        if (widget.ownerName != null && widget.ownerName!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(
              _processLabel(widget.ownerName),
              style: TextStyle(
                color: widget.isEmergency ? const Color.fromARGB(255, 255, 255, 255) : Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
                shadows: [
                  Shadow(
                    blurRadius: 3.0,
                    color: Colors.black.withOpacity(0.7),
                    offset: const Offset(1.0, 1.0),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
      ],
    );
  }
}