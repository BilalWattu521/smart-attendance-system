import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Helper class to store copied image data synchronously
class CameraImageData {
  final int width;
  final int height;
  final ImageFormatGroup format;
  final List<Uint8List> planeBytes;
  final List<int> planeBytesPerRow;

  CameraImageData({
    required this.width,
    required this.height,
    required this.format,
    required this.planeBytes,
    required this.planeBytesPerRow,
  });

  /// Copy image data synchronously BEFORE any await
  static CameraImageData fromCameraImage(CameraImage image) {
    final planeBytes = <Uint8List>[];
    final planeBytesPerRow = <int>[];

    for (final plane in image.planes) {
      // Create a copy of the bytes
      planeBytes.add(Uint8List.fromList(plane.bytes));
      planeBytesPerRow.add(plane.bytesPerRow);
    }

    return CameraImageData(
      width: image.width,
      height: image.height,
      format: image.format.group,
      planeBytes: planeBytes,
      planeBytesPerRow: planeBytesPerRow,
    );
  }
}

class MLService {
  Interpreter? _interpreter;
  static const int inputSize = 112; // MobileFaceNet standard input
  bool _isModelLoaded = false;

  Future<void> initialize() async {
    try {
      final options = InterpreterOptions();
      // Use Metal Delegate for iOS or NNAPI for Android if available, but for simplicity CPU first
      _interpreter = await Interpreter.fromAsset(
        'assets/mobilefacenet.tflite',
        options: options,
      );
      _isModelLoaded = true;
      _isModelLoaded = true;
      debugPrint('FaceNet model loaded successfully');
    } catch (e) {
      debugPrint('Failed to load model: $e');
    }
  }

  bool get isModelLoaded => _isModelLoaded;

  /// Pre-process the CameraImage/Face to fit the model input (112x112)
  /// Returns the standard Float32List embedding
  Future<List<double>?> predict(
    CameraImage cameraImage,
    Face face,
    bool isFrontCamera,
    int rotation,
  ) async {
    if (!_isModelLoaded || _interpreter == null) {
      debugPrint('[MLService] Model not loaded');
      return null;
    }

    try {
      // 1. Convert CameraImage to img.Image
      img.Image? convertedImage = _convertCameraImage(cameraImage);
      if (convertedImage == null) return null;

      // 2. Rotate image to upright orientation
      if (rotation == 90) {
        convertedImage = img.copyRotate(convertedImage, angle: 90);
      } else if (rotation == 180) {
        convertedImage = img.copyRotate(convertedImage, angle: 180);
      } else if (rotation == 270) {
        convertedImage = img.copyRotate(convertedImage, angle: 270);
      }

      // 3. Flip if front camera
      if (isFrontCamera) {
        convertedImage = img.flipHorizontal(convertedImage);
      }

      // 4. Get face bounding box with padding (20%)
      double padding = face.boundingBox.width * 0.20;
      int x = (face.boundingBox.left - padding).toInt().clamp(
        0,
        convertedImage.width - 1,
      );
      int y = (face.boundingBox.top - padding).toInt().clamp(
        0,
        convertedImage.height - 1,
      );
      int w = (face.boundingBox.width + padding * 2).toInt();
      int h = (face.boundingBox.height + padding * 2).toInt();

      if (x + w > convertedImage.width) w = convertedImage.width - x;
      if (y + h > convertedImage.height) h = convertedImage.height - y;

      // Minimum size check
      if (w <= 0 || h <= 0) {
        debugPrint('Invalid face dimensions: $w x $h');
        return null;
      }

      debugPrint('[MLService] Cropping face at ($x, $y) size $w x $h');

      // 3. Crop and resize to 112x112
      img.Image croppedImage = img.copyCrop(
        convertedImage,
        x: x,
        y: y,
        width: w,
        height: h,
      );

      img.Image resizedImage = img.copyResize(
        croppedImage,
        width: inputSize,
        height: inputSize,
      );

      // 4. Normalize and convert to input array [1, 112, 112, 3]
      Float32List input = _imageToByteListFloat32(resizedImage);

      // 5. Run Inference
      debugPrint('[MLService] Running inference...');
      var outputBuffer = List.generate(1, (_) => List.filled(192, 0.0));
      _interpreter!.run(input.reshape([1, 112, 112, 3]), outputBuffer);

      debugPrint('[MLService] Embedding generated successfully!');
      List<double> embedding = outputBuffer[0];

      // L2 Normalization
      double sum = 0;
      for (double v in embedding) {
        sum += v * v;
      }
      double norm = sqrt(sum);
      if (norm > 0) {
        for (int i = 0; i < embedding.length; i++) {
          embedding[i] /= norm;
        }
      }

      return embedding;
    } catch (e, stackTrace) {
      debugPrint('[MLService] Error in predict: $e');
      debugPrint('[MLService] Stack: $stackTrace');
      return null;
    }
  }

