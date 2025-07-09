import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';
import 'map_models.dart'; // Import our new models.

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Stream to get all nearby emergency devices.
  Stream<List<EmergencyMarker>> getEmergencyDevicesStream() {
    return _db
        .collection('devices')
        .where('emergency', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        // Fallback to current time if timestamp is null to prevent errors.
        final timestamp = (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
        return EmergencyMarker(
          id: doc.id,
          ownerName: data['ownerName'] ?? 'Unknown',
          position: LatLng(data['latitude'], data['longitude']),
          profilePicUrl: data['profilePic'],
          timestamp: timestamp, // <<< ADDED: Pass the timestamp to the model.
        );
      }).toList();
    });
  }

  Stream<EmergencyMarker?> getSingleEmergencyDeviceStream(String deviceId) {
    return _db
        .collection('devices')
        .doc(deviceId)
        .snapshots()
        .map((docSnapshot) {
      if (docSnapshot.exists) {
        final data = docSnapshot.data();
        if (data != null) {
          // Fallback to current time if timestamp is null.
          final timestamp = (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
          return EmergencyMarker(
            id: docSnapshot.id,
            ownerName: data['ownerName'] ?? 'Unknown',
            position: LatLng(data['latitude'], data['longitude']),
            profilePicUrl: data['profilePic'],
            timestamp: timestamp, // <<< ADDED: Pass the timestamp to the model.
          );
        }
      }
      return null;
    });
  }


  // Stream to get all helpers for a specific emergency device.
  Stream<List<HelperMarker>> getHelpersStream(String deviceId) {
    return _db
        .collection('devices')
        .doc(deviceId)
        .collection('helpers')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => HelperMarker.fromFirestore(doc, deviceId))
            .toList());
  }

  // Updates or creates a helper document in Firestore.
  // This is called when a user decides to help or changes their role.
  Future<void> updateHelperStatus({
    required String deviceId,
    required String helperId,
    required String name,
    required LatLng location,
    required HelperRole role,
    String status = '',
  }) async {
    final helperRef =
        _db.collection('devices').doc(deviceId).collection('helpers').doc(helperId);

    await helperRef.set({
      'name': name,
      'location': GeoPoint(location.latitude, location.longitude),
      'isactive': role == HelperRole.active,
      'status': status,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  // Deletes a helper document.
  // This is used when a user stops helping or switches to another emergency.
  Future<void> removeHelper(String deviceId, String helperId) async {
    final helperRef =
        _db.collection('devices').doc(deviceId).collection('helpers').doc(helperId);
    await helperRef.delete();
  }

  Future<void> updateEmergencyStatus(String deviceId, bool isEmergency) async {
    final deviceRef = _db.collection('devices').doc(deviceId);
    await deviceRef.update({'emergency': isEmergency});
  }

  // New method to resolve an emergency by setting its 'emergency' field to false.
  Future<void> resolveEmergency(String deviceId) async {
    final deviceRef = _db.collection('devices').doc(deviceId);
    await deviceRef.update({'emergency': false});

    // Optionally, you might want to remove all helpers associated with this resolved emergency
    // as part of the resolution process.
    final helpersSnapshot = await deviceRef.collection('helpers').get();
    for (var doc in helpersSnapshot.docs) {
      await doc.reference.delete();
    }
  }


  // Updates just the status message for a helper.
  Future<void> updateHelperMessage(
      String deviceId, String helperId, String status) async {
    final helperRef =
        _db.collection('devices').doc(deviceId).collection('helpers').doc(helperId);
    await helperRef.update({'status': status});
  }
}