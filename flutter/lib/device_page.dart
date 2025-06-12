import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'centered_scrolling_list.dart';
import 'package:permission_handler/permission_handler.dart';
import 'home.dart';


import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io'; 

class DevicePage extends StatefulWidget {
  final String deviceId;

  const DevicePage({super.key, required this.deviceId});

  @override
  _DevicePageState createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  String? _ownerName;
  List<Map<String, dynamic>> _contacts = [];
  bool _isLoading = true;
  String? _errorMessage;
  late TextEditingController _ownerNameController;
  bool _editProfile = false;
  int _selectedIndex = 0;
  bool _isEditingOwnerName = false;
  String _selectedLanguage = 'en';
  late PageController _pageController;
  String? _profilePicUrl;

  @override
  void initState() {
    super.initState();
    _ownerNameController = TextEditingController();
    _fetchDeviceData();
    _pageController = PageController(initialPage: _selectedIndex);
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
    await prefs.remove('deviceId');
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const HomeScreen()),
    );
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _addContact(BuildContext context) async {
    String tempName = '';
    String tempPhone = '';
    Map<String, String>? newContact = await showDialog<Map<String, String>>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Add Contact'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                onChanged: (value) {
                  tempName = value;
                },
                decoration: const InputDecoration(hintText: "Contact Name"),
              ),
              TextField(
                onChanged: (value) {
                  tempPhone = value;
                },
                decoration: const InputDecoration(hintText: "Phone Number"),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop({
                  'contact_name': tempName,
                  'phone_no': tempPhone,
                });
              },
            ),
          ],
        );
      },
    );
    if (newContact != null &&
        newContact['contact_name']!.isNotEmpty &&
        newContact['phone_no']!.isNotEmpty) {
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
    Map<String, String>? updatedContact = await showDialog<Map<String, String>>(
      context: context,
      builder: (BuildContext context) {
        String tempName = _contacts[index]['contact_name'];
        String tempPhone = _contacts[index]['phone_no'];
        return AlertDialog(
          title: const Text('Edit Contact'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                onChanged: (value) {
                  tempName = value;
                },
                controller:
                    TextEditingController(text: _contacts[index]['contact_name']),
                decoration: const InputDecoration(hintText: "Contact Name"),
              ),
              TextField(
                onChanged: (value) {
                  tempPhone = value;
                },
                controller:
                    TextEditingController(text: _contacts[index]['phone_no']),
                decoration: const InputDecoration(hintText: "Phone Number"),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop({
                  'contact_name': tempName,
                  'phone_no': tempPhone,
                });
              },
            ),
          ],
        );
      },
    );
    if (updatedContact != null &&
        updatedContact['contact_name']!.isNotEmpty &&
        updatedContact['phone_no']!.isNotEmpty) {
      setState(() {
        _contacts[index] = updatedContact;
      });
      _updateDeviceData();
    }
  }

  @override
  void dispose() {
    _ownerNameController.dispose();
    _pageController.dispose();
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
                style: const TextStyle(color: Color.fromARGB(255, 255, 255, 255), fontSize: 20),
                cursorColor: Colors.white,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.7)),
                  ),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.5)),
                  ),
                ),
              )
            : GestureDetector(
                onTap: () {
                  setState(() {
                    _isEditingOwnerName = true;
                  });
                  _ownerNameController.text = _ownerName ?? '';
                  _ownerNameController.selection = TextSelection.fromPosition(
                    TextPosition(offset: _ownerNameController.text.length),
                  );
                },
                child: Text(
                  '${_ownerName!}\'s Device',
                  style: const TextStyle(color: Color.fromARGB(255, 255, 255, 255), fontSize: 20),
                ),
              ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Row(
              children: [
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
                  inactiveTrackColor: const Color.fromARGB(255, 255, 255, 255).withOpacity(0),
                  inactiveThumbColor: const Color.fromARGB(255, 255, 255, 255),
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
        iconTheme: const IconThemeData(
            color: Colors.white), 
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
                                      
                                      Text('Device ID: ${widget.deviceId}',
                                          style: const TextStyle(
                                              color: Color.fromARGB(
                                                  255, 255, 255, 255))),
                                      
                                      const SizedBox(height: 10),
                                      GestureDetector(
                                        onTap: _editProfile ? _pickAndUploadImage : null,
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            CircleAvatar(
                                              radius: 60,
                                              backgroundColor: Colors.white.withOpacity(0.2),
                                              backgroundImage: _profilePicUrl != null && _profilePicUrl!.isNotEmpty
                                                  ? NetworkImage(_profilePicUrl!) as ImageProvider<Object>?
                                                  : null,
                                              child: _profilePicUrl == null || _profilePicUrl!.isEmpty
                                                  ? Icon(
                                                      Icons.person,
                                                      size: 80,
                                                      color: Colors.white.withOpacity(0.7),
                                                    )
                                                  : null,
                                            ),
                                            if (_editProfile)
                                              Positioned(
                                                bottom: 0,
                                                right: 0,
                                                child: CircleAvatar(
                                                  radius: 20,
                                                  backgroundColor: const Color.fromARGB(166, 38, 134, 203),
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
                                            style: TextStyle(color: Colors.white),
                                          ),
                                          Container(
                                            
                                            margin: const EdgeInsets.only(
                                                top: 8), 
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(
                                                  20), 
                                              border: Border.all(
                                                  color: Colors.white.withOpacity(
                                                      0.3)), 
                                            ),
                                            child: ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                  maxWidth: 120), 
                                              child: DropdownButton<String>(
                                                value: _selectedLanguage,
                                                items: <DropdownMenuItem<String>>[
                                                  const DropdownMenuItem<String>(
                                                    value: 'en',
                                                    child: Text('    English'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'hi',
                                                    child: Text('    Hindi'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'ta',
                                                    child: Text('    Tamil'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'ml',
                                                    child: Text('    Malayalam'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'te',
                                                    child: Text('    Telugu'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'kn',
                                                    child: Text('    Kannada'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'bn',
                                                    child: Text('    Bengali'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'gu',
                                                    child: Text('    Gujarati'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'mr',
                                                    child: Text('    Marathi'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'pa', 
                                                    child: Text('    Punjabi'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'ur',
                                                    child: Text('    Urdu'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'or', 
                                                    child: Text('    Odia'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'as', 
                                                    child: Text('    Assamese'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'mai', 
                                                    child: Text('    Maithili'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'lus', 
                                                    child: Text('    Mizo'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'gom', 
                                                    child: Text('    Konkani'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'mni-Mtei', 
                                                    child: Text('    Manipuri'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'sa', 
                                                    child: Text('    Sanskrit'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'awa', 
                                                    child: Text('    Awadhi'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'bho', 
                                                    child: Text('    Bhojpuri'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'doi', 
                                                    child: Text('    Dogri'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'kha', 
                                                    child: Text('    Khasi'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'kok', 
                                                    child: Text('    Kokborok'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'brx', 
                                                    child: Text('    Bodo'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'mwr', 
                                                    child: Text('    Marwari'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'sat', 
                                                    child: Text('    Santali'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'tcy', 
                                                    child: Text('    Tulu'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'ks', 
                                                    child: Text('    Kashmiri'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'ne', 
                                                    child: Text('    Nepali'),
                                                  ),
                                                  
                                                  const DropdownMenuItem<String>(
                                                    value: 'zh-CN', 
                                                    child: Text('    Chinese'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'ja',
                                                    child: Text('    Japanese'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'ko',
                                                    child: Text('    Korean'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'ru',
                                                    child: Text('    Russian'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'es',
                                                    child: Text('    Spanish'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'fr',
                                                    child: Text('    French'),
                                                  ),
                                                  const DropdownMenuItem<String>(
                                                    value: 'de',
                                                    child: Text('    German'),
                                                  ),
                                                ],
                                                onChanged: (String? newValue) {
                                                  if (newValue != null) {
                                                    setState(() {
                                                      _selectedLanguage = newValue;
                                                      _updateDeviceLanguage(newValue);
                                                    });
                                                  }
                                                },
                                                dropdownColor: const Color.fromARGB(208, 47, 72, 79).withOpacity(1),
                                                style: const TextStyle(color: Colors.white),
                                                icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                                                underline: Container(),
                                                isExpanded: true,
                                                menuMaxHeight: 200,
                                                alignment: AlignmentDirectional.centerStart,
                                                borderRadius: BorderRadius.circular(20), 
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
    backgroundColor: const Color.fromARGB(166, 38, 134, 203), 
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
                                        color: const Color.fromARGB(107, 132, 167,
                                            187), 
                                        width:
                                            4.0, 
                                      ),
                                      borderRadius: BorderRadius.circular(
                                          10.0), 
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
                                 SizedBox(height:60)
                                ])))),
                  );
                },
              ),
              LiveLocationContent(deviceId: widget.deviceId),
            ]),
      ),
      bottomNavigationBar: Container(
        color: Colors.transparent, 
        child: BottomNavigationBar(
          backgroundColor: const Color.fromARGB(94, 17, 49, 60),
          items: const <BottomNavigationBarItem>[
            BottomNavigationBarItem(
              icon: Icon(Icons.person),
              label: 'Contacts',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.gps_fixed),
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

class LiveLocationContent extends StatefulWidget {
  final String deviceId;

  const LiveLocationContent({super.key, required this.deviceId});

  @override
  State<LiveLocationContent> createState() => _LiveLocationContentState();
}

class _LiveLocationContentState extends State<LiveLocationContent> {
  LatLng? _deviceLocation;
  GoogleMapController? _mapController;
  Stream<DocumentSnapshot>? _locationStream;

  String _darkMapStyle = r'''
  [{"elementType": "geometry", "stylers": [{"color": "#242f3e"}]}, {"elementType": "labels.text.fill", "stylers": [{"color": "#746855"}]}, {"elementType": "labels.text.stroke", "stylers": [{"color": "#242f3e"}]}, {"featureType": "administrative.locality", "elementType": "labels.text.fill", "stylers": [{"color": "#d59563"}]}, {"featureType": "poi", "elementType": "labels.text.fill", "stylers": [{"color": "#d59563"}]}, {"featureType": "poi.park", "elementType": "geometry", "stylers": [{"color": "#263c3f"}]}, {"featureType": "poi.park", "elementType": "labels.text.fill", "stylers": [{"color": "#6b9a76"}]}, {"featureType": "road", "elementType": "geometry", "stylers": [{"color": "#38414e"}]}, {"featureType": "road", "elementType": "geometry.stroke", "stylers": [{"color": "#212a37"}]}, {"featureType": "road", "elementType": "labels.text.fill", "stylers": [{"color": "#9ca5b3"}]}, {"featureType": "road.highway", "elementType": "geometry", "stylers": [{"color": "#746855"}]}, {"featureType": "road.highway", "elementType": "geometry.stroke", "stylers": [{"color": "#1f2835"}]}, {"featureType": "road.highway", "elementType": "labels.text.fill", "stylers": [{"color": "#f3d19c"}]}, {"featureType": "transit", "elementType": "geometry", "stylers": [{"color": "#2f3948"}]}, {"featureType": "transit.station", "elementType": "labels.text.fill", "stylers": [{"color": "#d59563"}]}, {"featureType": "water", "elementType": "geometry", "stylers": [{"color": "#17263c"}]}, {"featureType": "water", "elementType": "labels.text.fill", "stylers": [{"color": "#515c6d"}]}, {"featureType": "water", "elementType": "labels.text.stroke", "stylers": [{"color": "#17263c"}]}]
  ''';

  @override
  void initState() {
    super.initState();
    _locationStream = FirebaseFirestore.instance
        .collection('devices')
        .doc(widget.deviceId)
        .snapshots();
    _requestLocationPermission();
  }

  Future<void> _requestLocationPermission() async {
    var status = await Permission.location.request();
    if (status.isGranted) {
      print('Location permission granted.');
    } else {
      print('Location permission denied.');
    }
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    _mapController!.setMapStyle(_darkMapStyle); 
  }

  Future<void> _openGoogleMaps() async {
    try {
      if (_deviceLocation == null) {
        print("Device location is null");
        return;
      }
      double latitude = _deviceLocation!.latitude;
      double longitude = _deviceLocation!.longitude;

      final String googleMapsUrl =
          'geo:$latitude,$longitude?q=$latitude,$longitude';

      final Uri uri = Uri.parse(googleMapsUrl);

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        print('Launched Google Maps: $googleMapsUrl');
      } else {
        print('Could not launch Google Maps: $googleMapsUrl');
        print('canLaunchUrl returned false');
      }
    } catch (e) {
      print('Error launching Google Maps: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.fromARGB(255, 10, 20, 30),
              Color.fromARGB(255, 15, 30, 45),
              Color.fromARGB(255, 40, 50, 60),
            ],
            stops: [0.0, 0.46, 1.0],
          ),
        ),
        child: Stack(
          children: [
            StreamBuilder<DocumentSnapshot>(
              stream: _locationStream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'Error: ${snapshot.error}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  );
                }
                if (_deviceLocation != null) {
                  print(
                      "Device Location: ${_deviceLocation!.latitude}, ${_deviceLocation!.longitude}");
                }

                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: Colors.white,
                    ),
                  );
                }

                if (!snapshot.hasData || !snapshot.data!.exists) {
                  return const Center(
                    child: Text(
                      'Location data not available.',
                      style: TextStyle(color: Colors.white),
                    ),
                  );
                }

                final data = snapshot.data!.data() as Map<String, dynamic>;
                final latitude = data['latitude'] as double?;
                final longitude = data['longitude'] as double?;

                if (latitude == null || longitude == null) {
                  return const Center(
                    child: Text(
                      'Invalid location data.',
                      style: TextStyle(color: Colors.white),
                    ),
                  );
                }

                _deviceLocation = LatLng(latitude, longitude);

                if (_mapController != null) {
                  _mapController!.animateCamera(
                    CameraUpdate.newLatLng(_deviceLocation!),
                  );
                }

                return GoogleMap(
                  onMapCreated: _onMapCreated,
                  initialCameraPosition: CameraPosition(
                    target: _deviceLocation!,
                    zoom: 15.0,
                  ),
                  markers: {
                    Marker(
                      markerId: const MarkerId("deviceLocation"),
                      position: _deviceLocation!,
                    ),
                  },
                  mapType: MapType.normal,
                  mapToolbarEnabled: false,
                  zoomControlsEnabled: false,
                );
              },
            ),
            Positioned(
              bottom: 16.0,
              left: 16.0,
              right: 16.0,
              child: Column(
                children: [
                  ElevatedButton(
  onPressed: () {
    _openGoogleMaps();
  },
  style: ElevatedButton.styleFrom(
    backgroundColor: const Color.fromARGB(255, 26, 51, 57), 
    foregroundColor: Colors.white, 
    elevation: 8, 
    shadowColor: const Color.fromARGB(255, 0, 0, 0).withOpacity(0.5), 
    shape: RoundedRectangleBorder( 
      borderRadius: BorderRadius.circular(20), 
      side: const BorderSide(
        color: Color.fromARGB(106, 38, 79, 82), 
        width: 2, 
      ),
    ),
  ),
  child: const Text('Open Google Maps'),
),
                  const SizedBox(height: 50)
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}