  /// Version that works with pre-copied image data (survives async operations)
  Future<List<double>?> predictFromData(
    CameraImageData imageData,
    Face face,
    bool isFrontCamera,
    int rotation,
  ) async {
    if (!_isModelLoaded || _interpreter == null) {
      debugPrint('[MLService] Model not loaded');
      return null;
    }

    try {
      img.Image? convertedImage = _convertFromCameraImageData(imageData);
      if (convertedImage == null) return null;

      // Rotate
      if (rotation == 90) {
        convertedImage = img.copyRotate(convertedImage, angle: 90);
      } else if (rotation == 180) {
        convertedImage = img.copyRotate(convertedImage, angle: 180);
      } else if (rotation == 270) {
        convertedImage = img.copyRotate(convertedImage, angle: 270);
      }

      // Flip if front camera
      if (isFrontCamera) {
        convertedImage = img.flipHorizontal(convertedImage);
      }

      // Get face bounding box with 20% padding
      double padding = face.boundingBox.width * 0.20;
      int x = (face.boundingBox.left - padding).toInt().clamp(
        0,
        convertedImage.width - 1,
      );
      int y = (face.boundingBox.top - padding).toInt().clamp(
        0,
        convertedImage.height - 1,
      );
      int w = (face.boundingBox.width + padding * 2).toInt();
      int h = (face.boundingBox.height + padding * 2).toInt();

      if (x + w > convertedImage.width) w = convertedImage.width - x;
      if (y + h > convertedImage.height) h = convertedImage.height - y;

      if (w <= 0 || h <= 0) {
        debugPrint('[MLService] Invalid face dimensions: $w x $h');
        return null;
      }

      img.Image croppedImage = img.copyCrop(
        convertedImage,
        x: x,
        y: y,
        width: w,
        height: h,
      );
      img.Image resizedImage = img.copyResize(
        croppedImage,
        width: inputSize,
        height: inputSize,
      );

      Float32List input = _imageToByteListFloat32(resizedImage);

      // Use 2D output array - TFLite expects [1, 192] shape
      var outputBuffer = List.generate(1, (_) => List.filled(192, 0.0));

      _interpreter!.run(input.reshape([1, 112, 112, 3]), outputBuffer);

      // Extract the embedding from the 2D array
      List<double> embedding = outputBuffer[0];

      // L2 Normalization: Ensure vector length is 1 for robust comparison
      double sum = 0;
      for (double v in embedding) {
        sum += v * v;
      }
      double norm = sqrt(sum);
      if (norm > 0) {
        for (int i = 0; i < embedding.length; i++) {
          embedding[i] /= norm;
        }
      }

      return embedding;
    } catch (e, stackTrace) {
      debugPrint('[MLService] Error in predictFromData: $e');
      debugPrint('[MLService] Stack: $stackTrace');
      return null;
    }
  }

