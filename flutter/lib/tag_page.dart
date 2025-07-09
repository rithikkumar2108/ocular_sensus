import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math';
import 'package:url_launcher/url_launcher.dart';
import 'dart:ui';
import 'dart:async';
import 'animate_border.dart'; // Ensure this file contains your AnimatedBorderContainer
import 'package:audioplayers/audioplayers.dart';

class TagPage extends StatefulWidget {
  final String deviceId;

  const TagPage({super.key, required this.deviceId});

  @override
  State<TagPage> createState() => _TagPageState();
}

class _TagPageState extends State<TagPage> {
  final TextEditingController _tagNameController = TextEditingController();
  final TextEditingController _tagDetailsController = TextEditingController();
  late DocumentReference _deviceDocRef;
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _highlightedTag;

  // Stream to listen for real-time tag updates from Firestore
  late Stream<Map<String, dynamic>> _tagsStream;
  StreamSubscription<Map<String, dynamic>>? _tagsStreamSubscription;
  // Locally stored tags, updated by the stream
  Map<String, dynamic> _localTags = {};

  // Maps to store colors and rotations for each tag, managed locally
  final Map<String, Color> _tagColorMap = {};
  final Map<String, double> _tagRotationMap = {};

  final List<Color> _availableTagColors = const [
    Color(0xFF1E3A4C), // Dark Blue-Green
    Color(0xFF275E6A), // Teal
    Color(0xFF3D4C5E), // Slate Gray
    Color(0xFF1F2F3F) // Very Dark Blue-Gray
  ];
  final Random _rand = Random(); // For random initial tag rotations and colors

  bool _isDeleteEnabled = false;
  bool _isAddModifyEnabled = false;
  bool _isProcessingAction = false; // New flag to prevent rapid presses

  // NEW: State variable to control the animated border
  bool _animateMargin = false;

  // Define the duration for the animated border
  final Duration _animatedBorderDuration = const Duration(milliseconds: 700);


  @override
void initState() {
  super.initState();
  _deviceDocRef =
      FirebaseFirestore.instance.collection('devices').doc(widget.deviceId);

  // Initialize the stream for real-time tag updates
  _tagsStream = _getTagsStream();

  // Listen to the stream to update _localTags and button states
  // NEW: Assign the listener to _tagsStreamSubscription
  _tagsStreamSubscription = _tagsStream.listen((tagsData) { // MODIFY THIS LINE
    if (mounted) { // NEW: Add mounted check before setState
      setState(() {
        _localTags = tagsData;
        _updateButtonStates(); // Update buttons whenever local tags change
      });
    }
  });

  // Add listeners to text controllers to update button states
  _tagNameController.addListener(_updateButtonStates);
  _tagDetailsController.addListener(_updateButtonStates);
}

  @override
void dispose() {
  _tagNameController.removeListener(_updateButtonStates);
  _tagDetailsController.removeListener(_updateButtonStates);
  _tagNameController.dispose();
  _tagDetailsController.dispose();
  _audioPlayer.dispose();
  // NEW: Cancel the Firestore stream subscription
  _tagsStreamSubscription?.cancel(); // ADD THIS LINE
  super.dispose();
}

  /// Returns a stream of tag data from Firestore.
  Stream<Map<String, dynamic>> _getTagsStream() {
    return _deviceDocRef.snapshots().map((docSnapshot) {
      if (docSnapshot.exists && docSnapshot.data() != null) {
        final data = docSnapshot.data() as Map<String, dynamic>;
        final tagsMap = data['navigation_tags'] as Map<String, dynamic>?;
        return tagsMap ?? {};
      }
      return {};
    });
  }

  Future<void> _playTagSound({double volume = 1.0}) async {
    try {
      await _audioPlayer.setVolume(volume); // Set volume before playing
      await _audioPlayer.setSourceAsset('audio/tag_sound.mp3');
      await _audioPlayer.resume();
    } catch (e) {
      _showSnackBar('Error playing sound: $e');
      print('Error playing sound: $e');
    }
  }

  Future<void> _playPeelSound({double volume = 1.0}) async {
    try {
      await _audioPlayer.setVolume(volume); // Set volume before playing
      await _audioPlayer.setSourceAsset('audio/stickynotes_peel.mp3');
      await _audioPlayer.resume();
      await Future.delayed(const Duration(milliseconds: 500)); // Give sound time to play
    } catch (e) {
      _showSnackBar('Error playing sound: $e');
      print('Error playing sound: $e');
    }
  }

