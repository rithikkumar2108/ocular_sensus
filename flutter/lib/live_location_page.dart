import 'dart:async';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';

// Assuming these files exist in your project structure.
// If not, you might need to create them or adjust the imports.
import 'helpmappage/firestore_service.dart';
import 'helpmappage/map_models.dart';

// --- Data Models and Service Extensions ---

class DeviceData {
  final String id;
  final String ownerName;
  final String? profilePicUrl;
  final LatLng position;
  final bool isEmergency;
  final double emergencyThreshold;
  final String? nav;
  final Timestamp? timestamp; // Added for emergency timer

  DeviceData({
    required this.id,
    required this.ownerName,
    this.profilePicUrl,
    required this.position,
    required this.isEmergency,
    required this.emergencyThreshold,
    this.nav,
    this.timestamp,
  });

  factory DeviceData.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return DeviceData(
      id: doc.id,
      ownerName: data['ownerName'] as String? ?? 'Unknown',
      profilePicUrl: data['profilePic'] as String?,
      position: LatLng(
        (data['latitude'] as num?)?.toDouble() ?? 0.0,
        (data['longitude'] as num?)?.toDouble() ?? 0.0,
      ),
      isEmergency: data['emergency'] as bool? ?? false,
      emergencyThreshold:
          (data['emergency_threshold'] as num?)?.toDouble() ?? 0.0,
      nav: data['nav'] as String?,
      timestamp: data['timestamp'] as Timestamp?,
    );
  }
}

extension DeviceStreamExtension on FirestoreService {
  Stream<DeviceData?> getDeviceStream(String deviceId) {
    return FirebaseFirestore.instance
        .collection('devices')
        .doc(deviceId)
        .snapshots()
        .map((snapshot) {
      if (snapshot.exists) {
        return DeviceData.fromFirestore(snapshot);
      }
      return null;
    });
  }
}

// --- Live Location Page Widget ---

class LiveLocationPage extends StatefulWidget {
  final String deviceId;

  const LiveLocationPage({super.key, required this.deviceId});

  @override
  State<LiveLocationPage> createState() => _LiveLocationPageState();
}