  /// Convert pre-copied CameraImageData to img.Image
  img.Image? _convertFromCameraImageData(CameraImageData imageData) {
    try {
      if (imageData.format == ImageFormatGroup.nv21) {
        // NV21 can be 1 plane (all data) or 2 planes (Y + VU)
        if (imageData.planeBytes.length == 1) {
          return _convertNV21SinglePlaneFromData(imageData);
        } else {
          return _convertNV21FromData(imageData);
        }
      } else if (imageData.format == ImageFormatGroup.yuv420) {
        return _convertYUV420FromData(imageData);
      } else if (imageData.format == ImageFormatGroup.bgra8888) {
        return img.Image.fromBytes(
          width: imageData.width,
          height: imageData.height,
          bytes: imageData.planeBytes[0].buffer,
          order: img.ChannelOrder.bgra,
        );
      }

      // Fallback based on plane count
      if (imageData.planeBytes.length == 1) {
        return _convertNV21SinglePlaneFromData(imageData);
      } else if (imageData.planeBytes.length == 2) {
        return _convertNV21FromData(imageData);
      } else if (imageData.planeBytes.length >= 3) {
        return _convertYUV420FromData(imageData);
      }

      debugPrint('[MLService] Unknown format: ${imageData.format}');
      return null;
    } catch (e) {
      debugPrint('[MLService] Data conversion error: $e');
      return null;
    }
  }

  img.Image? _convertNV21FromData(CameraImageData imageData) {
    try {
      final int width = imageData.width;
      final int height = imageData.height;

      final yBytes = imageData.planeBytes[0];
      final vuBytes = imageData.planeBytes[1];
      final yBytesPerRow = imageData.planeBytesPerRow[0];
      final vuBytesPerRow = imageData.planeBytesPerRow[1];

      final img.Image image = img.Image(width: width, height: height);

      for (int h = 0; h < height; h++) {
        for (int w = 0; w < width; w++) {
          final int yIndex = h * yBytesPerRow + w;
          final int vuIndex = (h ~/ 2) * vuBytesPerRow + (w ~/ 2) * 2;

          if (yIndex >= yBytes.length || vuIndex + 1 >= vuBytes.length) {
            continue;
          }

          final int y = yBytes[yIndex];
          final int v = vuBytes[vuIndex];
          final int u = vuBytes[vuIndex + 1];

          int r = (y + 1.402 * (v - 128)).round().clamp(0, 255);
          int g = (y - 0.344136 * (u - 128) - 0.714136 * (v - 128))
              .round()
              .clamp(0, 255);
          int b = (y + 1.772 * (u - 128)).round().clamp(0, 255);

          image.setPixelRgb(w, h, r, g, b);
        }
      }

      debugPrint('[MLService] NV21 from data conversion successful');
      return image;
    } catch (e) {
      debugPrint('[MLService] NV21 from data error: $e');
      return null;
    }
  }

  /// NV21 layout: [Y Y Y Y ... Y] [V U V U ... V U]
  /// Y data: bytesPerRow * height bytes at start (may include padding)
  /// VU data: interleaved, follows Y data
  img.Image? _convertNV21SinglePlaneFromData(CameraImageData imageData) {
    try {
      final int width = imageData.width;
      final int height = imageData.height;
      final bytes = imageData.planeBytes[0];
      final int yBytesPerRow = imageData.planeBytesPerRow[0];

      // Y data size with padding
      final int ySize = yBytesPerRow * height;
      // VU data starts after Y data
      final int vuOffset = ySize;
      // VU row stride (same as Y row stride for NV21)
      final int vuBytesPerRow = yBytesPerRow;

      final img.Image image = img.Image(width: width, height: height);

      for (int h = 0; h < height; h++) {
        for (int w = 0; w < width; w++) {
          // Y index with row padding
          final int yIndex = h * yBytesPerRow + w;
          // VU is interleaved: V U V U ... for each 2x2 block
          final int vuIndex =
              vuOffset + (h ~/ 2) * vuBytesPerRow + (w ~/ 2) * 2;

          if (yIndex >= bytes.length) continue;

          final int y = bytes[yIndex];
          int v = 128; // default neutral value
          int u = 128;

          if (vuIndex + 1 < bytes.length) {
            v = bytes[vuIndex];
            u = bytes[vuIndex + 1];
          }

          int r = (y + 1.402 * (v - 128)).round().clamp(0, 255);
          int g = (y - 0.344136 * (u - 128) - 0.714136 * (v - 128))
              .round()
              .clamp(0, 255);
          int b = (y + 1.772 * (u - 128)).round().clamp(0, 255);

          image.setPixelRgb(w, h, r, g, b);
        }
      }

      debugPrint('[MLService] NV21 single-plane conversion successful');
      return image;
    } catch (e) {
      debugPrint('[MLService] NV21 single-plane error: $e');
      return null;
    }
  }

