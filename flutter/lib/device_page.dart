import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'centered_scrolling_list.dart';
import 'tag_page.dart';
import '../constants/country_codes.dart';
import 'package:flutter/services.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:async';
import 'live_location_page.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

class DevicePage extends StatefulWidget {
  final String deviceId;

  const DevicePage({super.key, required this.deviceId});

  @override
  _DevicePageState createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> with TickerProviderStateMixin {
  String? _ownerName;
  List<Map<String, dynamic>> _contacts = [];
  bool _isLoading = true;
  String? _errorMessage;
  late TextEditingController _ownerNameController;
  bool _editProfile = false;
  int _selectedIndex = 0;
  String countryCode = '+91';
  String tempName = '';
  String tempPhone = '';
  bool _isEditingOwnerName = false;
  String _selectedLanguage = 'en';
  late PageController _pageController;
  String? _profilePicUrl;
  bool _isDeviceInEmergency = false;
  late Animation<Color?> _blinkAnimation;

late AnimationController _blinkAnimationController;


StreamSubscription<DocumentSnapshot>? _deviceEmergencySubscription;

@override
void initState() {
  super.initState();
  _ownerNameController = TextEditingController();
  _fetchDeviceData();
  _pageController = PageController(initialPage: _selectedIndex);

  _blinkAnimationController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  // This animation will always go from grey to red
  _blinkAnimation = ColorTween(begin: Colors.grey, end: Colors.red).animate(_blinkAnimationController); // Modified
  _listenForDeviceEmergencyStatus();
}


  Future<void> _fetchDeviceData() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('devices')
          .doc(widget.deviceId)
          .get();
      if (doc.exists) {
        if (mounted) {
          setState(() {
            _ownerName = doc.data()?['ownerName'] as String?;
            _contacts = (doc.data()?['contacts'] as List<dynamic>?)
                    ?.map((contact) => {
                          'contact_name': contact['contact_name'] ?? 'xxxx',
                          'phone_no': contact['phone_no'] ?? 'xxxx',
                        })
                    .toList() ??
                [];
            _selectedLanguage = doc.data()?['lang'] ?? 'en';
            _profilePicUrl = doc.data()?['profilePic'] as String?;
            _isLoading = false;
            _ownerNameController.text = _ownerName ?? '';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = 'Device not found.';
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to fetch device data: $e';
          _isLoading = false;
        });
      }
    }
  }

  void _listenForDeviceEmergencyStatus() {
  _deviceEmergencySubscription?.cancel();
  _deviceEmergencySubscription = FirebaseFirestore.instance
      .collection('devices')
      .doc(widget.deviceId)
      .snapshots()
      .listen((snapshot) {
    if (snapshot.exists && snapshot.data() != null) {
      final data = snapshot.data()!;
      final isEmergency = data['emergency'] == true;
      if (_isDeviceInEmergency != isEmergency) {
        setState(() {
          _isDeviceInEmergency = isEmergency;
        });
      }
    } else {
      if (_isDeviceInEmergency) {
        setState(() {
          _isDeviceInEmergency = false;
        });
      }
    }
  }, onError: (error) {
    print("Error listening for device emergency status: $error");
  });
}

  Future<void> _updateDeviceLanguage(String languageCode) async {
    try {
      await FirebaseFirestore.instance
          .collection('devices')
          .doc(widget.deviceId)
          .update({'lang': languageCode});
      print('Language updated to $languageCode');
    } catch (e) {
      print('Error updating language: $e');
      _showSnackBar(context, 'Failed to update language: $e');
    }
  }

  Future<void> _pickAndUploadImage() async {
    if (!_editProfile) return;

    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);

