import 'dart:io';
import 'package:attendance_app/services/face_detector_service.dart';
import 'package:attendance_app/services/ml_service.dart';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceEnrollmentScreen extends StatefulWidget {
  const FaceEnrollmentScreen({super.key});

  @override
  State<FaceEnrollmentScreen> createState() => _FaceEnrollmentScreenState();
}

class _FaceEnrollmentScreenState extends State<FaceEnrollmentScreen> {
  CameraController? _cameraController;
  final FaceDetectorService _faceDetectorService = FaceDetectorService();
  final MLService _mlService = MLService();

  bool _isInitializing = true;
  bool _isEmbedding = false;
  String? _statusMessage;

  // Real-time detection state
  List<Face> _faces = [];
  bool _canEnroll = false;
  CameraImageData? _lastValidImageData; // Pre-copied bytes for enrollment
  Face? _lastDetectedFace; // Last detected face for enrollment

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    try {
      // 1. Init ML Service (Load Model)
      await _mlService.initialize();

      // 2. Init Camera
      final cameras = await availableCameras();
      // Use front camera
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup
                  .nv21 // standard for Android ML Kit
            : ImageFormatGroup.bgra8888, // standard for iOS
      );

      await _cameraController!.initialize();

      // 3. Start Stream
      await _cameraController!.startImageStream(_processCameraImage);

      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Error initializing: $e';
          _isInitializing = false;
        });
      }
    }
  }

  // Helper to convert Camera rotation to ML Kit rotation
  // For front camera, we need to compensate for the mirroring
  InputImageRotation _getRotation(CameraDescription camera) {
    final sensorOrientation = camera.sensorOrientation;

    if (Platform.isAndroid) {
      // For front camera, the image is mirrored, so we need to adjust
      int rotationCompensation;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + 360) % 360;
      } else {
        rotationCompensation = sensorOrientation;
      }

      switch (rotationCompensation) {
        case 0:
          return InputImageRotation.rotation0deg;
        case 90:
          return InputImageRotation.rotation90deg;
        case 180:
          return InputImageRotation.rotation180deg;
        case 270:
          return InputImageRotation.rotation270deg;
        default:
          return InputImageRotation.rotation0deg;
      }
    }
    // iOS typically doesn't need rotation compensation
    return InputImageRotation.rotation0deg;
  }

  // Face detection logic simplified - enable enrollment when 1 face detected
  bool _isProcessing = false; // Lock to prevent parallel processing

  void _processCameraImage(CameraImage image) async {
    // Basic throttling: skip if embedding or already processing
    if (_isEmbedding || _isProcessing) return;

    _isProcessing = true;

    try {
      // CRITICAL: Copy bytes synchronously BEFORE any await
      // NV21 can be 1 plane (all data) or 2 planes, we support both
      CameraImageData? imageData;
      if (image.planes.isNotEmpty) {
        imageData = CameraImageData.fromCameraImage(image);
      }

      final camera = _cameraController!.description;
      final rotation = _getRotation(camera);

      final faces = await _faceDetectorService.detectFacesFromImage(
        image,
        rotation,
      );

      if (mounted) {
        bool faceFound = faces.length == 1;

        setState(() {
          _faces = faces;
          // Store valid image data and face for enrollment
          if (faceFound && imageData != null) {
            _lastValidImageData = imageData;
            _lastDetectedFace = faces.first;
          }
          // Enable enrollment if we have valid stored data
          _canEnroll =
              faceFound &&
              _mlService.isModelLoaded &&
              _lastValidImageData != null;
        });
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _enrollFace() async {
    // Skip if no valid data or already processing
    if (_lastValidImageData == null ||
        _lastDetectedFace == null ||
        _isEmbedding) {
      return;
    }

    setState(() {
      _isEmbedding = true;
      _statusMessage = "Generating embedding...";
    });

    try {
      // Generate embedding from the pre-copied image data
      final embedding = await _mlService.predictFromData(
        _lastValidImageData!,
        _lastDetectedFace!,
      );

      if (embedding == null) {
        throw Exception("Failed to generate embedding. Please try again.");
      }

      setState(() {
        _statusMessage = "Saving to database...";
      });

      // Save to Firestore
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'faceEmbedding': embedding,
        'faceEnrolledAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Face Enrolled Successfully!')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('[Enrollment] Error: $e');

      if (mounted) {
        setState(() {
          _statusMessage = "Error: $e";
          _isEmbedding = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _faceDetectorService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isInitializing) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text('Initializing Camera...', style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      );
    }

    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(title: const Text("Camera Error")),
        body: Center(child: Text(_statusMessage ?? "Camera failed to start")),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        title: const Text(
          "Face Enrollment",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // 1. CAMERA FEED
          Positioned.fill(
            child: AspectRatio(
              aspectRatio: _cameraController!.value.aspectRatio,
              child: CameraPreview(_cameraController!),
            ),
          ),

          // 2. MODERN OVERLAY
          Positioned.fill(
            child: CustomPaint(
              painter: FaceOverlayPainter(
                borderColor: _canEnroll ? Colors.green : Colors.white24,
                pulse: _canEnroll,
              ),
            ),
          ),

          // 3. UI CONTROLS
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 40, 24, 40),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.5),
                    Colors.black.withValues(alpha: 0.8),
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Status Badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _faces.isEmpty
                              ? Icons.face_retouching_off_rounded
                              : Icons.face_rounded,
                          size: 18,
                          color: _canEnroll ? Colors.green : Colors.white70,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _statusMessage ??
                              (_faces.isEmpty
                                  ? "Align face in frame"
                                  : _faces.length > 1
                                  ? "Multiple faces detected"
                                  : "Ready to enroll"),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Action Button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: (_canEnroll && !_isEmbedding)
                          ? _enrollFace
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _canEnroll
                            ? Colors.green
                            : theme.colorScheme.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.white10,
                        disabledForegroundColor: Colors.white24,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _isEmbedding
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              "ENROLL NOW",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FaceOverlayPainter extends CustomPainter {
  final Color borderColor;
  final bool pulse;

  FaceOverlayPainter({required this.borderColor, required this.pulse});

  @override
  void paint(Canvas canvas, Size size) {
    // Same design as Verification for consistency
    final center = Offset(size.width / 2, size.height * 0.45);
    final radius = size.width * 0.35;

    final backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final holePath = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));

    final path = Path.combine(
      PathOperation.difference,
      backgroundPath,
      holePath,
    );

    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paint);

    // Border
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawCircle(center, radius, borderPaint);

    // Corner guides
    final guidePaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    const sweep = 0.5;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius + 10),
      -1.57 - sweep,
      sweep * 2,
      false,
      guidePaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius + 10),
      0 - sweep,
      sweep * 2,
      false,
      guidePaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius + 10),
      1.57 - sweep,
      sweep * 2,
      false,
      guidePaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius + 10),
      3.14 - sweep,
      sweep * 2,
      false,
      guidePaint,
    );
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) =>
      oldDelegate.borderColor != borderColor || oldDelegate.pulse != pulse;
}
