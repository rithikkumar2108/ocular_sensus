import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Enum to define the role of a helper.
enum HelperRole { active, passive }

// A utility function to assign a consistent color based on a device ID.
// This ensures each emergency has a unique, recognizable color.
Color getDeviceColor(String deviceId) {
  final hash = deviceId.hashCode;
  // Use a list of predefined nice colors to cycle through.
  final colors = [
    Colors.red.shade400,
    Colors.blue.shade400,
    Colors.green.shade400,
    Colors.purple.shade400,
    Colors.orange.shade400,
    Colors.teal.shade400,
    Colors.pink.shade400,
    Colors.indigo.shade400,
    Colors.cyan.shade400,
    Colors.lime.shade600, // Brighter lime
    Colors.amber.shade600, // Brighter amber
    Colors.deepPurple.shade400,
    Colors.brown.shade400,
    Colors.blueGrey.shade400,
    Colors.deepOrange.shade400,
    Colors.lightGreen.shade400,
    Colors.lightBlue.shade400,
  ];
  return colors[hash % colors.length];
}

// Model for the main emergency device markers.
class EmergencyMarker {
  final String id;
  final String ownerName;
  final LatLng position;
  final DateTime timestamp; // <<< ADDED: To store the start time of the emergency.
  final String? profilePicUrl;
  final Color color;
  double? distance; // Optional distance from the user.

  EmergencyMarker({
    required this.id,
    required this.ownerName,
    required this.position,
    required this.timestamp, // <<< ADDED: Required in constructor.
    this.profilePicUrl,
    this.distance,
  }) : color = getDeviceColor(id); // Assign color automatically based on ID.
}

// Model for the helpers' markers.
class HelperMarker {
  final String id; // Firestore document ID of the helper.
  final String name;
  final LatLng position;
  final HelperRole role;
  final String status;
  final String helpingDeviceId; // ID of the device they are helping.
  final Color color; // Color should match the emergency they are helping.

  HelperMarker({
    required this.id,
    required this.name,
    required this.position,
    required this.role,
    required this.status,
    required this.helpingDeviceId,
  }) : color = getDeviceColor(helpingDeviceId); // Match color with the emergency device.

  // Factory constructor to create a HelperMarker from a Firestore document.
  factory HelperMarker.fromFirestore(DocumentSnapshot doc, String deviceId) {
    Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
    GeoPoint geoPoint = data['location'];
    return HelperMarker(
      id: doc.id,
      name: data['name'] ?? 'Unknown Helper',
      position: LatLng(geoPoint.latitude, geoPoint.longitude),
      // Convert string from Firestore to HelperRole enum.
      role: (data['isactive'] == true) ? HelperRole.active : HelperRole.passive,
      status: data['status'] ?? '',
      helpingDeviceId: deviceId,
    );
  }
}