import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceDetectorService {
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: false,
      enableClassification: false,
      enableLandmarks: false,
      enableTracking: false,
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.15, // Detect faces that are at least 15% of image width
    ),
  );

  bool _isBusy = false;

  Future<List<Face>> detectFacesFromImage(
    CameraImage image,
    InputImageRotation rotation,
  ) async {
    if (_isBusy) return [];
    _isBusy = true;

    try {
      final inputImage = _buildInputImage(image, rotation);
      if (inputImage == null) {
        debugPrint('[FaceDetector] Failed to build InputImage');
        _isBusy = false;
        return [];
      }

      final faces = await _faceDetector.processImage(inputImage);
      debugPrint(
        '[FaceDetector] Found ${faces.length} faces | Format: ${image.format.group} | Size: ${image.width}x${image.height}',
      );
      _isBusy = false;
      return faces;
    } catch (e) {
      debugPrint('[FaceDetector] ERROR: $e');
      _isBusy = false;
      return [];
    }
  }

  /// Build InputImage from CameraImage - handles NV21 (Android) and BGRA8888 (iOS)
  InputImage? _buildInputImage(CameraImage image, InputImageRotation rotation) {
    // Determine format
    final format = InputImageFormatValue.fromRawValue(image.format.raw);

    // For NV21 format (Android), we need all plane bytes concatenated
    // For BGRA8888 (iOS), we only need the first plane
    Uint8List bytes;

    if (format == InputImageFormat.nv21) {
      // Android NV21: Concatenate Y plane + interleaved UV plane
      final WriteBuffer buffer = WriteBuffer();
      for (final Plane plane in image.planes) {
        buffer.putUint8List(plane.bytes);
      }
      bytes = buffer.done().buffer.asUint8List();
    } else if (format == InputImageFormat.bgra8888) {
      // iOS BGRA: Just use the first plane
      bytes = image.planes[0].bytes;
    } else {
      // Fallback: try concatenating all planes
      final WriteBuffer buffer = WriteBuffer();
      for (final Plane plane in image.planes) {
        buffer.putUint8List(plane.bytes);
      }
      bytes = buffer.done().buffer.asUint8List();
    }

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format ?? InputImageFormat.nv21,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  void dispose() {
    _faceDetector.close();
  }
}