  img.Image? _convertYUV420FromData(CameraImageData imageData) {
    try {
      final int width = imageData.width;
      final int height = imageData.height;
      final yBytes = imageData.planeBytes[0];
      final uBytes = imageData.planeBytes[1];
      final vBytes = imageData.planeBytes[2];
      final uvBytesPerRow = imageData.planeBytesPerRow[1];

      final img.Image image = img.Image(width: width, height: height);

      for (int h = 0; h < height; h++) {
        for (int w = 0; w < width; w++) {
          final int uvIndex = (w ~/ 2) + uvBytesPerRow * (h ~/ 2);
          final int index = h * width + w;

          if (index >= yBytes.length ||
              uvIndex >= uBytes.length ||
              uvIndex >= vBytes.length) {
            continue;
          }

          final y = yBytes[index];
          final u = uBytes[uvIndex];
          final v = vBytes[uvIndex];

          int r = (y + 1.402 * (v - 128)).round().clamp(0, 255);
          int g = (y - 0.344136 * (u - 128) - 0.714136 * (v - 128))
              .round()
              .clamp(0, 255);
          int b = (y + 1.772 * (u - 128)).round().clamp(0, 255);

          image.setPixelRgb(w, h, r, g, b);
        }
      }
      return image;
    } catch (e) {
      debugPrint('[MLService] YUV420 from data error: $e');
      return null;
    }
  }

  Float32List _imageToByteListFloat32(img.Image image) {
    var convertedBytes = Float32List(inputSize * inputSize * 3);
    int pixelIndex = 0;

    for (var i = 0; i < inputSize; i++) {
      for (var j = 0; j < inputSize; j++) {
        var pixel = image.getPixel(j, i);
        // Normalize to [-1, 1] - crucial for MobileFaceNet
        convertedBytes[pixelIndex++] = (pixel.r - 127.5) / 128.0;
        convertedBytes[pixelIndex++] = (pixel.g - 127.5) / 128.0;
        convertedBytes[pixelIndex++] = (pixel.b - 127.5) / 128.0;
      }
    }
    return convertedBytes;
  }

  // --- Image Utilities ---

  img.Image? _convertCameraImage(CameraImage image) {
    try {
      final numPlanes = image.planes.length;
      debugPrint('[MLService] Image has $numPlanes planes');

      if (image.format.group == ImageFormatGroup.nv21) {
        // NV21 has 2 planes: Y + interleaved VU
        return _convertNV21ToImage(image);
      } else if (image.format.group == ImageFormatGroup.yuv420) {
        // YUV420 has 3 planes: Y + U + V
        return _convertYUV420ToImage(image);
      } else if (image.format.group == ImageFormatGroup.bgra8888) {
        return _convertBGRA8888ToImage(image);
      }

      // Fallback based on plane count
      if (numPlanes == 2) {
        return _convertNV21ToImage(image);
      } else if (numPlanes >= 3) {
        return _convertYUV420ToImage(image);
      }

      debugPrint('[MLService] Unknown format: ${image.format.group}');
      return null;
    } catch (e) {
      debugPrint('[MLService] Image conversion error: $e');
      return null;
    }
  }

