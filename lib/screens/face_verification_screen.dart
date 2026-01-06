import 'dart:io';
import 'package:attendance_app/services/face_detector_service.dart';
import 'package:attendance_app/services/ml_service.dart';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceVerificationScreen extends StatefulWidget {
  final String studentUid;
  final String studentName;
  final String requestId;

  const FaceVerificationScreen({
    super.key,
    required this.studentUid,
    required this.studentName,
    required this.requestId,
  });

  @override
  State<FaceVerificationScreen> createState() => _FaceVerificationScreenState();
}

class _FaceVerificationScreenState extends State<FaceVerificationScreen> {
  CameraController? _cameraController;
  final FaceDetectorService _faceDetectorService = FaceDetectorService();
  final MLService _mlService = MLService();

  bool _isInitializing = true;
  bool _isVerifying = false;
  String? _statusMessage;
  List<double>? _storedEmbedding;

  // Real-time detection state
  List<Face> _faces = [];
  bool _canVerify = false;
  CameraImageData? _lastValidImageData;
  Face? _lastDetectedFace;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      // 1. Fetch stored embedding
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.studentUid)
          .get();

      final data = userDoc.data();
      if (data == null || !data.containsKey('faceEmbedding')) {
        throw Exception("Student has no enrolled face data.");
      }

      _storedEmbedding = List<double>.from(data['faceEmbedding']);

      // 2. Init services
      await _mlService.initialize();

      // 3. Init Camera
      final cameras = await availableCameras();
      // Use back camera for Admin to verify student, or front if self-verification?
      // Usually Admin is holding the phone, so back camera is better.
      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
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
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Error: $e';
          _isInitializing = false;
        });
      }
    }
  }

  InputImageRotation _getRotation(CameraDescription camera) {
    final sensorOrientation = camera.sensorOrientation;
    if (Platform.isAndroid) {
      int rotationCompensation = sensorOrientation;
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
    return InputImageRotation.rotation0deg;
  }

  bool _isProcessing = false;

  void _processCameraImage(CameraImage image) async {
    if (_isVerifying || _isProcessing) return;
    _isProcessing = true;

    try {
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
          if (faceFound && imageData != null) {
            _lastValidImageData = imageData;
            _lastDetectedFace = faces.first;
          }
          _canVerify =
              faceFound &&
              _mlService.isModelLoaded &&
              _lastValidImageData != null;
        });
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _verifyFace() async {
    if (_lastValidImageData == null ||
        _lastDetectedFace == null ||
        _isVerifying ||
        _storedEmbedding == null) {
      return;
    }

    setState(() {
      _isVerifying = true;
      _statusMessage = "Verifying face...";
    });

    try {
      final currentEmbedding = await _mlService.predictFromData(
        _lastValidImageData!,
        _lastDetectedFace!,
      );

      if (currentEmbedding == null) {
        throw Exception("Failed to process face.");
      }

      final distance = _mlService.euclideanDistance(
        currentEmbedding,
        _storedEmbedding!,
      );
      debugPrint('[Verification] Distance: $distance');

      // Threshold: 1.0 is generally good for MobileFaceNet
      if (distance < 1.0) {
        setState(
          () => _statusMessage =
              "Match Found! (Dist: ${distance.toStringAsFixed(2)})\nUpdating attendance...",
        );

        try {
          await _updateAttendance();

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Identity Verified (Dist: ${distance.toStringAsFixed(2)})',
                ),
                backgroundColor: Colors.green,
              ),
            );
            Navigator.pop(context, true);
          }
        } catch (e) {
          debugPrint('[Verification] Error updating attendance: $e');
          if (mounted) {
            setState(() {
              _statusMessage = "Error updating database:\n$e";
              _isVerifying = false;
            });
          }
        }
      } else {
        setState(() {
          _statusMessage =
              "Identity mismatch\nDistance: ${distance.toStringAsFixed(2)}";
          _isVerifying = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = "Error: $e";
          _isVerifying = false;
        });
      }
    }
  }

  Future<void> _updateAttendance() async {
    final now = DateTime.now();
    final dateKey =
        "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

    // 1. Update request status
    await FirebaseFirestore.instance
        .collection('attendance_requests')
        .doc(widget.requestId)
        .update({
          'status': 'verified',
          'verifiedAt': FieldValue.serverTimestamp(),
        });

    // 2. Create/Update attendance summary record
    await FirebaseFirestore.instance
        .collection('attendance')
        .doc(dateKey)
        .collection('records')
        .doc(widget.studentUid)
        .set({
          'studentName': widget.studentName,
          'timestamp': FieldValue.serverTimestamp(),
          'status': 'present',
        });
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
              Text('Preparing Camera...', style: theme.textTheme.bodyMedium),
            ],
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
        title: Text(
          "Verify: ${widget.studentName}",
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // 1. CAMERA PREVIEW
          if (_cameraController != null &&
              _cameraController!.value.isInitialized)
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
                borderColor: _canVerify
                    ? theme.colorScheme.primary
                    : Colors.white24,
                pulse: _canVerify,
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
                              ? Icons.sensors_rounded
                              : Icons.face_rounded,
                          size: 18,
                          color: _canVerify
                              ? theme.colorScheme.primary
                              : Colors.white70,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _statusMessage ??
                              (_faces.isEmpty
                                  ? "Align face in frame"
                                  : "Face detected"),
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
                      onPressed: (_canVerify && !_isVerifying)
                          ? _verifyFace
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        disabledBackgroundColor: Colors.white10,
                        disabledForegroundColor: Colors.white24,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _isVerifying
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              "VERIFY NOW",
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
