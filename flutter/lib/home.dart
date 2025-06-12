import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ocular_sensus/device_page.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'help_page.dart'; 
import 'dart:io';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? savedDeviceId;
  bool deviceIdStored = false;
  bool notificationsEnabled = true;

  

  @override
  void initState() {
    super.initState();
    _loadDeviceId();
    _loadNotificationSetting();
    
  }

  @override
  void dispose() {
    
    super.dispose();
  }

  void _loadNotificationSetting() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      notificationsEnabled = prefs.getBool('notificationsEnabled') ?? true;
    });
  }

  void _toggleNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      notificationsEnabled = !notificationsEnabled;
      prefs.setBool('notificationsEnabled', notificationsEnabled);
    });
  }

  Future<void> _loadDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    savedDeviceId = prefs.getString('deviceId');
    if (mounted) {
      if (savedDeviceId != null && savedDeviceId!.isNotEmpty) {
        deviceIdStored = true;
      }
      setState(() {});
    }
  }

  

  Future<void> _saveDeviceId(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('deviceId', deviceId);
    if (mounted) {
      savedDeviceId = deviceId;
      deviceIdStored = true;
      setState(() {});
    }
  }

  Future<void> _navigateToDevicePage(BuildContext context) async {
    print("Starting _navigateToDevicePage");

    if (!mounted) {
      print("Context not mounted before getting device ID.");
      return;
    }

    if (!deviceIdStored) {
      String? deviceId = await _getDeviceId(context);
      print("deviceId after _getDeviceId: $deviceId");

      if (deviceId != null && deviceId.isNotEmpty) {
        if (await _checkDeviceIdInFirestore(deviceId)) {
          await _saveDeviceId(deviceId);
          print("deviceId after _saveDeviceId: $deviceId");

          if (mounted) {
            print("Navigating immediately after saving deviceId");
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => DevicePage(deviceId: savedDeviceId!),
              ),
            );
            return;
          }
        } else {
          if (mounted) {
            _showSnackBar(context, 'Device ID not found in Firestore.');
          } else {
            print("context not mounted");
          }
        }
      } else {
        if (mounted) {
          _showSnackBar(context, 'Invalid Device ID.');
        } else {
          print("context not mounted");
        }
      }
    }

    if (deviceIdStored && mounted) {
      print("mounted: $mounted");
      print("Navigating with deviceId: $savedDeviceId");
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => DevicePage(deviceId: savedDeviceId!),
        ),
      );
    }
  }

  Future<String?> _getDeviceId(BuildContext context) async {
    String? deviceId;
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
                    deviceId = value;
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
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop(deviceId);
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

        print("Result type: ${result.runtimeType}");
        print("Result is null: ${result == null}");
        print("Controller: ${controller.toString()}");

        if (result != null) {
          if (result.barcodes.isNotEmpty) {
            return result.barcodes.first.rawValue;
          }
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
    return Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.fromARGB(255, 33, 72, 93),
                  Color.fromARGB(255, 25, 55, 79),
                  Color.fromARGB(255, 84, 103, 103),
                ],
                stops: [0.0, 0.46, 1.0],
              ),
            ),
            child: Column(
              children: [
                AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  actions: [
                    IconButton(
                      icon: Icon(
                        notificationsEnabled
                            ? Icons.notifications
                            : Icons.notifications_off,
                        color: Colors.white,
                      ),
                      onPressed: _toggleNotifications,
                    ),
                    const SizedBox(width: 230),
                    IconButton(
                      icon: const Icon(Icons.logout),
                      color: Color.fromRGBO(255, 255, 255, 1),
                      onPressed: () {
                        SignOutIconButton().signOut();
                      },
                    ),
                    const SizedBox(width: 20),
                  ],
                ),
                
                Expanded(
                  child: Center(
                      child: Container(
                    decoration: BoxDecoration(
                      color: Color.fromARGB(32, 255, 255, 255),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          spreadRadius: 3,
                          blurRadius: 7,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    height: 450,
                    width: 300,
                    margin: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                    child: Column(
                      children: [
                        SizedBox(height: 15),
                        AnimatedGradientContainer(
                          child: Container(
                            height: 70,
                            width: 250,
                            margin: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                            padding: const EdgeInsets.all(16.0),
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
                        Expanded(
                          child: HelpPage(),
                        ),
                      ],
                    ),
                  )),
                ),
                ElevatedButton(
                  onPressed: () => _navigateToDevicePage(context),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 12),
                    foregroundColor: Colors.white,
                    shadowColor: Colors.black.withOpacity(0.4),
                    elevation: 8,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    backgroundColor: Colors.transparent,
                  ).copyWith(
                    backgroundColor:
                        MaterialStateProperty.resolveWith<Color>((states) {
                      if (states.contains(MaterialState.pressed)) {
                        return Colors.white.withOpacity(0.1);
                      }
                      return Colors.white.withOpacity(0.2);
                    }),
                    overlayColor: MaterialStateProperty.all(Colors.transparent),
                    surfaceTintColor:
                        MaterialStateProperty.all(Colors.transparent),
                  ),
                  child: Text(
                    deviceIdStored ? "Access Device" : "Connect to Device",
                    style: TextStyle(fontSize: 18),
                  ),
                ),
                SizedBox(height: 30),
              ],
            )));
  }
}

class SignOutIconButton extends StatelessWidget {
  const SignOutIconButton({super.key});

  Future<void> signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
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

  const AnimatedGradientContainer({Key? key, required this.child})
      : super(key: key);

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
      duration: const Duration(seconds: 5),
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
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    spreadRadius: 4,
                    blurRadius: 10,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(35),
                    gradient: LinearGradient(
                      begin: Alignment(_offsetAnimation.value - 0.5, 0.0),
                      end: Alignment(_offsetAnimation.value + 0.5, 0.0),
                      colors: const [
                        Color.fromARGB(255, 224, 228, 228),
                        Color.fromRGBO(255, 255, 255, 1),
                        Color.fromARGB(255, 224, 228, 228),
                      ],
                    ),
                  ),
                  child: widget.child));
        });
  }
}

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({Key? key}) : super(key: key);

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