    if (image != null) {
      if (mounted) {
        setState(() {
          _isLoading = true;
        });
      }
      try {
        File file = File(image.path);
        final storageRef = FirebaseStorage.instance
            .ref()
            .child('profile_pictures/${widget.deviceId}/profile_pic.jpg');

        await storageRef.putFile(file);
        final downloadURL = await storageRef.getDownloadURL();

        await FirebaseFirestore.instance
            .collection('devices')
            .doc(widget.deviceId)
            .update({'profilePic': downloadURL});

        if (mounted) {
          setState(() {
            _profilePicUrl = downloadURL;
            _isLoading = false;
          });
        }
        _showSnackBar(context, 'Profile picture updated successfully!');
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        _showSnackBar(context, 'Failed to upload profile picture: $e');
        print('Error uploading profile picture: $e');
      }
    } else {
      _showSnackBar(context, 'No image selected.');
    }
  }
Future<void> _logout(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  
  List<String> loggedInDevices = prefs.getStringList('loggedInDevices') ?? [];
  loggedInDevices.remove(widget.deviceId); 

  await prefs.setStringList('loggedInDevices', loggedInDevices);
  if (mounted) { // Check if the widget is still in the tree before popping
    Navigator.pop(context, true); // Pass 'true' as a result
  }
}

  Future<void> _updateDeviceData() async {
    try {
      await FirebaseFirestore.instance
          .collection('devices')
          .doc(widget.deviceId)
          .update({
        'ownerName': _ownerName,
        'contacts': _contacts,
      });
      _showSnackBar(context, 'Device data updated successfully.');
    } catch (e) {
      _showSnackBar(context, 'Failed to update device data: $e');
    }
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _updateOwnerName(String newName) async {
    try {
      await FirebaseFirestore.instance
          .collection('devices')
          .doc(widget.deviceId)
          .update({'ownerName': newName});

      if (mounted) {
        setState(() {
          _ownerName = newName;
        });
      }
      print('Owner name updated successfully to: $newName');
    } catch (e) {
      print('Error updating owner name: $e');
    }
  }

  Future<String?> showCountryCodePicker(BuildContext context) async {
    TextEditingController searchController = TextEditingController();
    List<Map<String, String>> filteredCodes = List.from(countryCodes);

    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text("Select Country Code"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: searchController,
                    onChanged: (value) {
                      setState(() {
                        filteredCodes = countryCodes
                            .where((code) => code['name']!
                                .toLowerCase()
                                .contains(value.toLowerCase()))
                            .toList();
                      });
                    },
                    decoration: const InputDecoration(
                      hintText: "Search country",
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 200,
                    width: 300,
                    child: ListView.builder(
                      itemCount: filteredCodes.length,
                      itemBuilder: (context, index) {
                        return ListTile(
                          title: Text(
                              "${filteredCodes[index]['name']} (${filteredCodes[index]['code']})"),
                          onTap: () {
                            Navigator.pop(
                                context, filteredCodes[index]['code']);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Map<String, String> splitPhoneNumber(String fullNumber) {
    for (var code in countryCodes.map((e) => e['code']!)) {
      if (fullNumber.startsWith(code)) {
        return {
          'code': code,
          'number': fullNumber.substring(code.length),
        };
      }
    }
    // fallback
    return {
      'code': '+91',
      'number': fullNumber,
    };
  }

  Future<void> _addContact(BuildContext context) async {
    String tempName = '';
    String tempPhone = '';
    String countryCode = '+91';

    Map<String, String>? newContact = await showDialog<Map<String, String>>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Add Contact'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    onChanged: (value) {
                      tempName = value.trim();
                    },
                    decoration: const InputDecoration(hintText: "Contact Name"),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () async {
                          final selectedCode =
                              await showCountryCodePicker(context);
                          if (selectedCode != null) {
                            setState(() {
                              countryCode = selectedCode;
                            });
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(countryCode),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          keyboardType: TextInputType.number,
                          maxLength: 10,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          onChanged: (value) {
                            tempPhone = value.trim();
                          },
                          decoration: const InputDecoration(
                            hintText: "Phone Number",
                            counterText: '', // hides 0/10 below the field
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('OK'),
                  onPressed: () {
                    Navigator.of(context).pop({
                      'contact_name': tempName,
                      'phone_no': '$countryCode$tempPhone',
                    });
                  },
                ),
              ],
            );
          },
        );
      },
    );

    if (newContact != null &&
        newContact['contact_name']!.isNotEmpty &&
        newContact['phone_no']!.isNotEmpty) {

      final exists = _contacts.any((contact) =>
          contact['contact_name'] == newContact['contact_name'] ||
          contact['phone_no'] == newContact['phone_no']);

      if (exists) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text("Duplicate Found"),
            content: const Text("Name or phone number already exists."),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("OK"),
              ),
            ],
          ),
        );
        return;
      }

      setState(() {
        _contacts.add(newContact);
      });
      _updateDeviceData();
    }
  }

  Future<void> _deleteContact(BuildContext context, int index) async {
    if (!_editProfile) return;
    setState(() {
      _contacts.removeAt(index);
    });
    _updateDeviceData();
  }

  Future<void> _editContact(BuildContext context, int index) async {
    if (!_editProfile) return;

    final Map<String, String> split =
        splitPhoneNumber(_contacts[index]['phone_no']);
    final TextEditingController nameController =
        TextEditingController(text: _contacts[index]['contact_name']);
    final TextEditingController phoneController =
        TextEditingController(text: split['number']!);
    String countryCode = split['code']!;

    Map<String, String>? updatedContact = await showDialog<Map<String, String>>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Edit Contact'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(hintText: "Contact Name"),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () async {
                          final selectedCode =
                              await showCountryCodePicker(context);
                          if (selectedCode != null) {
                            setState(() {
                              countryCode = selectedCode;
                            });
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(countryCode),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          keyboardType: TextInputType.number,
                          maxLength: 10,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          controller: phoneController,
                          decoration: const InputDecoration(
                            hintText: "Phone Number",
                            counterText: '', // 🔥 hides 0/10 below
                            contentPadding: EdgeInsets.symmetric(
                                vertical: 12, horizontal: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('OK'),
                  onPressed: () {
                    Navigator.of(context).pop({
                      'contact_name': nameController.text.trim(),
                      'phone_no': '$countryCode${phoneController.text.trim()}',
                    });
                  },
                ),
              ],
            );
          },
        );
      },
    );

    if (updatedContact != null) {
      setState(() {
        _contacts[index] = updatedContact;
      });
    }
  }

  // Function to handle sharing
  Future<void> _shareProfile() async {
  final String deviceId = widget.deviceId; // Get the device ID
  final String ownerName = _ownerName ?? 'my device';

  // 1. Generate the QR code as a ByteData
  final qrPainter = QrPainter(
    data: deviceId, // Data to encode in the QR code
    version: QrVersions.auto,
    gapless: true,
    color: const Color.fromARGB(255, 255, 255, 255),
    emptyColor: Colors.black
  );

  // Render the QR code to an image
  // Use toImage from qr_flutter_new
  final ui.Image qrImage = await qrPainter.toImage(200); // Specify a size (e.g., 200 pixels)
  final ByteData? byteData = await qrImage.toByteData(format: ui.ImageByteFormat.png);

  if (byteData != null) {
    // 2. Save the QR code image to a temporary file
    final tempDir = await getTemporaryDirectory();
    final qrImagePath = '${tempDir.path}/device_id_qr.png';
    final File qrFile = await File(qrImagePath).writeAsBytes(byteData.buffer.asUint8List());

    // 3. Prepare the message
    final String message = "Stay in touch with $ownerName!\n"
                           "Device ID: $deviceId\n\n"
                           "Upload the QR code to the app to connect.";

    // 4. Share the message and the QR code image
    await Share.shareXFiles(
      [XFile(qrFile.path)], // Share the image file
      text: message,
      subject: "Connect with $ownerName",
    );
  } else {
    // Handle the case where QR code generation fails
    print("Failed to generate QR code.");
    // Optionally, share just the text if QR generation fails
    await Share.share(
      "Stay in touch with $ownerName! Device ID: $deviceId",
      subject: "Connect with $ownerName"
    );
  }
}
  
  
  @override
