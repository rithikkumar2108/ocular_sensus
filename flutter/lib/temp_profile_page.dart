import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:photo_view/photo_view.dart'; 

class TempProfilePage extends StatefulWidget {
  final String? deviceId;

  const TempProfilePage({
    Key? key,
    this.deviceId,
  }) : super(key: key);

  @override
  _TempProfilePageState createState() => _TempProfilePageState();
}

class _TempProfilePageState extends State<TempProfilePage> {
  String? _ownerName;
  double? _longitude;
  double? _latitude;
  String? _profilePicUrl;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchProfileData();
  }

  Future<void> _fetchProfileData() async {
    if (widget.deviceId == null || widget.deviceId!.isEmpty) {
      if (mounted) {
        setState(() {
          _errorMessage = 'No Device ID provided.';
          _isLoading = false;
        });
      }
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('devices')
          .doc(widget.deviceId)
          .get();

      if (doc.exists) {
        if (mounted) {
          setState(() {
            _ownerName = doc.data()?['ownerName'] as String?;
            _longitude = doc.data()?['longitude'] as double?;
            _latitude = doc.data()?['latitude'] as double?;
            _profilePicUrl = doc.data()?['profilePic'] as String?;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = 'Device data not found for ID: ${widget.deviceId}.';
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to fetch profile data: $e';
          _isLoading = false;
        });
      }
    }
  }

  
  void _showFullScreenImage(BuildContext context, String imageUrl) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.black, 
            iconTheme: const IconThemeData(color: Colors.white),
            title: const Text(
              'Image of Rescuee',
              style: TextStyle(color: Colors.white),
            ),
          ),
          body: Container(
            color: Colors.black, 
            child: PhotoView(
              imageProvider: NetworkImage(imageUrl),
              minScale: PhotoViewComputedScale.contained * 0.8,
              maxScale: PhotoViewComputedScale.covered * 2,
              heroAttributes: PhotoViewHeroAttributes(tag: imageUrl), 
              backgroundDecoration: const BoxDecoration(
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(0, 44, 76, 89),
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Rescuee Info', 
          style: TextStyle(color: Color.fromARGB(255, 255, 255, 255), fontSize: 18),
        ),
        iconTheme: const IconThemeData(
          color: Colors.white,
        ),
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
        child: Center(
          child: _isLoading
              ? const CircularProgressIndicator(color: Colors.white)
              : Container(
                  decoration: BoxDecoration(
                    color: const Color.fromARGB(32, 255, 255, 255),
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
                  height: 600,
                  width: 300,
                  margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      if (_errorMessage != null)
                        Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 18, color: Colors.redAccent),
                        )
                      else ...[
                        
                        GestureDetector(
                          onTap: () {
                            if (_profilePicUrl != null && _profilePicUrl!.isNotEmpty) {
                              _showFullScreenImage(context, _profilePicUrl!);
                            }
                          },
                          child: Hero( 
                            tag: _profilePicUrl ?? 'default_profile_pic', 
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 20.0),
                              child: CircleAvatar(
                                radius: 125, 
                                backgroundColor: Colors.white.withOpacity(0.2),
                                backgroundImage: _profilePicUrl != null && _profilePicUrl!.isNotEmpty
                                    ? NetworkImage(_profilePicUrl!) as ImageProvider<Object>?
                                    : null,
                                child: _profilePicUrl == null || _profilePicUrl!.isEmpty
                                    ? const Icon(
                                        Icons.person,
                                        size: 60,
                                        color: Colors.white70,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (_ownerName != null && _ownerName!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(
                              'Name: $_ownerName',
                              style: const TextStyle(fontSize: 18, color: Color.fromARGB(255, 255, 255, 255)),
                            ),
                          ),
                        if (widget.deviceId != null && widget.deviceId!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(
                              'Device ID: ${widget.deviceId!}',
                              style: const TextStyle(fontSize: 14, color: Color.fromARGB(255, 255, 255, 255)),
                            ),
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.all(8.0),
                            child: Text(
                              'No Device ID received.',
                              style: TextStyle(fontSize: 14, color: Colors.redAccent),
                            ),
                          ),
                        if (_latitude != null)
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(
                              'Latitude: ${_latitude!.toStringAsFixed(4)}',
                              style: const TextStyle(fontSize: 18, color: Color.fromARGB(255, 255, 255, 255)),
                            ),
                          ),
                        if (_longitude != null)
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(
                              'Longitude: ${_longitude!.toStringAsFixed(4)}',
                              style: const TextStyle(fontSize: 18, color: Color.fromARGB(255, 255, 255, 255)),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}