class _LiveLocationPageState extends State<LiveLocationPage>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final FirestoreService _firestoreService = FirestoreService();

  DeviceData? _deviceData;
  List<HelperMarker> _helpers = [];
  bool _isMapReady = false;

  StreamSubscription? _deviceSubscription;
  StreamSubscription? _helpersSubscription;

  late AnimationController _emergencyTextAnimController;
  late AnimationController _pulseAnimController;

  Timer? _emergencyTimer;
  Duration _emergencyDuration = Duration.zero;

  final GlobalKey _navInfoKey = GlobalKey();
  double _navInfoHeight = 0;

  @override
  void initState() {
    super.initState();
    _emergencyTextAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _pulseAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _listenToDeviceData();
    WidgetsBinding.instance.addPostFrameCallback((_) => _getNavInfoHeight());
  }

  @override
  void dispose() {
    _mapController.dispose();
    _deviceSubscription?.cancel();
    _helpersSubscription?.cancel();
    _emergencyTextAnimController.dispose();
    _pulseAnimController.dispose();
    _emergencyTimer?.cancel();
    super.dispose();
  }

  void _listenToDeviceData() {
    _deviceSubscription?.cancel();
    _deviceSubscription =
        _firestoreService.getDeviceStream(widget.deviceId).listen((deviceData) {
      if (!mounted || deviceData == null) return;
      final bool wasInEmergency = _deviceData?.isEmergency ?? false;
      setState(() {
        _deviceData = deviceData;
      });
      if (_isMapReady) {
        _centerMapOnDevice(animated: true);
      }
      if (deviceData.isEmergency) {
        if (!_pulseAnimController.isAnimating) {
          _pulseAnimController.repeat();
        }
        _startEmergencyTimer();
      } else {
        if (wasInEmergency) {
          _pulseAnimController.stop();
          _pulseAnimController.reset();
        }
        _stopEmergencyTimer();
      }
      _listenToHelpers(deviceData.id);
      WidgetsBinding.instance.addPostFrameCallback((_) => _getNavInfoHeight());
    });
  }

  void _getNavInfoHeight() {
    final RenderBox? renderBox =
        _navInfoKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && mounted) {
      setState(() {
        _navInfoHeight = renderBox.size.height;
      });
    }
  }

  void _listenToHelpers(String deviceId) {
    _helpersSubscription?.cancel();
    _helpersSubscription =
        _firestoreService.getHelpersStream(deviceId).listen((helpers) {
      if (mounted) {
        setState(() {
          _helpers = helpers;
        });
      }
    });
  }

  void _startEmergencyTimer() {
    _emergencyTimer?.cancel();
    _emergencyTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_deviceData?.timestamp != null) {
        final emergencyTime = _deviceData!.timestamp!.toDate();
        final now = DateTime.now();
        if (mounted) {
          setState(() {
            _emergencyDuration = now.difference(emergencyTime);
          });
        }
      }
    });
  }

  void _stopEmergencyTimer() {
    _emergencyTimer?.cancel();
    if (mounted) {
      setState(() {
        _emergencyDuration = Duration.zero;
      });
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$hours:$minutes:$seconds';
  }

  void _centerMapOnDevice({bool animated = false}) {
    if (_deviceData == null || !_isMapReady) return;
    final LatLng targetPosition = _deviceData!.position;
    double targetZoom;
    if (_deviceData!.isEmergency && _deviceData!.emergencyThreshold > 0) {
      const double metersPerPixelAtZoom0 = 156543.03392;
      final double mapWidth = MediaQuery.of(context).size.width;
      final double metersPerPixel =
          metersPerPixelAtZoom0 / math.pow(2, _mapController.camera.zoom);
      final double requiredPixels =
          _deviceData!.emergencyThreshold * 2 / metersPerPixel;
      if (requiredPixels > mapWidth * 0.8 || requiredPixels < mapWidth * 0.5) {
        targetZoom = math.log(mapWidth *
                metersPerPixelAtZoom0 /
                (_deviceData!.emergencyThreshold * 2 * 1.2)) /
            math.log(2);
        targetZoom = targetZoom.clamp(5.0, 18.0);
      } else {
        targetZoom = _mapController.camera.zoom;
      }
    } else {
      targetZoom = 16.0;
    }
    if (animated) {
      final latTween = Tween<double>(
          begin: _mapController.camera.center.latitude,
          end: targetPosition.latitude);
      final lngTween = Tween<double>(
          begin: _mapController.camera.center.longitude,
          end: targetPosition.longitude);
      final zoomTween =
          Tween<double>(begin: _mapController.camera.zoom, end: targetZoom);
      final animationController = AnimationController(
          vsync: this, duration: const Duration(milliseconds: 500));
      final animation =
          CurvedAnimation(parent: animationController, curve: Curves.easeInOut);
      animationController.addListener(() {
        _mapController.move(
          LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)),
          zoomTween.evaluate(animation),
        );
      });
      animation.addStatusListener((status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          animationController.dispose();
        }
      });
      animationController.forward();
    } else {
      _mapController.move(targetPosition, targetZoom);
    }
  }

  Future<void> _openInGoogleMaps() async {
    if (_deviceData == null) return;
    final lat = _deviceData!.position.latitude;
    final lng = _deviceData!.position.longitude;
    final url = 'https://www.google.com/maps/search/?api=1&query=$lat,$lng';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Google Maps.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _deviceData == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                _buildMap(),
                _buildEmergencyInfoPanel(),
                if (_deviceData?.isEmergency ?? false) _buildEmergencyTimer(),
                _buildNavigationInfoPanel(),
                _buildGpsFloatingButton(),
              ],
            ),
    );
  }

  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _deviceData!.position,
        initialZoom: _deviceData!.isEmergency &&
                _deviceData!.emergencyThreshold > 0
            ? _calculateInitialEmergencyZoom()
            : 16.0,
        minZoom: 5,
        maxZoom: 18,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onMapReady: () {
          setState(() => _isMapReady = true);
          _centerMapOnDevice();
        },
      ),
      children: [
        TileLayer(
          urlTemplate:
              "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png",
          subdomains: const ['a', 'b', 'c'],
        ),
        IgnorePointer(
          child: Container(
            color: const Color.fromARGB(255, 45, 138, 157).withOpacity(0.3),
          ),
        ),
        if (_deviceData!.isEmergency && _deviceData!.emergencyThreshold > 0)
          ..._buildEmergencyThresholdLayers(),
        _buildMarkersLayer(),
      ],
    );
  }

  double _calculateInitialEmergencyZoom() {
    if (_deviceData == null || _deviceData!.emergencyThreshold <= 0)
      return 16.0;
    const double metersPerPixelAtZoom0 = 156543.03392;
    final double mapWidth = MediaQuery.of(context).size.width;
    double zoom = math.log(mapWidth *
            metersPerPixelAtZoom0 /
            (_deviceData!.emergencyThreshold * 2 * 1.2)) /
        math.log(2);
    return zoom.clamp(5.0, 18.0);
  }

  List<Widget> _buildEmergencyThresholdLayers() {
    return [
      CircleLayer(
        circles: [
          CircleMarker(
            point: _deviceData!.position,
            radius: _deviceData!.emergencyThreshold,
            useRadiusInMeter: true,
            color: Colors.red.withOpacity(0.1),
            borderColor: Colors.red.withOpacity(0.5),
            borderStrokeWidth: 1.5,
          ),
        ],
      ),
      PulseCircleLayer(
        pulseController: _pulseAnimController,
        position: _deviceData!.position,
        emergencyThreshold: _deviceData!.emergencyThreshold,
      ),
    ];
  }

  MarkerLayer _buildMarkersLayer() {
    List<Marker> markers = [];
    markers.add(
      Marker(
        width: 80,
        height: 80,
        point: _deviceData!.position,
        child: GestureDetector(
          onTap: () => _centerMapOnDevice(animated: true),
          onLongPress: _openInGoogleMaps,
          child: LiveDeviceMarker(
            deviceData: _deviceData!,
          ),
        ),
      ),
    );
    if (_deviceData!.isEmergency) {
      for (final helper in _helpers) {
        markers.add(
          Marker(
            width: 65,
            height: 65,
            point: helper.position,
            child: ThemedHelperMarkerWidget(marker: helper),
          ),
        );
      }
    }
    return MarkerLayer(markers: markers);
  }

  Widget _buildEmergencyInfoPanel() {
    final bool isEmergency = _deviceData?.isEmergency ?? false;
    return Positioned(
      top: 70,
      left: 10,
      right: 10,
      child: isEmergency
          ? Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const ui.Color.fromARGB(0, 0, 0, 0).withOpacity(0.0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: FadeTransition(
                opacity: _emergencyTextAnimController,
                child: const Text(
                  'In Emergency!!!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ui.Color.fromARGB(171, 211, 55, 44),
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildEmergencyTimer() {
    return Positioned(
      bottom: 80,
      right: 10,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
  // Option 1: Concatenate strings
  "Time Elapsed: " +
  _formatDuration(_emergencyDuration),
  style: const TextStyle(
    color: ui.Color.fromARGB(230, 255, 255, 255),
    fontSize: 14,
    fontWeight: FontWeight.w400,
    fontFamily: 'monospace',
  ),
),
      ),
    );
  }

  Widget _buildNavigationInfoPanel() {
    final String? navText = _deviceData?.nav;
    final bool showNav = navText != null && navText.isNotEmpty;
    if (_deviceData?.isEmergency ?? false) {
      return const SizedBox.shrink();
    }
    return Positioned(
      bottom: 90,
      left: 10,
      right: 10,
      child: Container(
        key: _navInfoKey,
        child: showNav
            ? Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Currently navigating to: $navText',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: ui.Color.fromARGB(194, 176, 176, 176),
                    fontSize: 15,
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildGpsFloatingButton() {
    final double bottomPosition = 120 + (_navInfoHeight > 0 ? _navInfoHeight - 20 : 0);
    return Positioned(
      bottom: bottomPosition,
      right: 10,
      child: FloatingActionButton(
        heroTag: "focusHelpingDevice",
        mini: true,
        backgroundColor:
            const Color.fromARGB(208, 27, 73, 75).withOpacity(0.5),
        onPressed: () {
          _centerMapOnDevice(animated: true);
        },
        child: const Icon(Icons.my_location, color: Colors.white),
      ),
    );
  }
}

// --- Custom Marker Widgets ---
class LiveDeviceMarker extends StatelessWidget {
  final DeviceData deviceData;

  const LiveDeviceMarker({
    super.key,
    required this.deviceData,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.0),
            boxShadow: [
              BoxShadow(
                color: deviceData.isEmergency
                    ? Colors.red.withOpacity(0.5)
                    : Colors.black.withOpacity(0.3),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
          child: CircleAvatar(
            radius: 20,
            backgroundColor: Colors.black.withOpacity(0.5),
            backgroundImage: deviceData.profilePicUrl != null &&
                    deviceData.profilePicUrl!.isNotEmpty
                ? NetworkImage(deviceData.profilePicUrl!)
                : null,
            child: deviceData.profilePicUrl == null ||
                    deviceData.profilePicUrl!.isEmpty
                ? const Icon(Icons.person, color: Colors.white)
                : null,
          ),
        ),
      ],
    );
  }
}

class PulseCircleLayer extends StatelessWidget {
  final AnimationController pulseController;
  final LatLng position;
  final double emergencyThreshold;

  const PulseCircleLayer({
    Key? key,
    required this.pulseController,
    required this.position,
    required this.emergencyThreshold,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseController,
      builder: (context, child) {
        final double currentRadius =
            10.0 + (emergencyThreshold - 10.0) * pulseController.value;
        final double currentOpacity = 1.0 - pulseController.value;
        return CircleLayer(
          circles: [
            CircleMarker(
              point: position,
              radius: currentRadius.clamp(0.0, emergencyThreshold),
              useRadiusInMeter: true,
              color: Colors.red.withOpacity(currentOpacity * 0.2),
              borderColor: Colors.red.withOpacity(currentOpacity * 0.8),
              borderStrokeWidth: 2.0,
            ),
          ],
        );
      },
    );
  }
}

class DottedPulsePainter extends CustomPainter {
  final double progress;
  final Color color;

  DottedPulsePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;
    final currentRadius = maxRadius * progress;
    final paint = Paint()
      ..color = color.withOpacity(1.0 - (progress * 0.8))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    const double dashWidth = 5.0;
    const double dashSpace = 3.0;
    final path = ui.Path();
    for (double i = 0;
        i < 2 * 3.14159;
        i += (dashWidth + dashSpace) / currentRadius) {
      path.addArc(
        Rect.fromCircle(center: center, radius: currentRadius),
        i,
        dashWidth / currentRadius,
      );
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant DottedPulsePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class ThemedHelperMarkerWidget extends StatelessWidget {
  final HelperMarker marker;

  const ThemedHelperMarkerWidget({super.key, required this.marker});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(2),
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: ui.Color.fromARGB(66, 255, 255, 255),
                blurRadius: 4,
                offset: Offset(0, 2),
              )
            ],
          ),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: marker.role == HelperRole.active
                  ? Colors.blue.shade400
                  : Colors.grey.shade600,
              shape: BoxShape.circle,
            ),
            child: Icon(
              marker.role == HelperRole.active
                  ? Icons.directions_run
                  : Icons.visibility,
              color: Colors.white,
              size: 16,
            ),
          ),
        ),
        const SizedBox(height: 4),
        if (marker.status.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              marker.status,
              style: const TextStyle(color: Colors.white, fontSize: 10),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}