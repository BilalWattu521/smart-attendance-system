import 'dart:io';
import 'package:attendance_app/services/face_detector_service.dart';
import 'package:attendance_app/services/ml_service.dart';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
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
  int _cameraIndex = 0;
  List<CameraDescription> _availableCameras = [];
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
      _availableCameras = await availableCameras();
      if (_availableCameras.isEmpty) throw Exception("No cameras found");

      // Find front camera for default
      _cameraIndex = _availableCameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
      );
      if (_cameraIndex == -1) _cameraIndex = 0;

      await _initCamera(_availableCameras[_cameraIndex]);
    } catch (e) {
      if (mounted) {
        setState(() {
          if (e is CameraException && e.code == 'CameraAccessDenied') {
            _statusMessage = 'PERMISSION_DENIED';
          } else {
            _statusMessage = 'Error initializing: $e';
          }
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> _initCamera(CameraDescription description) async {
    _cameraController = CameraController(
      description,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    await _cameraController!.initialize();
    await _cameraController!.startImageStream(_processCameraImage);

    if (mounted) {
      setState(() {
        _isInitializing = false;
      });
    }
  }

  Future<void> _toggleCamera() async {
    if (_availableCameras.length < 2) return;

    setState(() {
      _isInitializing = true;
      _canEnroll = false;
    });

    await _cameraController?.stopImageStream();
    await _cameraController?.dispose();

    _cameraIndex = (_cameraIndex + 1) % _availableCameras.length;
    await _initCamera(_availableCameras[_cameraIndex]);
  }

  // Helper to convert Camera rotation to ML Kit rotation
  // For front camera, we need to compensate for the mirroring
  int _getRotationDegrees(CameraDescription camera) {
    final sensorOrientation = camera.sensorOrientation;
    if (Platform.isAndroid) {
      if (camera.lensDirection == CameraLensDirection.front) {
        return (sensorOrientation + 360) % 360;
      } else {
        return sensorOrientation;
      }
    }
    return 0;
  }

  InputImageRotation _getRotation(CameraDescription camera) {
    final degrees = _getRotationDegrees(camera);
    switch (degrees) {
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
      final camera = _availableCameras[_cameraIndex];
      final isFront = camera.lensDirection == CameraLensDirection.front;
      final rotation = _getRotationDegrees(camera);

      final embedding = await _mlService.predictFromData(
        _lastValidImageData!,
        _lastDetectedFace!,
        isFront,
        rotation,
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
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      _cameraController?.stopImageStream();
    }
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
      final isPermissionError = _statusMessage == 'PERMISSION_DENIED';

      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
          title: Text(
            isPermissionError ? "Permission Required" : "Camera Error",
          ),
          elevation: 0,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isPermissionError
                      ? Icons.camera_enhance_rounded
                      : Icons.error_outline_rounded,
                  size: 80,
                  color: isPermissionError
                      ? Colors.orange
                      : theme.colorScheme.error,
                ).animate().scale(duration: 400.ms, curve: Curves.easeOutBack),
                const SizedBox(height: 24),
                Text(
                  isPermissionError
                      ? "Camera Access Needed"
                      : "Initialization Failed",
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  isPermissionError
                      ? "To enroll your face, we need access to your camera. Please grant permission in your device settings."
                      : (_statusMessage ??
                            "Camera failed to start. Please try again."),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                    ),
                    child: const Text("GO BACK"),
                  ),
                ),
              ],
            ),
          ),
        ),
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
        actions: [
          if (!_isInitializing && _availableCameras.length > 1)
            IconButton(
              icon: const Icon(
                Icons.flip_camera_ios_rounded,
                color: Colors.white,
              ),
              onPressed: _isEmbedding ? null : _toggleCamera,
            ),
          const SizedBox(width: 8),
        ],
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