  Future<void> _playPasteSound({double volume = 1.0}) async {
    try {
      await _audioPlayer.setVolume(volume); // Set volume before playing
      await _audioPlayer.setSourceAsset('audio/stickynotes_paste.mp3');
      await _audioPlayer.resume();
      await Future.delayed(const Duration(milliseconds: 500)); // Give sound time to play
    } catch (e) {
      _showSnackBar('Error playing sound: $e');
      print('Error playing sound: $e');
    }
  }

  /// Updates the enabled state of the Add/Modify and Delete buttons
  /// based on text field content and existing tags.
  void _updateButtonStates() {
    final tagName = _tagNameController.text.trim();
    final tagDetails = _tagDetailsController.text.trim();

    final bool exactMatchFound =
        _localTags.containsKey(tagName) && _localTags[tagName] == tagDetails;

    // Buttons are disabled if an action is already in progress
    _isAddModifyEnabled =
        tagName.isNotEmpty && tagDetails.isNotEmpty && !exactMatchFound && !_isProcessingAction;
    _isDeleteEnabled = exactMatchFound && !_isProcessingAction;

    // Logic to clear highlight if text fields no longer match highlighted tag
    if (_highlightedTag != null) {
      if (_tagNameController.text.trim() != _highlightedTag ||
          _localTags[_highlightedTag!] != _tagDetailsController.text.trim()) {
        _highlightedTag = null;
      }
    }

    setState(() {
      // Update state for button enablement
    });
  }

  void _clearTextFields() {
    _tagNameController.clear();
    _tagDetailsController.clear();
  }

  /// Adds a new tag or updates an existing one in Firestore.
  Future<void> _addOrUpdateTag() async {
    // Immediately disable the button and set processing flag
    if (_isProcessingAction) return; // Prevent double tap
    setState(() {
      _isProcessingAction = true;
      _animateMargin = false; // Ensure animated border is off for Add/Modify
    });

    FocusScope.of(context).unfocus();
    await Future.delayed(const Duration(milliseconds: 400));
    final tagName = _tagNameController.text.trim();
    final tagDetails = _tagDetailsController.text.trim();

    if (tagName.isEmpty || tagDetails.isEmpty) {
      setState(() {
        _isProcessingAction = false;
      });
      return;
    }

    try {
      _playPasteSound(); // Wait for the sound to finish
      await _deviceDocRef.update({
        'navigation_tags.$tagName': tagDetails // Correctly targets the specific tag within the map
      });
      _clearTextFields();
      // UI update handled by StreamBuilder
    } catch (e) {
      _showSnackBar('Failed to save tag: $e');
    } finally {
      setState(() {
        _isProcessingAction = false;
      });
      _updateButtonStates(); // Re-enable or disable buttons based on new state
    }
  }

  Future<void> _launchMaps(String query) async {
    final encodedQuery = Uri.encodeComponent(query);
    final Uri googleMapsUrl = Uri.parse('http://maps.google.com/?q=$encodedQuery'); // Corrected URL

    try {
      if (await canLaunchUrl(googleMapsUrl)) {
        if (!await launchUrl(googleMapsUrl,
            mode: LaunchMode.externalApplication)) {
          if (!await launchUrl(googleMapsUrl, mode: LaunchMode.platformDefault)) {
            _showSnackBar('Could not launch maps for "$query"');
            print('Error: Could not launch maps for "$query"');
          }
        }
      } else {
        _showSnackBar('Cannot open maps URL for "$query". No map app found?');
        print(
            'Error: Cannot open maps URL for "$query". canLaunchUrl returned false.');
      }
    } catch (e) {
      _showSnackBar('Error launching maps: $e');
      print('Error launching maps: $e');
    }
  }

