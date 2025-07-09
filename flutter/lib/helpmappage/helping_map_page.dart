import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:audioplayers/audioplayers.dart'; // Added for sound effect
import 'map_models.dart';
import 'firestore_service.dart';
import 'map_markers.dart';

class HelpingMapPage extends StatefulWidget {
  final String? initialHelpingDeviceId;
  final LatLng? initialHelpingDeviceLocation;

  const HelpingMapPage({
    super.key,
    this.initialHelpingDeviceId,
    this.initialHelpingDeviceLocation,
  });

  @override
  State<HelpingMapPage> createState() => _HelpingMapPageState();
}

class _HelpingMapPageState extends State<HelpingMapPage> with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();
  final FirestoreService _firestoreService = FirestoreService();
  final TextEditingController _statusController = TextEditingController();
  final Uuid _uuid = const Uuid();
  final AudioPlayer _audioPlayer = AudioPlayer(); // Audio player instance

  // User and state management
  String? _userName;
  String? _helperId;
  HelperRole _userRole = HelperRole.passive;
  LatLng? _currentUserLocation;
  EmergencyMarker? _helpingDevice; // The device the user is currently helping
  String _currentUserStatus = '';

  // Data from Firestore
  List<EmergencyMarker> _emergencyMarkers = [];
  final Map<String, List<HelperMarker>> _helperMarkersMap = {};

  // UI state
  bool _isInitialized = false;
  bool _showVigilanteOverlay = false; // <<< CHANGE 1: Start with overlay invisible for fade-in
  String? _showingHelperLabelForDeviceId;
  bool _showResolveButton = false;
  late AnimationController _resolveButtonAnimationController;
  late Animation<Offset> _resolveButtonOffsetAnimation;

  // <<< TIMER: State for the emergency duration timer
  Timer? _durationTimer;
  Duration? _emergencyDuration;

  // Stream subscriptions
  StreamSubscription<Position>? _positionStreamSub;
  StreamSubscription<List<EmergencyMarker>>? _emergencyStreamSub;
  final Map<String, StreamSubscription> _helperStreamSubs = {};

  @override
  void initState() {
    super.initState();
    _helperId = _uuid.v4();
    _resolveButtonAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _resolveButtonOffsetAnimation = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _resolveButtonAnimationController,
      curve: Curves.easeOut,
    ));

    // Initialize location services and data streams first.
    _initializeMapAndDataStreams();

    // Trigger the initial sequence: overlay -> prompt -> button logic
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startInitialSequence();
    });
  }

  Future<void> _startInitialSequence() async {
    // 1. Trigger overlay fade-in before playing sound
    if (mounted) {
      setState(() => _showVigilanteOverlay = true); // This triggers the 2-second fade IN
    }

    // 2. Play sound effect along with the fade-in
    await _playLocalSound('audio/vigilante_active.mp3'); // Sound starts

    // Wait for the sound duration (and overlay fade-in to complete)
    await Future.delayed(const Duration(seconds: 2));
    await Future.delayed(const Duration(seconds: 1));

    // Then, trigger the overlay fade-out
    if (mounted) {
      setState(() => _showVigilanteOverlay = false); // This triggers the 2-second fade OUT
    }

    // Wait for the AnimatedOpacity to complete its fade-out duration
    await Future.delayed(const Duration(seconds: 2)); // This duration must match the `duration` of `AnimatedOpacity` in `_buildVigilanteOverlay`

    // 3. Prompt for user information
    await _promptForUserInfo();
  }

  // 1. Initial prompts for user information. (Modified to be called *after* overlay)
  Future<void> _promptForUserInfo() async {
    final result = await _showNameAndRoleDialog();
    if (result == null || result['name'] == null || (result['name'] as String).isEmpty || result['role'] == null) {
      if (mounted) Navigator.of(context).pop(); // Exit if no valid info
      return;
    }

    setState(() {
      _userName = result['name'] as String;
      _userRole = result['role'] as HelperRole;
      _isInitialized = true; // Mark as initialized only after getting user info
    });

    // NEW: After initialization, check and select initial helping device if provided
    if (mounted && _isInitialized && widget.initialHelpingDeviceId != null && _helpingDevice == null) {
      // Give the stream a moment to populate _emergencyMarkers if it hasn't already
      // This is a safety measure, as the stream might not have emitted the first event yet.
      await Future.delayed(const Duration(milliseconds: 100));

      final initialDevice = _emergencyMarkers.firstWhereOrNull((d) => d.id == widget.initialHelpingDeviceId);
      if (initialDevice != null) {
        _selectEmergencyToHelp(initialDevice, isInitial: true);
      } else {
        _showSnackbar("The emergency you were trying to help is no longer active or found.", isError: false);
      }
    }
  }


  // 2. Initialize location services and data streams from Firestore.
  Future<void> _initializeMapAndDataStreams() async {
    try {
      await _determinePosition();
      _listenToEmergencies();
    } catch (e) {
      _showSnackbar("Initialization failed: ${e.toString()}", isError: true);
    }
  }

  // 3. Handle location permissions and start listening to position updates.
  Future<void> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showSnackbar('Location services are disabled. Please enable them.', isError: true);
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showSnackbar('Location permissions are denied.', isError: true);
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      _showSnackbar('Location permissions are permanently denied, we cannot request permissions.', isError: true);
      return Future.error('Location permissions are permanently denied, we cannot request permissions.');
    }

    Position position = await Geolocator.getCurrentPosition();
    if (mounted) {
      setState(() {
        _currentUserLocation = LatLng(position.latitude, position.longitude);
      });
    }

    _positionStreamSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5), // Increased frequency for distance calculation
    ).listen((pos) {
      if (mounted) {
        setState(() {
          _currentUserLocation = LatLng(pos.latitude, pos.longitude);
        });
        // Only update helper on Firestore and check distance if user info has been captured
        if (_isInitialized && _helpingDevice != null) {
          _updateHelperOnFirestore(status: _currentUserStatus);
          _checkDistanceToEmergency(); // Check distance on location update
        }
      }
    });
  }

  // Helper method to calculate distance
  double _calculateDistance(LatLng latLng1, LatLng latLng2) {
    return Geolocator.distanceBetween(
      latLng1.latitude,
      latLng1.longitude,
      latLng2.latitude,
      latLng2.longitude,
    );
  }

  // Check distance to emergency and show/hide resolve button
  void _checkDistanceToEmergency() {
    // Only proceed if the app is initialized (user has provided name/role)
    if (!_isInitialized) return;

    if (_currentUserLocation != null && _helpingDevice != null) {
      final distance = _calculateDistance(_currentUserLocation!, _helpingDevice!.position);
      if (distance <= 20.0 && !_showResolveButton) {
        setState(() {
          _showResolveButton = true;
        });

        _resolveButtonAnimationController.forward();
        _playLocalSound('audio/slidein.mp3'); // Sound for button slide in
      } else if (distance > 20.0 && _showResolveButton) {
        _resolveButtonAnimationController.reverse().then((_) {
          if (mounted) {
            setState(() {
              _showResolveButton = false;
            });
          }
        });
      }
    } else if (_showResolveButton) {
      _resolveButtonAnimationController.reverse().then((_) {
        if (mounted) {
          setState(() {
            _showResolveButton = false;
          });
        }
      });
    }
  }

  // 4. Listen to the main stream of emergency devices.
  void _listenToEmergencies() {
    _emergencyStreamSub?.cancel();
    _emergencyStreamSub = _firestoreService.getEmergencyDevicesStream().listen((devices) {
      if (mounted) {
        setState(() {
          _emergencyMarkers = devices;

          // NEW LOGIC START: Update _helpingDevice if its data has changed
          if (_helpingDevice != null) {
            final updatedHelpingDevice = devices.firstWhereOrNull((d) => d.id == _helpingDevice!.id);
            if (updatedHelpingDevice != null) {
              // Only update if the position (or other relevant fields) has actually changed
              if (updatedHelpingDevice.position != _helpingDevice!.position) {
                print('🔔 Emergency device location updated in Firestore. Updating _helpingDevice.');
                // <<< TIMER: important to update the helping device to get the latest data
                _helpingDevice = updatedHelpingDevice;
                _centerMapOnLocation(_helpingDevice!.position);
                if (_isInitialized) { 
                  _checkDistanceToEmergency(); 
                }
              }
            } else {
              _showSnackbar("The emergency you were helping has been resolved by someone else.", isError: false);
               // <<< TIMER: Stop the timer when the emergency is resolved elsewhere
              _stopDurationTimer();
              _helpingDevice = null;
              _showResolveButton = false;
              _resolveButtonAnimationController.reverse();
            }
          }
          // NEW LOGIC END
        });
        _listenToHelpersForDevices(devices);
      }
    });
  }

  // 5. Manage streams for helpers for each visible emergency device.
  void _listenToHelpersForDevices(List<EmergencyMarker> devices) {
    final currentDeviceIds = devices.map((d) => d.id).toSet();
    _helperStreamSubs.keys.where((id) => !currentDeviceIds.contains(id)).forEach((id) {
      _helperStreamSubs[id]?.cancel();
    });
    _helperStreamSubs.removeWhere((id, _) => !currentDeviceIds.contains(id));

    for (final device in devices) {
      if (!_helperStreamSubs.containsKey(device.id)) {
        _helperStreamSubs[device.id] = _firestoreService.getHelpersStream(device.id).listen((helpers) {
          if (mounted) {
            setState(() {
              _helperMarkersMap[device.id] = helpers;
            });
          }
        });
      }
    }
  }

  // 6. Handle long-pressing an emergency marker to offer help.
  Future<void> _selectEmergencyToHelp(EmergencyMarker device, {bool isInitial = false}) async {
    if (!_isInitialized) {
      _showSnackbar("Please enter your name and role first.", isError: true);
      return;
    }

    bool? confirm = isInitial
        ? true
        : await _showConfirmationDialog(
            title: 'Help ${device.ownerName}?',
            content: 'Do you want to switch to helping this person?',
          );

    if (confirm == true && mounted) {
      if (_helpingDevice != null && _helpingDevice!.id != device.id) {
        await _firestoreService.removeHelper(_helpingDevice!.id, _helperId!);
      }
      setState(() {
        _helpingDevice = device;
      });
       // <<< TIMER: Start the timer when a device is selected.
      _startDurationTimer();
      _updateHelperOnFirestore(status: _currentUserStatus);
      if (!isInitial) {
        _showSnackbar("You are now helping ${device.ownerName}.", isError: false);
      }
      _centerMapOnLocation(device.position);
      _checkDistanceToEmergency();
    }
  }

  // 7. Update the user's status in Firestore.
  Future<void> _updateHelperOnFirestore({String? status}) async {
    if (_helpingDevice == null || _userName == null || _currentUserLocation == null || !_isInitialized) return; // Add _isInitialized check

    setState(() {
      _currentUserStatus = status ?? _statusController.text;
    });

    await _firestoreService.updateHelperStatus(
      deviceId: _helpingDevice!.id,
      helperId: _helperId!,
      name: _userName!,
      location: _currentUserLocation!,
      role: _userRole,
      status: _currentUserStatus,
    );
  }

  // Method to launch Google Maps with directions
  Future<void> _launchGoogleMapsDirections(LatLng origin, LatLng destination) async {
    final url = 'http://maps.google.com/maps?saddr=${origin.latitude},${origin.longitude}&daddr=${destination.latitude},${destination.longitude}&travelmode=driving';
    final Uri uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      _showSnackbar('Could not open map for directions. Please ensure you have Google Maps installed.', isError: true);
    }
  }

  // Handle emergency resolution
  Future<void> _resolveEmergency() async {
    if (_helpingDevice == null) {
      _showSnackbar("No emergency currently selected to resolve.", isError: true);
      return;
    }

    final confirm = await _showConfirmationDialog(
      title: 'Resolve Emergency?',
      content: 'Are you sure you want to mark this emergency as resolved?',
    );

    if (confirm == true) {
      await _firestoreService.resolveEmergency(_helpingDevice!.id);
      _showSnackbar("Emergency resolved. Thank you for your help!", isError: false);
      // <<< TIMER: Stop the timer when the emergency is resolved by the user.
      _stopDurationTimer();
      setState(() {
        _helpingDevice = null;
        _showResolveButton = false;
      });
      _resolveButtonAnimationController.reverse();
    }
  }

  // Play local sound effect (requires audioplayers package and sound asset)
  Future<void> _playLocalSound(String assetPath) async {
    try {
      await _audioPlayer.play(AssetSource(assetPath));
    } catch (e) {
      debugPrint('Error playing sound: $e');
    }
  }

  // <<< TIMER: Helper function to start the duration timer
  void _startDurationTimer() {
    _durationTimer?.cancel(); // Cancel any existing timer
    if (_helpingDevice == null) return;

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _helpingDevice == null) {
        timer.cancel();
        return;
      }
      setState(() {
        _emergencyDuration = DateTime.now().difference(_helpingDevice!.timestamp);
      });
    });
  }

  // <<< TIMER: Helper function to stop the duration timer
  void _stopDurationTimer() {
    _durationTimer?.cancel();
    if (mounted) {
      setState(() {
        _emergencyDuration = null;
      });
    }
  }
  
  // <<< TIMER: Helper function to format Duration into hh:mm:ss
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String hours = twoDigits(duration.inHours);
    String minutes = twoDigits(duration.inMinutes.remainder(60));
    String seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$hours:$minutes:$seconds";
  }

  // 8. Build the list of all markers to display on the map.
  List<Marker> _buildAllMarkers() {
    final List<Marker> markers = [];

    // Add emergency markers
    for (final device in _emergencyMarkers) {
      markers.add(Marker(
        point: device.position,
        width: 54,
        height: 54,
        child: GestureDetector(
          onTap: () {
            _centerMapOnLocation(device.position);
          },
          onLongPress: () {
            if (device.id == _helpingDevice?.id && _currentUserLocation != null) {
              _launchGoogleMapsDirections(
                _currentUserLocation!,
                device.position,
              );
            } else {
              _selectEmergencyToHelp(device);
            }
          },
          child: EmergencyDeviceMarkerWidget(marker: device),
        ),
      ));
    }

    // Add helper markers
    _helperMarkersMap.forEach((_, helpers) {
      for (final helper in helpers) {
        if (helper.id == _helperId) continue;
        markers.add(Marker(
          point: helper.position,
          width: 54,
          height: 54,
          child: GestureDetector(
            onTap: () {
              setState(() {
                _showingHelperLabelForDeviceId = helper.helpingDeviceId;
              });
              Future.delayed(const Duration(seconds: 3), () {
                if (mounted && _showingHelperLabelForDeviceId == helper.helpingDeviceId) {
                  setState(() {
                    _showingHelperLabelForDeviceId = null;
                  });
                }
              });
            },
            child: HelperMarkerWidget(
              marker: helper,
              showHelpingLabel: _showingHelperLabelForDeviceId == helper.helpingDeviceId,
              helpingDeviceOwnerName: _emergencyMarkers.firstWhereOrNull((e) => e.id == helper.helpingDeviceId)?.ownerName,
            ),
          ),
        ));
      }
    });

    // Add current user's location marker
    if (_currentUserLocation != null && _userName != null) {
      markers.add(Marker(
        point: _currentUserLocation!,
        width: 54,
        height: 54,
        child: UserStatusMarker(
          color: _helpingDevice?.color ?? Colors.blueAccent,
          status: _currentUserStatus,
          userName: "You",
          role: _userRole,
        ),
      ));
    }

    return markers;
  }

  void _centerMapOnLocation(LatLng location) {
    const double delta = 0.0001;
    LatLng southwest = LatLng(location.latitude - delta, location.longitude - delta);
    LatLng northeast = LatLng(location.latitude + delta, location.longitude + delta);
    LatLngBounds bounds = LatLngBounds(southwest, northeast);

    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(0),
        minZoom: 15.0,
      ),
    );
  }

  @override
  void dispose() {
    _statusController.dispose();
    _positionStreamSub?.cancel();
    _emergencyStreamSub?.cancel();
    _helperStreamSubs.forEach((_, sub) => sub.cancel());
    _mapController.dispose();
    _resolveButtonAnimationController.dispose();
    _audioPlayer.dispose();
    // <<< TIMER: Ensure the timer is cancelled when the page is disposed.
    _durationTimer?.cancel();
    if (_helpingDevice != null) {
      _firestoreService.removeHelper(_helpingDevice!.id, _helperId!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        final confirm = await _showConfirmationDialog(
          title: 'Leave Page?',
          content: 'Are you sure you want to exit Vigilante Mode?',
        );
        if (confirm == true) {
          _showSnackbar("Vigilante Mode disabled. Your location is now private.", isError: false);
        }
        return confirm ?? false;
      },
      child: Scaffold(
        body: Stack( 
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentUserLocation ?? const LatLng(13.0827, 80.2707),
                initialZoom: 15.0,
                maxZoom: 20.0,
                minZoom: 5.0,
                interactionOptions: InteractionOptions(
                  flags: _isInitialized ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none, 
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png",
                  subdomains: const ['a', 'b', 'c'],
                ),
                MarkerLayer(markers: _buildAllMarkers()),
              ],
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: const Color.fromARGB(255, 45, 138, 157).withOpacity(0.3),
                ),
              ),
            ),

            _buildVigilanteOverlay(),

            if (_isInitialized) ...[
                // <<< TIMER: Add the timer widget to the UI stack.
                _buildEmergencyTimer(),

                Positioned(
                  bottom: 150,
                  left: 10,
                  child: Text(
                    _helpingDevice != null
                        ? 'Currently helping: ${_helpingDevice!.ownerName}'
                        : 'Currently helping: None',
                    style: TextStyle(color: Colors.white70, fontSize: 14), 
                  ),
                ),

              if (_helpingDevice != null && _currentUserLocation != null)
                Positioned(
                  bottom: 190,
                  right: 10,
                  child: FloatingActionButton(
                    heroTag: "focusHelpingDevice",
                    mini: true,
                    backgroundColor: const Color.fromARGB(208, 27, 73, 75).withOpacity(0.5),
                    onPressed: () {
                      if (_helpingDevice != null) {
                        _centerMapOnLocation(_helpingDevice!.position);
                      }
                    },
                    child: const Icon(Icons.my_location, color: Colors.white),
                  ),
                ),
              if (_currentUserLocation != null)
                Positioned(
                  bottom: 145,
                  right: 10,
                  child: FloatingActionButton(
                    heroTag: "focusUserLocation",
                    mini: true,
                    backgroundColor: const Color.fromARGB(208, 27, 73, 75).withOpacity(0.5),
                    onPressed: () {
                      _centerMapOnLocation(_currentUserLocation!);
                    },
                    child: const Icon(Icons.pin_drop_sharp, color: Colors.white),
                  ),
                ),
              _buildStatusUpdateBar(),
              _buildRoleSwitch(),
              
              _buildResolveButton(),
            ],
          ],
        ),
      ),
    );
  }

  // --- UI WIDGETS and DIALOGS ---
  
  // <<< TIMER: New UI widget for the timer display.
  Widget _buildEmergencyTimer() {
    if (_helpingDevice == null || _emergencyDuration == null) {
      return const SizedBox.shrink(); // Return an empty widget if not helping
    }

    return Positioned(
      top: 100,
      right: 11,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color.fromARGB(121, 23, 66, 70),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 12,
              offset: const Offset(0, 6),
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.timer, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              _formatDuration(_emergencyDuration!),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildVigilanteOverlay() {
  return AnimatedOpacity(
    opacity: _showVigilanteOverlay ? 1.0 : 0.0,
    duration: const Duration(seconds: 2),
    child: IgnorePointer(
      ignoring: !_showVigilanteOverlay, 
      child: Container(
        color: const Color.fromARGB(255, 8, 38, 34).withOpacity(0.7),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Vigilante Mode Active',
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                'Your location is now public to those in need.',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

  Widget _buildRoleSwitch() {
    return Positioned(
      top: 40,
      right: 10,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: const Color.fromARGB(121, 23, 66, 70),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 12,
              offset: const Offset(0, 6),
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              _userRole == HelperRole.active ? Icons.directions_run : Icons.visibility,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              _userRole == HelperRole.active ? 'Active' : 'Passive',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            Switch(
              value: _userRole == HelperRole.active,
              onChanged: (isActive) {
                setState(() {
                  _userRole = isActive ? HelperRole.active : HelperRole.passive;
                });
                _updateHelperOnFirestore(status: _currentUserStatus);
              },
              activeColor: Colors.white,
              activeTrackColor: const Color.fromARGB(255, 26, 94, 110),
              inactiveThumbColor: Colors.white,
              inactiveTrackColor: Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusUpdateBar() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(12.0),
        decoration: BoxDecoration(
          color: const Color.fromARGB(208, 27, 73, 75).withOpacity(0.5),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(10.0)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              spreadRadius: 5,
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _statusController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Update your status...',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                filled: true,
                fillColor: Colors.white.withOpacity(0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10.0),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.clear, color: Colors.white),
                      onPressed: () {
                        _statusController.clear();
                        _updateHelperOnFirestore(status: '');
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.send, color: Colors.white),
                      onPressed: () {
                        _updateHelperOnFirestore(status: _statusController.text);
                        FocusScope.of(context).unfocus();
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _statusChip('On my way'),
                  _statusChip('Have vehicle'),
                  _statusChip('Calling ambulance'),
                  _statusChip('Getting help'),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: ActionChip(
        label: Text(text),
        labelStyle: const TextStyle(color: Colors.white),
        backgroundColor: const Color.fromARGB(64, 27, 73, 75).withOpacity(0.9),
        elevation: 5.0,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20.0),
          side: const BorderSide(color: Colors.transparent),
        ),
        onPressed: () {
          _statusController.text = text;
          _updateHelperOnFirestore(status: text);
        },
      ),
    );
  }

  Widget _buildResolveButton() {
    return Positioned(
      bottom: 240, // Position above other controls
      right: 10,
      child: SlideTransition(
        position: _resolveButtonOffsetAnimation,
        child: Visibility(
          visible: _showResolveButton,
          child: FloatingActionButton.extended(
            heroTag: "resolveEmergency",
            onPressed: _resolveEmergency,
            label: const Text(
              'Resolve',
              style: TextStyle(color: Colors.white),
            ),
            icon: const Icon(Icons.check_circle_outline, color: Colors.white),
            backgroundColor: const Color.fromARGB(208, 27, 73, 75).withOpacity(0.5),
          ),
        ),
      ),
    );
  }

  // Combined Name and Role Dialog
  Future<Map<String, dynamic>?> _showNameAndRoleDialog() async {
  TextEditingController nameController = TextEditingController();
  HelperRole? selectedRole; // Initialize to null

  if (_userName != null) {
    nameController.text = _userName!;
    selectedRole = _userRole; 
  }

  return await showGeneralDialog<Map<String, dynamic>?>(
    context: context,
    barrierDismissible: false,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withOpacity(0.5), 
    transitionDuration: const Duration(milliseconds: 350),
    pageBuilder: (BuildContext buildContext, Animation animation, Animation secondaryAnimation) {
      return StatefulBuilder( 
        builder: (BuildContext context, StateSetter setDialogState) {
          return Center(
            child: SizedBox(width:300,
              child: Material(
                type: MaterialType.card,
                color: const Color.fromARGB(208, 27, 73, 75).withOpacity(0.5),
                borderRadius: BorderRadius.circular(20.0),
                child: Container(
                  padding: const EdgeInsets.only(left:30.0,right:30,top:30,bottom:20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text(
                        'Welcome, Vigilante!',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white, 
                        ),
                      ),
                      const SizedBox(height: 15),
                      TextField(
                        controller: nameController,
                        autofocus: true,
                        style: const TextStyle(color: Colors.white), 
                        onChanged: (text) {
                          setDialogState(() {
                          });
                        },
                        decoration: InputDecoration(
                          labelText: 'Enter Your Name',
                          labelStyle: const TextStyle(color: Colors.white70), 
                          hintStyle: const TextStyle(color: Colors.white54), 
                          filled: true,
                          fillColor: Colors.black.withOpacity(0.2), 
                          border: const OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.grey), 
                          ),
                          enabledBorder: const OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.grey), 
                          ),
                          focusedBorder: const OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white), 
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.check, color: Colors.white), 
                            onPressed: () {
                              FocusScope.of(context).unfocus(); // Close keyboard
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Choose Your Role:',
                        style: TextStyle(color: Colors.white), 
                      ),
                      RadioListTile<HelperRole>(
                        title: const Text('Active Helper', style: TextStyle(color: Colors.white)), 
                        subtitle: const Text('Expected to physically assist.', style: TextStyle(color: Colors.grey)), 
                        value: HelperRole.active,
                        groupValue: selectedRole,
                        onChanged: (HelperRole? value) {
                          setDialogState(() { 
                            selectedRole = value;
                          });
                          FocusScope.of(context).unfocus(); 
                        },
                        activeColor: Colors.white, 
                        selectedTileColor: Colors.blue.withOpacity(0.2), 
                      ),
                      RadioListTile<HelperRole>(
                        title: const Text('Passive Helper', style: TextStyle(color: Colors.white)), 
                        subtitle: const Text('Provides support remotely.', style: TextStyle(color: Colors.grey)), 
                        value: HelperRole.passive,
                        groupValue: selectedRole,
                        onChanged: (HelperRole? value) {
                          setDialogState(() { 
                            selectedRole = value;
                          });
                          FocusScope.of(context).unfocus(); 
                        },
                        activeColor: Colors.white, 
                        selectedTileColor: Colors.blue.withOpacity(0.2),
                      ),
                      const SizedBox(height: 15),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color.fromARGB(255, 22, 74, 86), 
                          foregroundColor: Colors.white, 
                        ),
                        onPressed: (nameController.text.trim().isNotEmpty && selectedRole != null)
                            ? () {
                                Navigator.of(context).pop({'name': nameController.text.trim(), 'role': selectedRole});
                              }
                            : null, 
                        child: const Text('Confirm'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

  Future<bool?> _showConfirmationDialog({required String title, required String content}) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Confirm')),
        ],
      ),
    );
  }

  void _showSnackbar(String message, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? const Color.fromARGB(179, 99, 29, 29) : const Color.fromARGB(204, 46, 75, 74),
    ));
  }
}

extension FirstWhereOrNullExtension<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E element) test) {
    for (E element in this) {
      if (test(element)) {
        return element;
      }
    }
    return null;
  }
}