  /// Convert NV21 (2 planes: Y + interleaved VU) to RGB Image
  img.Image? _convertNV21ToImage(CameraImage cameraImage) {
    try {
      final int width = cameraImage.width;
      final int height = cameraImage.height;

      final yPlane = cameraImage.planes[0];
      final vuPlane = cameraImage.planes[1]; // NV21: VU interleaved

      debugPrint('[MLService] NV21 conversion: $width x $height');
      debugPrint(
        '[MLService] Y plane: ${yPlane.bytes.length} bytes, bytesPerRow: ${yPlane.bytesPerRow}',
      );
      debugPrint(
        '[MLService] VU plane: ${vuPlane.bytes.length} bytes, bytesPerRow: ${vuPlane.bytesPerRow}',
      );

      final img.Image image = img.Image(width: width, height: height);

      for (int h = 0; h < height; h++) {
        for (int w = 0; w < width; w++) {
          final int yIndex = h * yPlane.bytesPerRow + w;

          // VU plane is half resolution, interleaved (2 bytes per pixel pair)
          final int vuRowOffset = (h ~/ 2) * vuPlane.bytesPerRow;
          final int vuColOffset = (w ~/ 2) * 2;
          final int vuIndex = vuRowOffset + vuColOffset;

          // Bounds check
          if (yIndex >= yPlane.bytes.length ||
              vuIndex + 1 >= vuPlane.bytes.length) {
            continue; // Skip invalid pixels
          }

          final int y = yPlane.bytes[yIndex];
          // NV21: V comes before U
          final int v = vuPlane.bytes[vuIndex];
          final int u = vuPlane.bytes[vuIndex + 1];

          // YUV to RGB conversion
          int r = (y + 1.402 * (v - 128)).round().clamp(0, 255);
          int g = (y - 0.344136 * (u - 128) - 0.714136 * (v - 128))
              .round()
              .clamp(0, 255);
          int b = (y + 1.772 * (u - 128)).round().clamp(0, 255);

          image.setPixelRgb(w, h, r, g, b);
        }
      }

      debugPrint('[MLService] NV21 conversion successful');
      return image;
    } catch (e) {
      debugPrint('[MLService] NV21 conversion error: $e');
      return null;
    }
  }

  /// Convert YUV420 (3 planes: Y + U + V) to RGB Image
  img.Image _convertYUV420ToImage(CameraImage cameraImage) {
    final int width = cameraImage.width;
    final int height = cameraImage.height;
    final int uvRowStride = cameraImage.planes[1].bytesPerRow;
    final int uvPixelStride = cameraImage.planes[1].bytesPerPixel ?? 1;

    final img.Image image = img.Image(width: width, height: height);

    for (int h = 0; h < height; h++) {
      for (int w = 0; w < width; w++) {
        final int uvIndex = uvPixelStride * (w ~/ 2) + uvRowStride * (h ~/ 2);
        final int index = h * width + w;

        final y = cameraImage.planes[0].bytes[index];
        final u = cameraImage.planes[1].bytes[uvIndex];
        final v = cameraImage.planes[2].bytes[uvIndex];

        int r = (y + 1.402 * (v - 128)).round().clamp(0, 255);
        int g = (y - 0.344136 * (u - 128) - 0.714136 * (v - 128)).round().clamp(
          0,
          255,
        );
        int b = (y + 1.772 * (u - 128)).round().clamp(0, 255);

        image.setPixelRgb(w, h, r, g, b);
      }
    }
    return image;
  }

  img.Image _convertBGRA8888ToImage(CameraImage cameraImage) {
    return img.Image.fromBytes(
      width: cameraImage.width,
      height: cameraImage.height,
      bytes: cameraImage.planes[0].bytes.buffer,
      order: img.ChannelOrder.bgra,
    );
  }

  // Euclidean Distance
  double euclideanDistance(List<double> e1, List<double> e2) {
    if (e1.length != e2.length) return 100.0;
    double sum = 0.0;
    for (int i = 0; i < e1.length; i++) {
      sum += pow((e1[i] - e2[i]), 2);
    }
    return sqrt(sum);
  }
}