  /// Deletes a tag from Firestore.
  Future<void> _deleteTag(String tagName) async {
    if (_isProcessingAction) return; // Prevent double tap

    setState(() {
      _isProcessingAction = true; // This will disable both buttons via _updateButtonStates()
      _isDeleteEnabled = false; // Explicitly disable the delete button here
      _animateMargin = true; // NEW: Set to true to activate animated border for the deleted tag
    });

    FocusScope.of(context).unfocus();

    try {
      await _playPeelSound(); // Wait for the sound to finish
      await _deviceDocRef.update({'navigation_tags.$tagName': FieldValue.delete()});
      _clearTextFields();
      // UI update is handled by StreamBuilder
    } catch (e) {
      _showSnackBar('Error deleting tag: $e');
    } finally {
      // NEW: Delay resetting _animateMargin to allow animation to play
      Future.delayed(_animatedBorderDuration, () {
        if (mounted) { // Check if the widget is still in the tree
          setState(() {
            _animateMargin = false; // Reset after animation duration
            _isProcessingAction = false;
            _highlightedTag = null; // Clear highlight after deletion
          });
          _updateButtonStates(); // Re-enable or disable buttons based on new state
        }
      });
    }
  }

  /// Shows a SnackBar message at the bottom of the screen.
  void _showSnackBar(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Background Gradient
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF21485D), Color(0xFF19374F), Color(0xFF546767)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          // Background Blur
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
            child: Container(
              color: Colors.black.withOpacity(0.2),
            ),
          ),
          // Main Content - wrapped in GestureDetector to dismiss keyboard
          GestureDetector(
            onTap: () {
              FocusScope.of(context).unfocus();
            },
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                children: [
                  const SizedBox(height: kToolbarHeight + 30),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Container(
                      color: Colors.transparent,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Tag Name TextField
                          TextField(
                            controller: _tagNameController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: 'Tag Name',
                              hintStyle: const TextStyle(color: Colors.white54),
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.1),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              isDense: true,
                              suffixIcon: SizedBox(
                                width: 40,
                                child: _tagNameController.text.isNotEmpty
                                    ? IconButton(
                                        icon:
                                            const Icon(Icons.clear, color: Colors.white70),
                                        onPressed: () {
                                          _tagNameController.clear();
                                          _updateButtonStates();
                                        },
                                      )
                                    : Opacity(
                                        opacity: 0,
                                        child: IconButton(
                                          icon: const Icon(Icons.clear),
                                          onPressed: null,
                                        ),
                                      ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 5),

                          // Tag Details TextField
                          TextField(
                            controller: _tagDetailsController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: 'Tag Details',
                              hintStyle: const TextStyle(color: Colors.white54),
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.1),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              isDense: true,
                              suffixIcon: SizedBox(
                                width: 40,
                                child: _tagDetailsController.text.isNotEmpty
                                    ? IconButton(
                                        icon:
                                            const Icon(Icons.clear, color: Colors.white70),
                                        onPressed: () {
                                          _tagDetailsController.clear();
                                          _updateButtonStates();
                                        },
                                      )
                                    : Opacity(
                                        opacity: 0,
                                        child: IconButton(
                                          icon: const Icon(Icons.clear),
                                          onPressed: null,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),

                          // Add/Modify and Delete Buttons
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              ElevatedButton.icon(
                                onPressed: _isAddModifyEnabled ? _addOrUpdateTag : null,
                                icon: const Icon(Icons.check_circle),
                                label: const Text('Add/Modify Tag'),
                                style: ElevatedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: _isAddModifyEnabled
                                      ? const Color.fromARGB(38, 255, 255, 255)
                                      : Colors.grey,
                                ),
                              ),
                              ElevatedButton.icon(
                                onPressed: _isDeleteEnabled
                                    ? () => _deleteTag(_tagNameController.text.trim())
                                    : null,
                                icon: const Icon(Icons.delete_forever),
                                label: const Text('Delete Tag'),
                                style: ElevatedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: _isDeleteEnabled
                                      ? const Color.fromARGB(38, 255, 255, 255)
                                      : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: StreamBuilder<Map<String, dynamic>>(
                      stream: _tagsStream,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const SizedBox(
                            height: 300,
                            child: Center(
                                child:
                                    CircularProgressIndicator(color: Colors.white70)),
                          );
                        }

                        if (snapshot.hasError) {
                          return SizedBox(
                            height: 300,
                            child: Center(
                                child: Text('Error: ${snapshot.error}',
                                    style: const TextStyle(color: Colors.red))),
                          );
                        }

                        final tagsMap = snapshot.data ?? {};
                        final tags = tagsMap.entries.toList();

                        _tagColorMap.keys.toList().forEach((key) {
                          if (!tagsMap.containsKey(key)) {
                            _tagColorMap.remove(key);
                            _tagRotationMap.remove(key);
                          }
                        });
                        tagsMap.forEach((tagName, details) {
                          if (!_tagColorMap.containsKey(tagName)) {
                            _tagColorMap[tagName] = _availableTagColors[
                                _rand.nextInt(_availableTagColors.length)];
                          }
                          if (!_tagRotationMap.containsKey(tagName)) {
                            _tagRotationMap[tagName] =
                                (_rand.nextDouble() - 0.5) * pi / 18;
                          }
                        });

                        if (tags.isEmpty) {
                          return const SizedBox(
                            height: 300,
                            child: Center(
                              child: Text('No tags yet. Add one!',
                                  style: TextStyle(color: Colors.white70)),
                            ),
                          );
                        }

                        return Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: const Color.fromARGB(85, 9, 54, 60).withOpacity(0.2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.27),
                                blurRadius: 0,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.all(8.0),
                          child: SizedBox(
                            height: 425,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                double baseFontSize = 40;
                                double minAllowedFontSize = 14;

                                double fontSize;
                                double currentTagCount = tags.length.toDouble();

                                if (currentTagCount <= 7) {
                                  fontSize = baseFontSize;
                                  if (currentTagCount == 1) {
                                    fontSize = baseFontSize + 10;
                                  } else if (currentTagCount <= 3) {
                                    fontSize = baseFontSize;
                                  } else {
                                    fontSize =
                                        baseFontSize - (currentTagCount - 3) * 3;
                                  }
                                } else {
                                  fontSize =
                                      baseFontSize - (currentTagCount - 6) * 3;
                                }

                                fontSize =
                                    fontSize.clamp(minAllowedFontSize, baseFontSize + 10);

                                double currentSpacing = 6.0;
                                double currentRunSpacing = 6.0;
                                if (currentTagCount > 10) {
                                  currentSpacing = 4.0;
                                  currentRunSpacing = 4.0;
                                } else if (currentTagCount > 7) {
                                  currentSpacing = 5.0;
                                  currentRunSpacing = 5.0;
                                }

                                return Center(
                                  child: Wrap(
                                    spacing: currentSpacing,
                                    runSpacing: currentRunSpacing,
                                    alignment: WrapAlignment.center,
                                    runAlignment: WrapAlignment.center,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: tags.map((entry) {
                                      final tagName = entry.key;
                                      final color = _tagColorMap[tagName]!;
                                      final rotationAngle = _tagRotationMap[tagName]!;

                                      return Transform.rotate(
                                        angle: rotationAngle,
                                        alignment: Alignment.center,
                                        child: GestureDetector(
                                          onTap: () async {
                                            FocusScope.of(context)
                                                .unfocus();
                                            _tagNameController.text = tagName;
                                            _tagDetailsController.text = entry.value;

                                            setState(() {
                                              _highlightedTag = tagName;
                                              _animateMargin = false; // Ensure it's not animating on tap
                                            });
                                            await _playTagSound();
                                            _updateButtonStates();
                                          },
                                          onLongPress: () async {
                                            final tagDetails = entry.value;
                                            setState(() {
                                              _highlightedTag = tagName;
                                              _animateMargin = false; // Ensure it's not animating on long press
                                            });
                                            await _playTagSound();
                                            _launchMaps(tagDetails);
                                          },
                                          // Call _buildTag with the new _animateMargin state
                                          child: _buildTag(tagName, color, fontSize),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(
                      height: MediaQuery.of(context).viewInsets.bottom > 0
                          ? MediaQuery.of(context).viewInsets.bottom + 20
                          : 0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds an individual tag widget with dynamic styling and animation.
  Widget _buildTag(String text, Color color, double fontSize) {
    // Determine if this specific tag should be highlighted (selected in text fields)
    final bool isHighlighted = text == _highlightedTag;

    // Determine if the border animation should be active for THIS tag
    // This is true only if _animateMargin is true AND this tag is the one highlighted for deletion
    final bool shouldAnimateBorder = _animateMargin && isHighlighted;


    final double defaultHorizontalPadding = 16.0;
    final double defaultVerticalPadding = 8.0;

    // Calculate padding for the text content itself
    final double contentHorizontalPadding =
        defaultHorizontalPadding * (fontSize / 40).clamp(0.7, 1.3);
    final double contentVerticalPadding =
        defaultVerticalPadding * (fontSize / 40).clamp(0.7, 1.3);

    // This will be the border width when highlighted statically or animated
    final double borderWidth = 4.0;


    double dynamicElevation = 10;
    double dynamicBlurRadius = 15;
    Offset dynamicOffset = const Offset(5, 5);
    double textShadowBlur = 3;
    Offset textShadowOffset = const Offset(2, 2);

    if (fontSize < 20) {
      double scaleFactor = fontSize / 20;
      dynamicElevation = 10 + (1 - scaleFactor) * 5;
      dynamicBlurRadius = 15 + (1 - scaleFactor) * 10;
      dynamicOffset =
          Offset(5 + (1 - scaleFactor) * 3, 5 + (1 - scaleFactor) * 3);
      textShadowBlur = 3 + (1 - scaleFactor) * 2;
      textShadowOffset =
          Offset(2 + (1 - scaleFactor) * 1, 2 + (1 - scaleFactor) * 1);
    }

    // This is the content that goes inside either AnimatedContainer or AnimatedBorderContainer
    final Widget innerContent = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: contentHorizontalPadding,
        vertical: contentVerticalPadding,
      ),
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.center,
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: fontSize,
            shadows: [
              Shadow(
                color: Colors.black.withOpacity(0.6),
                blurRadius: textShadowBlur,
                offset: textShadowOffset,
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );

    // Conditionally return the AnimatedBorderContainer or the regular AnimatedContainer
    if (shouldAnimateBorder) {
      // When animating, the AnimatedBorderContainer handles the border.
      // The outer AnimatedContainer should have no padding or border,
      // and its `child` is directly the AnimatedBorderContainer.
      return Material(
        color: Colors.transparent,
        elevation: dynamicElevation,
        shadowColor: Colors.black.withOpacity(0.9),
        shape: const ContinuousRectangleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          transform: Matrix4.rotationZ(
            isHighlighted
                ? -_tagRotationMap[text]!
                : _tagRotationMap[text]!,
          ),
          transformAlignment: Alignment.center,
          constraints: const BoxConstraints(
            minWidth: 70.0,
            maxWidth: 250.0,
          ),
          // No padding or border here for the outer AnimatedContainer
          padding: EdgeInsets.zero,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                color.withOpacity(0.9),
                color.withOpacity(1.0),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(4),
            // The border is now handled by AnimatedBorderContainer
            border: Border.all(color: Colors.transparent, width: 0.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.6),
                blurRadius: dynamicBlurRadius,
                offset: dynamicOffset,
              ),
            ],
          ),
          child: AnimatedBorderContainer(
            animate: true,
            duration: _animatedBorderDuration,
            borderColor: const Color.fromARGB(255, 255, 255, 255),
            borderWidth: borderWidth, // Use the common border width
            borderRadius: 4.0,
            curve: Curves.easeInCubic,
            child: innerContent, // The text with its padding
          ),
        ),
      );
    } else {
      // Original logic for static border when not animating or not highlighted
      return Material(
        color: Colors.transparent,
        elevation: isHighlighted ? dynamicElevation + 5 : dynamicElevation,
        shadowColor: Colors.black.withOpacity(0.9),
        shape: const ContinuousRectangleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          transform: Matrix4.rotationZ(
            isHighlighted
                ? -_tagRotationMap[text]!
                : _tagRotationMap[text]!,
          ),
          transformAlignment: Alignment.center,
          constraints: const BoxConstraints(
            minWidth: 70.0,
            maxWidth: 250.0,
          ),
          // No padding here for the outer AnimatedContainer.
          // The padding is now on the `innerContent` itself.
          padding: EdgeInsets.zero,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                color.withOpacity(0.9),
                color.withOpacity(1.0),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(4),
            // Static border applied here, also uses the common border width
            border: isHighlighted
                ? Border.all(color: Colors.white, width: borderWidth)
                : Border.all(color: Colors.transparent, width: 0.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.6),
                blurRadius: dynamicBlurRadius,
                offset: dynamicOffset,
              ),
            ],
          ),
          child: innerContent, // The text with its padding
        ),
      );
    }
  }
}