void dispose() {
  _ownerNameController.dispose();
  _pageController.dispose();
  _deviceEmergencySubscription?.cancel(); // <-- Add this line
  _blinkAnimationController.dispose(); // <-- Add this line
  super.dispose();
}

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_errorMessage != null) {
      return Scaffold(body: Center(child: Text(_errorMessage!)));
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      extendBody: true,
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 0.0,
        backgroundColor: const Color.fromARGB(0, 44, 76, 89),
        title: _editProfile
            ? TextField(
                controller: _ownerNameController,
                onChanged: (newValue) {
                  _ownerName = newValue;
                },
                onSubmitted: (newValue) {
                  _updateOwnerName(newValue);
                  FocusScope.of(context).unfocus();
                  setState(() {
                    _isEditingOwnerName = false;
                  });
                },
                style: const TextStyle(
                    color: Color.fromARGB(255, 255, 255, 255), fontSize: 18),
                cursorColor: Colors.white,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  focusedBorder: UnderlineInputBorder(
                    borderSide:
                        BorderSide(color: Colors.white.withOpacity(0.7)),
                  ),
                  enabledBorder: UnderlineInputBorder(
                    borderSide:
                        BorderSide(color: Colors.white.withOpacity(0.5)),
                  ),
                ),
              )
            : GestureDetector(
                onTap: () {
                  setState(() {
                    _isEditingOwnerName = true;
                  });
                  _ownerNameController.text = _ownerName ??'';
                  _ownerNameController.selection = TextSelection.fromPosition(
                    TextPosition(offset: _ownerNameController.text.length),
                  );
                },
                child: Text(
                  _ownerName!,
                  style: const TextStyle(
                      color: Color.fromARGB(255, 255, 255, 255), fontSize: 19),
                ),
              ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.share, color: Colors.white), // Share icon
                  onPressed: _shareProfile, // Share functionality
                ),
                IconButton(
                  icon: const Icon(Icons.logout, color: Colors.white),
                  onPressed: () {
                    _logout(context);
                  },
                )
              ],
            ),
          ),
        ],
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
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
        child: PageView(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            physics: const NeverScrollableScrollPhysics(),
            children: [
              LayoutBuilder(
                builder:
                    (BuildContext context, BoxConstraints viewportConstraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: viewportConstraints.maxHeight,
                        ),
                        child: IntrinsicHeight(
                            child: Center(
                                child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                              Column(
                                children: [
                                  const SizedBox(height: 80),

                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      SizedBox(width:40),
                                      Text('Device ID: ${widget.deviceId}',
                                          style: const TextStyle(
                                              color: Color.fromARGB(
                                                  255, 255, 255, 255))),
                                                  SizedBox(width:5),
                                                       Switch(
                  value: _editProfile,
                  onChanged: (value) {
                    setState(() {
                      _editProfile = value;
                      if (!value && _ownerName != null) {
                        _updateOwnerName(_ownerName!);
                      }
                    });
                  },
                  activeColor: const Color.fromARGB(0, 38, 134, 203),
                  inactiveTrackColor:
                      const Color.fromARGB(255, 255, 255, 255).withOpacity(0),
                  inactiveThumbColor: const Color.fromARGB(255, 255, 255, 255),
                ),
                                    ],
                                  ),

                                  const SizedBox(height: 10),
                                  GestureDetector(
                                    onTap: _editProfile
                                        ? _pickAndUploadImage
                                        : null,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        GestureDetector(
                                          onTap: () {
                                            if (_profilePicUrl != null &&
                                                _profilePicUrl!.isNotEmpty) {
                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (context) =>
                                                      FullScreenImagePage(
                                                          imageUrl:
                                                              _profilePicUrl!),
                                                ),
                                              );
                                            }
                                          },
                                          child: Hero(
                                            // Wrap CircleAvatar with Hero as well
                                            tag:
                                                'profilePic', // Same tag as in FullScreenImagePage
                                            child: CircleAvatar(
                                              radius: 60,
                                              backgroundColor:
                                                  Colors.white.withOpacity(0.2),
                                              backgroundImage: _profilePicUrl !=
                                                          null &&
                                                      _profilePicUrl!.isNotEmpty
                                                  ? NetworkImage(
                                                          _profilePicUrl!)
                                                      as ImageProvider<Object>?
                                                  : null,
                                              child: _profilePicUrl == null ||
                                                      _profilePicUrl!.isEmpty
                                                  ? Icon(
                                                      Icons.person,
                                                      size: 80,
                                                      color: Colors.white
                                                          .withOpacity(0.7),
                                                    )
                                                  : null,
                                            ),
                                          ),
                                        ),
                                        if (_editProfile)
                                          Positioned(
                                            bottom: 0,
                                            right: 0,
                                            child: CircleAvatar(
                                              radius: 20,
                                              backgroundColor:
                                                  const Color.fromARGB(
                                                      166, 38, 134, 203),
                                              child: Icon(
                                                Icons.camera_alt,
                                                color: Colors.white,
                                                size: 20,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 10),

                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Text(
                                        "Language: ",
                                        style: TextStyle(
                                            color: Colors.white, fontSize: 15),
                                      ),
                                      Container(
                                        margin: const EdgeInsets.only(top: 8),
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          border: Border.all(
                                              color: Colors.white
                                                  .withOpacity(0.3)),
                                        ),
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                              maxWidth: 120),
                                          child: DropdownButton<String>(
                                            value:
                                                _selectedLanguage, // Make sure _selectedLanguage is defined
                                            items: const <DropdownMenuItem<
                                                String>>[
                                              DropdownMenuItem<String>(
                                                value: 'en-IN',
                                                child: Text('    English (in)'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'en-US',
                                                child: Text('    English (us)'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'es-US',
                                                child: Text('    Spanish'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'de-DE',
                                                child: Text('    German'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'fr-FR',
                                                child: Text('    French'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'hi-IN',
                                                child: Text('    Hindi'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'pt-BR',
                                                child: Text('    Portuguese'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'ar-XA',
                                                child: Text('    Arabic'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'es-ES',
                                                child: Text('    Spanish'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'fr-CA',
                                                child: Text('    French'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'id-ID',
                                                child: Text('    Indonesian'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'it-IT',
                                                child: Text('    Italian'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'ja-JP',
                                                child: Text('    Japanese'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'tr-TR',
                                                child: Text('    Turkish'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'vi-VN',
                                                child: Text('    Vietnamese'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'bn-IN',
                                                child: Text('    Bengali'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'gu-IN',
                                                child: Text('    Gujarati'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'kn-IN',
                                                child: Text('    Kannada'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'ml-IN',
                                                child: Text('    Malayalam'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'mr-IN',
                                                child: Text('    Marathi'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'ta-IN',
                                                child: Text('    Tamil'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'te-IN',
                                                child: Text('    Telugu'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'nl-BE',
                                                child: Text('    Dutch'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'ko-KR',
                                                child: Text('    Korean'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'cmn-CN',
                                                child: Text('    Mandarin'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'pl-PL',
                                                child: Text('    Polish'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'ru-RU',
                                                child: Text('    Russian'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'sw-KE',
                                                child: Text('    Swahili'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'th-TH',
                                                child: Text('    Thai'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'ur-IN',
                                                child: Text('    Urdu'),
                                              ),
                                              DropdownMenuItem<String>(
                                                value: 'uk-UA',
                                                child: Text('    Ukrainian'),
                                              ),
                                            ],
                                            onChanged: (String? newValue) {
                                              if (newValue != null) {
                                                _updateDeviceLanguage(newValue);
                                              }
                                            },
                                            dropdownColor: const Color.fromARGB(
                                                    208, 47, 72, 79)
                                                .withOpacity(1),
                                            style: const TextStyle(
                                                color: Colors.white),
                                            icon: const Icon(
                                                Icons.arrow_drop_down,
                                                color: Colors.white),
                                            underline: Container(),
                                            isExpanded: true,
                                            menuMaxHeight: 200,
                                            alignment: AlignmentDirectional
                                                .centerStart,
                                            borderRadius:
                                                BorderRadius.circular(20),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Text("Contacts:-",
                                      style: TextStyle(
                                          color: Color.fromARGB(
                                              255, 255, 255, 255),
                                          fontSize: 25)),
                                  if (_editProfile)
                                    IconButton(
                                      onPressed: () => _addContact(context),
                                      icon: CircleAvatar(
                                        radius: 15,
                                        backgroundColor: const Color.fromARGB(
                                            166, 38, 134, 203),
                                        child: const Icon(
                                          Icons.add,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              Container(
                                height: 300,
                                width: 300,
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 10),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: const Color.fromARGB(
                                        107, 132, 167, 187),
                                    width: 4.0,
                                  ),
                                  borderRadius: BorderRadius.circular(10.0),
                                ),
                                child: CenteredScrollingList(
                                  contacts: _contacts,
                                  onDelete: (index) =>
                                      _deleteContact(context, index),
                                  onEdit: (index) =>
                                      _editContact(context, index),
                                  editMode: _editProfile,
                                ),
                              ),
                              SizedBox(height: 60)
                            ])))),
                  );
                },
              ),
              TagPage(deviceId: widget.deviceId),
              LiveLocationPage(deviceId: widget.deviceId),
            ]),
      ),
      bottomNavigationBar: Container(
        color: const Color.fromARGB(0, 0, 0, 0),
        child: BottomNavigationBar(
          backgroundColor: const Color.fromARGB(94, 17, 49, 60),
          items: <BottomNavigationBarItem>[
            BottomNavigationBarItem(
              icon: Icon(Icons.person),
              label: 'Contacts',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.local_offer),
              label: 'Tags',
            ),
            BottomNavigationBarItem(
  icon: _isDeviceInEmergency
      ? AnimatedBuilder(
          animation: _blinkAnimation,
          builder: (context, child) {
            // If selected, blink between white and red.
            // If not selected, blink between grey and red.
            // We achieve this by blending the animation color with the selected/unselected color.
            final Color baseColor = _selectedIndex == 2 ? Colors.white : Colors.grey;
            // Linearly interpolate between the base color and red based on the animation value.
            // When animation value is at its begin (grey), it will be baseColor.
            // When animation value is at its end (red), it will be red.
            return Icon(
              Icons.gps_fixed,
              color: Color.lerp(baseColor, Colors.red, _blinkAnimation.value!.red / 255),
            );
          },
        )
      : Icon(
          Icons.gps_fixed,
          // Set color based on selection when not in emergency
          color: _selectedIndex == 2 ? Colors.white : Colors.grey,
        ),
  label: 'Live location',
),
          ],
          currentIndex: _selectedIndex,
          selectedItemColor: const Color.fromARGB(255, 255, 255, 255),
          onTap: (int index) {
            setState(() {
              _selectedIndex = index;
            });
            _pageController.animateToPage(
              index,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          },
        ),
      ),
    );
  }
}

class FullScreenImagePage extends StatelessWidget {
  final String imageUrl;

  const FullScreenImagePage({super.key, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          Colors.black, // A dark background for the full-screen image
      body: GestureDetector(
        onTap: () {
          Navigator.pop(
              context); // Pop the current route when tapped to go back
        },
        child: Center(
          child: Hero(
            // Use Hero for a smooth animation
            tag: 'profilePic', // Unique tag for the Hero animation
            child: Image.network(
              imageUrl,
              fit: BoxFit.contain, // Ensure the image fits within the screen
            ),
          ),
        ),
      ),
    );
  }
}