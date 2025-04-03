import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'centered_scrolling_list.dart';
import 'package:permission_handler/permission_handler.dart';
import 'home.dart';

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
  bool _editProfile = false;
  int _selectedIndex = 0;
  String _selectedLanguage = 'en';
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _fetchOwnerName();
    _fetchLanguage();
    _pageController = PageController(initialPage: _selectedIndex);
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
    }
  }

  Future<void> _fetchLanguage() async {
    try {
      DocumentSnapshot deviceSnapshot = await FirebaseFirestore.instance
          .collection('devices')
          .doc(widget.deviceId)
          .get();

      if (deviceSnapshot.exists) {
        String fetchedLanguage =
            deviceSnapshot['lang'] ?? 'en'; // Default to 'en' if 'lang' is null
        setState(() {
          _selectedLanguage = fetchedLanguage;
        });
      } else {
        print('Device document not found for deviceId: ${widget.deviceId}');
      }
    } catch (e) {
      print('Error fetching language: $e');
    }
  }

  Future<void> _fetchOwnerName() async {
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
            _isLoading = false;
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _editName(BuildContext context) async {
    if (!_editProfile) return;
    String? newName = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        String tempName = _ownerName ?? '';
        return AlertDialog(
          title: const Text('Edit Name'),
          content: TextField(
            onChanged: (value) {
              tempName = value;
            },
            controller: TextEditingController(text: _ownerName),
            decoration: const InputDecoration(hintText: "Enter new name"),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop(tempName);
              },
            ),
          ],
        );
      },
    );
    if (newName != null && newName.isNotEmpty) {
      setState(() {
        _ownerName = newName;
      });
      _updateDeviceData();
    }
  }

  Future<void> _addContact(BuildContext context) async {
    Map<String, String>? newContact = await showDialog<Map<String, String>>(
      context: context,
      builder: (BuildContext context) {
        String tempName = '';
        String tempPhone = '';
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
                controller: TextEditingController(
                    text: _contacts[index]['contact_name']),
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
          backgroundColor: Color.fromARGB(0, 44, 76, 89),
          title: Text(
              _ownerName != null
                  ? '$_ownerName\'s Device '
                  : 'Device: ${widget.deviceId}',
              style: TextStyle(color: Color.fromARGB(255, 255, 255, 255))),
          actions: [
            if (_editProfile)
              IconButton(
                icon: const Icon(Icons.edit,
                    color: Color.fromARGB(255, 255, 255, 255)),
                onPressed: () => _editName(context),
              ),
          ],
          iconTheme: const IconThemeData(
              color: Colors
                  .white), // Sets color for all icons, including the back arrow, if no leading is defined.
          leading: IconButton(
            // explicitly making the leading icon white and setting the navigation
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          )),
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
                // Use LayoutBuilder
                builder:
                    (BuildContext context, BoxConstraints viewportConstraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                        // Use ConstrainedBox
                        constraints: BoxConstraints(
                          minHeight: viewportConstraints.maxHeight,
                        ),
                        child: IntrinsicHeight(
                            // Use IntrinsicHeight
                            child: Center(
                                child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                              Column(
                                children: [
                                  SizedBox(height: 80),
                                  Text('Device ID: ${widget.deviceId}',
                                      style: TextStyle(
                                          color: Color.fromARGB(
                                              255, 255, 255, 255))),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        "Language: ",
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      Container(
                                        // Wrap DropdownButton in Container for styling
                                        margin: EdgeInsets.only(
                                            top: 8), // Bring the top down
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                              20), // Make it rounder
                                          border: Border.all(
                                              color: Colors.white.withOpacity(
                                                  0.3)), // Optional border
                                        ),
                                        child: ConstrainedBox(
                                          constraints: BoxConstraints(
                                              maxWidth: 120), // Less width
                                          child: DropdownButton<String>(
                                            value: _selectedLanguage,
                                            items: <DropdownMenuItem<String>>[
                                              DropdownMenuItem<String>(
                                                  value: 'en',
                                                  child: Text('    English')),
                                              DropdownMenuItem<String>(
                                                  value: 'ta',
                                                  child: Text('    Tamil')),
                                              DropdownMenuItem<String>(
                                                  value: 'ml',
                                                  child: Text('    Malayalam')),
                                              DropdownMenuItem<String>(
                                                  value: 'te',
                                                  child: Text('    Telegu')),
                                              DropdownMenuItem<String>(
                                                  value: 'kn',
                                                  child: Text('    Kannada')),
                                              DropdownMenuItem<String>(
                                                  value: 'hi',
                                                  child: Text('    Hindi')),
                                              DropdownMenuItem<String>(
                                                  value: 'zh-TW',
                                                  child: Text('    Chinese')),
                                              DropdownMenuItem<String>(
                                                  value: 'ja',
                                                  child: Text('    Japanese')),
                                              DropdownMenuItem<String>(
                                                  value: 'ko',
                                                  child: Text('    Korean')),
                                              DropdownMenuItem<String>(
                                                  value: 'ru',
                                                  child: Text('    Russian')),
                                              DropdownMenuItem<String>(
                                                  value: 'es',
                                                  child: Text('    Spanish')),
                                              DropdownMenuItem<String>(
                                                  value: 'fr',
                                                  child: Text('    French')),
                                              DropdownMenuItem<String>(
                                                  value: 'de',
                                                  child: Text('    German')),
                                            ],
                                            onChanged: (String? newValue) {
                                              if (newValue != null) {
                                                setState(() {
                                                  _selectedLanguage = newValue;
                                                  _updateDeviceLanguage(
                                                      newValue);
                                                });
                                              }
                                            },
                                            dropdownColor: const Color.fromARGB(
                                                    208, 47, 72, 79)
                                                .withOpacity(1),
                                            style:
                                                TextStyle(color: Colors.white),
                                            icon: Icon(Icons.arrow_drop_down,
                                                color: Colors.white),
                                            underline: Container(),
                                            isExpanded: true,
                                            menuMaxHeight: 200,
                                            alignment: AlignmentDirectional
                                                .centerStart,
                                            borderRadius: BorderRadius.circular(
                                                20), // round the dropdown
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 20),
                                  Text("Contacts:-",
                                      style: TextStyle(
                                          color: Color.fromARGB(
                                              255, 255, 255, 255),
                                          fontSize: 25)),
                                ],
                              ),
                              Container(
                                height: 300,
                                width: 300,
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 10),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Color.fromARGB(107, 132, 167,
                                        187), // White margin color
                                    width:
                                        4.0, // Thick margin width (adjust as needed)
                                  ),
                                  borderRadius: BorderRadius.circular(
                                      10.0), // Optional: rounded corners for the margin
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
                              Container(
                                child: Column(
                                  children: [
                                    ElevatedButton(
                                      onPressed: () => _addContact(context),
                                      child: const Text('Add Contact'),
                                    ),
                                    SizedBox(height: 5),
                                    ElevatedButton(
                                      onPressed: () {
                                        _logout(context);
                                      },
                                      child: Text("Logout of this device"),
                                    ),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text("Edit mode:",
                                            style: TextStyle(
                                                color: Color.fromARGB(
                                                    255, 255, 255, 255),
                                                fontSize: 15)),
                                        Switch(
                                          value: _editProfile,
                                          onChanged: (value) {
                                            setState(() {
                                              _editProfile = value;
                                            });
                                          },
                                        )
                                      ],
                                    ),
                                    SizedBox(height: 80)
                                  ],
                                ),
                              ),
                            ])))),
                  );
                },
              ),
              LiveLocationContent(deviceId: widget.deviceId),
            ]),
      ),
      bottomNavigationBar: Container(
        color: Colors.transparent, // Fully transparent container
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
    _mapController!.setMapStyle(_darkMapStyle); // Apply dark style
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
                      backgroundColor: Color.fromARGB(
                          50, 255, 255, 255), // Make the button transparent
                      foregroundColor: Colors.white, // Text color
                      elevation: 0, // Remove shadow
                    ),
                    child: const Text('Open Google Maps'),
                  ),
                  SizedBox(height: 50)
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
