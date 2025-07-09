// map_markers.dart
import 'package:flutter/material.dart';
import 'map_models.dart'; // Import our data models.

// A general-purpose marker widget for a person's avatar.
// Used as a base for both emergency and helper markers.
class AvatarMarker extends StatelessWidget {
  final Color color;
  final String? profilePicUrl;
  final IconData icon;
  final double size; // New: size parameter

  const AvatarMarker({
    super.key,
    required this.color,
    this.profilePicUrl,
    this.icon = Icons.person,
    this.size = 24, // Default size
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: color, // The border color is key for identification.
          width: 2.0, // Slightly thinner border
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 3, // Smaller blur
            spreadRadius: 0.5, // Smaller spread
          ),
        ],
      ),
      child: CircleAvatar(
        radius: size / 2, // Radius based on size
        backgroundColor: Colors.white.withOpacity(0.9),
        backgroundImage: (profilePicUrl != null && profilePicUrl!.isNotEmpty)
            ? NetworkImage(profilePicUrl!)
            : null,
        child: (profilePicUrl == null || profilePicUrl!.isEmpty)
            ? Icon(icon, size: size * 0.6, color: color) // Icon size relative to marker size
            : null,
      ),
    );
  }
}

// The specific widget for an emergency device marker.
class EmergencyDeviceMarkerWidget extends StatelessWidget {
  final EmergencyMarker marker;

  const EmergencyDeviceMarkerWidget({super.key, required this.marker});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AvatarMarker(
          color: marker.color,
          profilePicUrl: marker.profilePicUrl,
          icon: Icons.priority_high_rounded,
          size: 28, // Smaller size for emergency markers to prevent overflow
        ),
        const SizedBox(height: 1), // Reduced spacing
        // Label with the owner's name.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5), // Smaller padding
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(6), // Smaller radius
          ),
          child: Text(
            marker.ownerName,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 9, // Smaller font size
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// The specific widget for a helper marker.
class HelperMarkerWidget extends StatelessWidget {
  final HelperMarker marker;
  final bool showHelpingLabel; // New: to conditionally show the label
  final String? helpingDeviceOwnerName; // New: to display who they are helping

  const HelperMarkerWidget({
    super.key,
    required this.marker,
    this.showHelpingLabel = false,
    this.helpingDeviceOwnerName,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // A simple solid circle marker for helpers.
            Container(
              width: 24, // Smaller size
              height: 24, // Smaller size
              decoration: BoxDecoration(
                color: marker.color.withOpacity(0.8),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.0), // Thinner border
              ),
            ),
            // Icon indicating the helper's role (active/passive).
            Icon(
              marker.role == HelperRole.active
                  ? Icons.directions_run // Active helper icon.
                  : Icons.visibility, // Passive helper icon.
              color: Colors.white,
              size: 12, // Smaller icon size
            ),
            // New: Temporary label showing who they are helping
            if (showHelpingLabel && helpingDeviceOwnerName != null)
              Positioned(
                bottom: 24, // Position above the marker, adjusted for smaller size
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Helping: ${helpingDeviceOwnerName!}',
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 1), // Reduced spacing
        // Display the helper's status message if it's not empty.
        if (marker.status.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5), // Smaller padding
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(5), // Smaller radius
            ),
            child: Text(
              marker.status,
              style: const TextStyle(color: Colors.white, fontSize: 8), // Smaller font size
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

// The marker for the current user's location with status.
class UserStatusMarker extends StatelessWidget {
  final Color color;
  final String status;
  final String userName;
  final HelperRole role; // Added role parameter

  const UserStatusMarker({
    super.key,
    required this.color,
    required this.status,
    required this.userName,
    required this.role, // Initialize role
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Container(
              width: 24, // Smaller size for user icon
              height: 24, // Smaller size for user icon
              decoration: BoxDecoration(
                color: color, // Use the passed color
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5), // Thinner border
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.5),
                    blurRadius: 8, // Smaller blur
                    spreadRadius: 3, // Smaller spread
                  ),
                ],
              ),
              child: Icon(
                role == HelperRole.active ? Icons.directions_run : Icons.visibility, // Dynamic icon based on role
                color: Colors.white,
                size: 14, // Smaller icon
              ),
            ),
            // User name label
            Positioned(
              bottom: 24, // Position above the marker
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade700.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  userName,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 1), // Reduced spacing
        // Display the user's status message if it's not empty.
        if (status.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5), // Smaller padding
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(5), // Smaller radius
            ),
            child: Text(
              status,
              style: const TextStyle(color: Colors.white, fontSize: 8), // Smaller font size
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}