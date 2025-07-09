import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'help_page.dart';
import 'device_page.dart';
import 'radar_page.dart';
import 'animate_border2.dart';
import 'dart:io';
import 'dart:async';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  Set<String> _loggedInDevices = {};
  late TabController _tabController;
  Map<String, String> _deviceNames = {};
  bool notificationsEnabled = true;
  bool _isFullScreen = false;
  String? _deviceIdToFocusInRadar;
  double? _initialLatToFocusInRadar;
  double? _initialLonToFocusInRadar;

  // New state variables for emergency indicators
  bool _hasEmergency = false;
  late AnimationController _blinkAnimationController;
  late Animation<double> _blinkAnimation;
  Map<String, bool> _deviceEmergencyStatus = {}; // To store emergency status for each device

  StreamSubscription<QuerySnapshot>? _emergencyStatusSubscription;

  static const double kBottomButtonsHeight = 100.0;

  @override
  void initState() {
    super.initState();
    _loadLoggedInDevices();
    _tabController = TabController(length: 2, vsync: this);
    _loadNotificationSetting();

    _blinkAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
    _blinkAnimation = Tween(begin: 0.0, end: 1.0).animate(_blinkAnimationController);

    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        if (_tabController.index != 1) {
          setState(() {
            _deviceIdToFocusInRadar = null;
            _initialLatToFocusInRadar = null;
            _initialLonToFocusInRadar = null;
          });
        }
      }
    });

    _listenForEmergencyStatus(); // Start listening for emergencies
  }

  @override
  void dispose() {
    _tabController.dispose();
    _blinkAnimationController.dispose();
    _emergencyStatusSubscription?.cancel();
    super.dispose();
  }

  void _listenForEmergencyStatus() {
    _emergencyStatusSubscription?.cancel(); // Cancel previous subscription if any

    // Listen to changes in all devices to check for emergencies
    _emergencyStatusSubscription = FirebaseFirestore.instance
        .collection('devices')
        .snapshots()
        .listen((snapshot) {
      bool anyEmergency = false;
      Map<String, bool> currentEmergencyStatuses = {};

      for (var doc in snapshot.docs) {
        final deviceId = doc.id;
        final data = doc.data();
        final isEmergency = data['emergency'] == true;
        currentEmergencyStatuses[deviceId] = isEmergency;

        if (_loggedInDevices.contains(deviceId) && isEmergency) {
          anyEmergency = true;
        }
      }

      setState(() {
        _hasEmergency = anyEmergency;
        _deviceEmergencyStatus = currentEmergencyStatuses;
      });
    }, onError: (error) {
      print("Error listening for emergency status: $error");
    });
  }

  void _loadNotificationSetting() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      notificationsEnabled = prefs.getBool('notificationsEnabled') ?? true;
    });

    FlutterBackgroundService().invoke("setNotificationEnabled", {"enabled": notificationsEnabled});
  }

  void _toggleNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      notificationsEnabled = !notificationsEnabled;
      prefs.setBool('notificationsEnabled', notificationsEnabled);
    });

    FlutterBackgroundService().invoke("setNotificationEnabled", {"enabled": notificationsEnabled});
  }

  void _toggleFullScreen() {
    setState(() {
      _isFullScreen = !_isFullScreen;
    });
  }

  Future<void> _loadLoggedInDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> devicesList = prefs.getStringList('loggedInDevices') ?? [];

    Map<String, String> fetchedNames = {};

    for (String deviceId in devicesList) {
      final docSnapshot = await FirebaseFirestore.instance
          .collection('devices')
          .doc(deviceId)
          .get();
      if (docSnapshot.exists && docSnapshot.data()!.containsKey('ownerName')) {
        fetchedNames[deviceId] = docSnapshot.get('ownerName');
      } else {
        fetchedNames[deviceId] = 'Unnamed Device';
      }
    }

    setState(() {
      _loggedInDevices = devicesList.toSet();
      _deviceNames = fetchedNames;
    });

    // Re-evaluate emergency status after loading logged-in devices
    _listenForEmergencyStatus();
  }

  Future<void> _addLoggedInDevice(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _loggedInDevices.add(deviceId);
      prefs.setStringList('loggedInDevices', _loggedInDevices.toList());
    });

    final docSnapshot = await FirebaseFirestore.instance
        .collection('devices')
        .doc(deviceId)
        .get();
    if (docSnapshot.exists && docSnapshot.data()!.containsKey('ownerName')) {
      setState(() {
        _deviceNames[deviceId] = docSnapshot.get('ownerName');
      });
    } else {
      setState(() {
        _deviceNames[deviceId] = 'Unnamed Device';
      });
    }

    // Re-evaluate emergency status after adding a new device
    _listenForEmergencyStatus();
  }

  Future<void> _handleAccessDevice() async {
    if (_loggedInDevices.isEmpty) {
      _promptForNewDeviceLogin();
    } else if (_loggedInDevices.length == 1) {
      final deviceId = _loggedInDevices.first;
      if (mounted) {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => DevicePage(deviceId: deviceId)),
        );
        if (result == true) {
          _loadLoggedInDevices();
        }
      }
    } else {
      _showDeviceSelectionSheet();
    }
  }

  void _switchTab(int index, {String? deviceIdToFocus, double? initialLatitude, double? initialLongitude}) {
    setState(() {
      _deviceIdToFocusInRadar = deviceIdToFocus;
      _initialLatToFocusInRadar = initialLatitude;
      _initialLonToFocusInRadar = initialLongitude;
    });
    _tabController.animateTo(index);
    print('DEBUG: Switched to tab $index. Device to focus: $deviceIdToFocus');
  }

  Future<void> _showDeviceSelectionSheet() async {
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final double maxHeight = constraints.maxHeight * 0.5;

            return SafeArea(
              child: Container(
                constraints: BoxConstraints(maxHeight: maxHeight),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF21485D), Color(0xFF546767)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(
                      'Select Device',
                      style: GoogleFonts.robotoCondensed(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_loggedInDevices.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          'No devices logged in. Tap the + button to add one.',
                          style: TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      Expanded(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _loggedInDevices.length,
                          itemBuilder: (context, index) {
                            final deviceId = _loggedInDevices.elementAt(index);
                            final displayName = _deviceNames[deviceId] ?? 'Unnamed Device';
                            final hasEmergency = _deviceEmergencyStatus[deviceId] ?? false;

                            return Container(
                              margin: const EdgeInsets.symmetric(vertical: 4.0),
                              decoration: BoxDecoration(
                                color: const Color.fromARGB(32, 255, 255, 255),
                                borderRadius: BorderRadius.circular(15),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    spreadRadius: 1,
                                    blurRadius: 3,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: ListTile(
                                title: Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        displayName,
                                        style: GoogleFonts.robotoCondensed(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                      if (hasEmergency)
                                        FadeTransition(
                                          opacity: _blinkAnimation,
                                          child: const Padding(
                                            padding: EdgeInsets.only(left: 4.0),
                                            child: Icon(
                                              Icons.star,
                                              color: Colors.redAccent,
                                              size: 18,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                onTap: () async {
                                  Navigator.pop(context);
                                  final result = await Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (context) => DevicePage(deviceId: deviceId)),
                                  );
                                  if (result == true) {
                                    _loadLoggedInDevices();
                                  }
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 35,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color.fromARGB(32, 255, 255, 255),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              spreadRadius: 1,
                              blurRadius: 3,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 0),
                            foregroundColor: Colors.white70,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          child: Text(
                            'Close',
                            style: GoogleFonts.robotoCondensed(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((result) {
      if (result == true) {
        _loadLoggedInDevices();
      }
    });
  }

  Future<void> _promptForNewDeviceLogin() async {
    String? deviceId = await _showDeviceIdInputDialog(context);

    if (deviceId != null && deviceId.isNotEmpty) {
      if (await _checkDeviceIdInFirestore(deviceId)) {
        await _addLoggedInDevice(deviceId);

        final String displayName = _deviceNames[deviceId] ?? 'Unnamed Device';

        if (mounted) {
          _showSnackBar(context, 'Device "$displayName" logged in!');
          final result = await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => DevicePage(deviceId: deviceId)),
          );
          if (result == true) {
            _loadLoggedInDevices();
          }
        }
      } else {
        if (mounted) {
          _showSnackBar(context, 'Device ID not found in Firestore.');
        }
      }
    } else {
      if (mounted) {
        _showSnackBar(context, 'Invalid Device ID.');
      }
    }
  }

  Future<String?> _showDeviceIdInputDialog(BuildContext context) async {
    String? deviceIdInput;
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Enter Device ID'),
          content: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (value) {
                    deviceIdInput = value;
                  },
                  decoration: const InputDecoration(hintText: "Device ID"),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                onPressed: () async {
                  String? scannedId = await _scanQRCode(context);
                  if (scannedId != null) {
                    Navigator.of(context).pop(scannedId);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.image),
                onPressed: () async {
                  String? uploadedId = await _uploadQRCode(context);
                  if (uploadedId != null) {
                    Navigator.of(context).pop(uploadedId);
                  }
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop(null);
              },
            ),
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop(deviceIdInput);
              },
            ),
          ],
        );
      },
    );
  }

  Future<bool> _checkDeviceIdInFirestore(String deviceId) async {
    final docSnapshot = await FirebaseFirestore.instance
        .collection('devices')
        .doc(deviceId)
        .get();
    return docSnapshot.exists;
  }

  Future<String?> _scanQRCode(BuildContext context) async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      _showSnackBar(context, 'Camera permission denied');
      return null;
    }
    try {
      final scannedCode = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const QRScannerPage()),
      );
      return scannedCode;
    } catch (e) {
      _showSnackBar(context, 'Error during QR scan: $e');
      return null;
    }
  }

  Future<String?> _uploadQRCode(BuildContext context) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      try {
        final imageBytes = await pickedFile.readAsBytes();
        final tempDir = await getTemporaryDirectory();
        final tempPath = path.join(tempDir.path, 'temp_qr_image.png');
        final tempFile = File(tempPath);
        await tempFile.writeAsBytes(imageBytes);
        final controller = MobileScannerController();
        final result = await controller.analyzeImage(tempPath);
        controller.dispose();
        await tempFile.delete();

        if (result != null && result.barcodes.isNotEmpty) {
          return result.barcodes.first.rawValue;
        }
        return null;
      } catch (e) {
        print("Error decoding QR code: $e");
        _showSnackBar(context, 'Error decoding QR code: $e');
        return null;
      }
    }
    return null;
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final double topSafeArea = mediaQuery.padding.top;
    final double bottomSafeArea = mediaQuery.padding.bottom;

    const double kAppBarDefaultHeight = kToolbarHeight;
    const double kBottomButtonsDefaultPadding = 30.0;

    final double mainContainerHorizontalMarginNormal = mediaQuery.size.width * 0.1;
    final double mainContainerVerticalMarginNormal = 100.0;
    final double mainContainerHorizontalMarginFullScreen = 5.0;
    final double mainContainerVerticalMarginFullScreen = 5.0;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: const [
              Color.fromARGB(255, 33, 72, 93),
              Color.fromARGB(255, 25, 55, 79),
              Color.fromARGB(255, 84, 103, 103),
            ],
            stops: const [0.0, 0.46, 1.0],
          ),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              top: _isFullScreen
                  ? topSafeArea + mainContainerVerticalMarginFullScreen
                  : kAppBarDefaultHeight + topSafeArea + mainContainerVerticalMarginNormal - 50,
              bottom: _isFullScreen
                  ? bottomSafeArea + mainContainerVerticalMarginFullScreen
                  : kBottomButtonsHeight + bottomSafeArea + mainContainerVerticalMarginNormal - 30,
              left: _isFullScreen ? mainContainerHorizontalMarginFullScreen : mainContainerHorizontalMarginNormal-10,
              right: _isFullScreen ? mainContainerHorizontalMarginFullScreen : mainContainerHorizontalMarginNormal-10,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      spreadRadius: 3,
                      blurRadius: 7,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 15),
                    AnimatedBorderContainer(
                      borderColor: const Color.fromARGB(176, 49, 125, 140),
                      borderWidth: 10.0,
                      borderRadius: 15.0,
                      duration: const Duration(seconds: 8),
                      child: AnimatedGradientContainer(
                        child: Container(
                          height: 50,
                          width: 250,
                          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          padding: const EdgeInsets.all(6.0),
                          child: Center(
                            child: Text(
                              "Active Help Requests",
                              style: GoogleFonts.robotoCondensed(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: const Color.fromARGB(221, 27, 78, 74),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 15),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(width: _isFullScreen ? 100 : 70),
                        Container(
                          height: 35,
                          width: 120,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(25),
                          ),
                          child: TabBar(
                            controller: _tabController,
                            indicatorSize: TabBarIndicatorSize.tab,
                            indicator: BoxDecoration(
                              borderRadius: BorderRadius.circular(25),
                              color: Colors.white.withOpacity(0.3),
                            ),
                            labelColor: Colors.white,
                            unselectedLabelColor: Colors.white54,
                            dividerColor: Colors.transparent,
                            tabs: const [
                              Tab(icon: Icon(Icons.person_outline_rounded, size: 18)),
                              Tab(icon: Icon(Icons.radar_outlined, size: 18)),
                            ],
                          ),
                        ),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: _isFullScreen ? 45.0 : 15.0,
                          child: const SizedBox.shrink(),
                        ),
                        IconButton(
                          icon: Icon(
                            _isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                            color: Colors.white,
                          ),
                          onPressed: _toggleFullScreen,
                        ),
                      ],
                    ),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(10.0),
                        decoration: BoxDecoration(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(15.0),
                        ),
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            HelpPage(onSwitchTab: _switchTab),
                            RadarPage(
                              deviceIdToFocus: _deviceIdToFocusInRadar,
                              initialLatitude: _initialLatToFocusInRadar,
                              initialLongitude: _initialLonToFocusInRadar,
                              isFullScreen: _isFullScreen,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              top: _isFullScreen ? -(kAppBarDefaultHeight + topSafeArea) : 0.0,
              left: 0,
              right: 0,
              child: AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                actions: [
                  const SizedBox(width: 15),
                  IconButton(
                    icon: Icon(
                      notificationsEnabled
                          ? Icons.notifications
                          : Icons.notifications_off,
                      color: Colors.white,
                    ),
                    onPressed: _toggleNotifications,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.logout),
                    color: const Color.fromRGBO(255, 255, 255, 1),
                    onPressed: () {
                      SignOutIconButton().signOut();
                    },
                  ),
                  const SizedBox(width: 15),
                ],
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              bottom: _isFullScreen ? -(kBottomButtonsHeight + bottomSafeArea) : kBottomButtonsDefaultPadding,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 0.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: _handleAccessDevice,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                        foregroundColor: Colors.white,
                        shadowColor: Colors.black.withOpacity(0.4),
                        elevation: 8,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                        backgroundColor: Colors.transparent,
                      ).copyWith(
                        backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
                          if (states.contains(WidgetState.pressed)) {
                            return Colors.white.withOpacity(0.1);
                          }
                          return Colors.white.withOpacity(0.2);
                        }),
                        overlayColor: WidgetStateProperty.all(Colors.transparent),
                        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _loggedInDevices.isEmpty ? "Login to Device" : "Access Device(s)",
                            style: const TextStyle(fontSize: 18),
                          ),
                          if (_hasEmergency)
                            FadeTransition(
                              opacity: _blinkAnimation,
                              child: const Padding(
                                padding: EdgeInsets.only(left: 8.0),
                                child: Icon(
                                  Icons.star,
                                  color: Colors.redAccent,
                                  size: 20,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_loggedInDevices.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8.0),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.15),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.add, color: Colors.white),
                            onPressed: _promptForNewDeviceLogin,
                            tooltip: 'Add new device',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SignOutIconButton extends StatelessWidget {
  const SignOutIconButton({super.key});

  Future<void> signOut() async {
    try {
      await FirebaseAuth.instance.signOut();

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('loggedInDevices');
    } catch (e) {
      print("Error signing out: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

class AnimatedGradientContainer extends StatefulWidget {
  final Widget child;

  const AnimatedGradientContainer({super.key, required this.child});

  @override
  _AnimatedGradientContainerState createState() =>
      _AnimatedGradientContainerState();
}

class _AnimatedGradientContainerState extends State<AnimatedGradientContainer>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _offsetAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    _offsetAnimation = Tween<double>(
      begin: -0.3,
      end: 0.3,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: _offsetAnimation,
        builder: (context, child) {
          return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    spreadRadius: 5,
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  gradient: LinearGradient(
                    begin: Alignment(_offsetAnimation.value - 0.5, 0.0),
                    end: Alignment(_offsetAnimation.value + 0.5, 0.0),
                    colors: const [
                      Color.fromARGB(255, 207, 212, 212),
                      Color.fromRGBO(255, 255, 255, 1),
                      Color.fromARGB(255, 207, 212, 212),
                    ],
                  ),
                ),
                child: widget.child));
        });
  }
}

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({super.key});

  @override
  _QRScannerPageState createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  late MobileScannerController controller;

  @override
  void initState() {
    super.initState();
    controller = MobileScannerController();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  bool _hasScanned = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: MobileScanner(
        controller: controller,
        onDetect: (capture) {
          if (_hasScanned) return;
          final List<Barcode> barcodes = capture.barcodes;
          if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
            _hasScanned = true;
            Navigator.of(context).pop(barcodes.first.rawValue);
          }
        },
      ),
    );
  }
}