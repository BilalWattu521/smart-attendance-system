import 'dart:async';

import 'package:attendance_app/screens/face_enrollment_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

class StudentDashboard extends StatefulWidget {
  const StudentDashboard({super.key, required this.currentUser});

  final User currentUser;

  @override
  State<StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<StudentDashboard>
    with WidgetsBindingObserver {
  // Config
  double? _campusLat;
  double? _campusLng;
  double? _campusRadius;
  bool _configLoaded = false;

  // Status
  bool? _isInsideCampus;
  bool _isEnrolled = false; // Track if face is enrolled
  bool _hasPendingRequest =
      false; // Track if there's a pending attendance request
  bool _isVerifiedToday = false; // Track if attendance is verified today
  bool _isRequestingAttendance = false; // Loading state for request button
  StreamSubscription<QuerySnapshot>? _attendanceSubscription;

  // Location & Map
  final MapController _mapController = MapController();
  Position? _currentPosition;

  // New Dashboard State
  int _selectedIndex = 0;
  String _userName = 'Student';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initGeofencing();
    _fetchUserData();
    _startAttendanceListener();
  }

  Future<void> _fetchUserData() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (mounted) {
        setState(() {
          _userName = doc.data()?['name'] ?? 'Student';
          _isEnrolled = doc.data()?.containsKey('faceEmbedding') ?? false;
        });
      }
    }
  }

  void _startAttendanceListener() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final today = DateTime.now();
    final startOfDay = DateTime(today.year, today.month, today.day);

    _attendanceSubscription?.cancel();
    _attendanceSubscription = FirebaseFirestore.instance
        .collection('attendance_requests')
        .where('studentUid', isEqualTo: uid)
        .snapshots()
        .listen((snapshot) {
          bool hasPending = false;
          bool isVerified = false;

          for (var doc in snapshot.docs) {
            final data = doc.data();
            final status = data['status'];
            final requestedAt = (data['requestedAt'] as Timestamp?)?.toDate();

            if (requestedAt != null && requestedAt.isAfter(startOfDay)) {
              if (status == 'pending') {
                hasPending = true;
              } else if (status == 'verified') {
                isVerified = true;
              }
            }
          }

          if (mounted) {
            setState(() {
              _hasPendingRequest = hasPending;
              _isVerifiedToday = isVerified;
            });
          }
        });
  }

  Future<void> _requestAttendance() async {
    if (_isRequestingAttendance || _hasPendingRequest) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() => _isRequestingAttendance = true);

    try {
      // Get user info for the request
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      final userData = userDoc.data() ?? {};

      // Create attendance request
      await FirebaseFirestore.instance.collection('attendance_requests').add({
        'studentUid': uid,
        'studentName': userData['name'] ?? 'Unknown',
        'studentEmail': userData['email'] ?? '',
        'requestedAt': FieldValue.serverTimestamp(),
        'status': 'pending', // pending, verified, rejected
        'location': _currentPosition != null
            ? GeoPoint(_currentPosition!.latitude, _currentPosition!.longitude)
            : null,
      });

      if (mounted) {
        setState(() {
          _hasPendingRequest = true;
          _isRequestingAttendance = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Attendance request submitted! Wait for admin verification.',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isRequestingAttendance = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _attendanceSubscription?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check permissions/service when user comes back to the app (e.g. from Settings)
    if (state == AppLifecycleState.resumed) {
      _initGeofencing();
    }
  }

  Future<void> _initGeofencing() async {
    try {
      // 1. Fetch Campus Config (if not already)
      if (!_configLoaded) {
        await _fetchCampusConfig();
      }

      if (!_configLoaded) {
        debugPrint('Failed to load campus configuration.');
        return;
      }

      // 2. Request Permissions & Check Service
      final permission = await _handlePermission();
      if (!permission) return;

      // 3. Start Listening to Location
      _startLocationStream();
    } catch (e) {
      if (mounted) {
        setState(() {
          _configLoaded = true;
        });
      }
    }
  }

  Future<void> _fetchCampusConfig() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('campus')
          .doc('config')
          .get();

      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        _campusLat = (data['lat'] as num?)?.toDouble();
        _campusLng = (data['lng'] as num?)?.toDouble();
        _campusRadius = (data['radius'] as num?)?.toDouble();

        if (_campusLat != null && _campusLng != null && _campusRadius != null) {
          _configLoaded = true;
          debugPrint(
            'Campus Config: $_campusLat, $_campusLng, $_campusRadius m',
          );
        }
      } else {
        debugPrint('Campus config missing in Firestore.');
      }
    } catch (e) {
      debugPrint('Error fetching config: $e');
    }
  }

  Future<bool> _handlePermission() async {
    bool serviceEnabled;
    LocationPermission permission;
    bool justGranted = false;

    // 1. Check/Request Permissions FIRST
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        // _updateStatus(
        //   'Permission denied. Please enable in Settings.',
        //   Colors.orange,
        // );
        return false;
      }
      // If we are here, we just got permission
      justGranted = true;
    }

    if (permission == LocationPermission.deniedForever) {
      // _updateStatus(
      //   'Permission permanently denied. Go to Phone Settings.',
      //   Colors.red,
      // );
      return false;
    }

    // 2. Check Service Status (GPS)
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Only open settings automatically if this is the "first run" (permission just granted)
      if (justGranted) {
        // _updateStatus('GPS is off. Opening Settings...', Colors.orange);
        await Geolocator.openLocationSettings();

        // Re-check after returning
        serviceEnabled = await Geolocator.isLocationServiceEnabled();
      }

      // If still disabled (or if we didn't open settings), show message
      if (!serviceEnabled) {
        // _updateStatus(
        //   'Location (GPS) is disabled. Please turn it on.',
        //   Colors.orange,
        // );
        return false;
      }
    }

    return true;
  }

  // void _updateStatus(String message, Color color) {
  //   if (mounted) {
  //     setState(() {
  //       _statusMessage = message;
  //       _statusColor = color;
  //       _isLoading = false;
  //     });
  //   }
  // }

  void _startLocationStream() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 5, // Relaxed slightly to reduce updates
    );

    Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) {
        _checkGeofence(position);
      },
      onError: (e) {
        // _updateStatus('Location Error: $e', Colors.red);
      },
    );
  }

  void _checkGeofence(Position userPosition) async {
    if (!_configLoaded) return;

    final distance = Geolocator.distanceBetween(
      userPosition.latitude,
      userPosition.longitude,
      _campusLat!,
      _campusLng!,
    );

    final isInside = distance <= _campusRadius!;

    if (mounted) {
      setState(() {
        _currentPosition = userPosition;
        _isInsideCampus = isInside;
      });
    }

    // Update Firestore if state changed
    if (isInside != _lastWrittenStatus) {
      _updateFirestoreLog(isInside);
    }
  }

  // Track the last status written to DB
  bool? _lastWrittenStatus;

  Future<void> _updateFirestoreLog(bool isInside) async {
    if (_lastWrittenStatus == isInside) return;

    final now = FieldValue.serverTimestamp();
    final logRef = FirebaseFirestore.instance
        .collection('geofence_logs')
        .doc(widget.currentUser.uid);

    final data = <String, dynamic>{
      'insideCampus': isInside,
      'lastCheckedAt': now,
    };

    if (isInside) {
      data['enteredAt'] = now;
    }

    try {
      await logRef.set(data, SetOptions(merge: true));
      _lastWrittenStatus = isInside;
      debugPrint('Geofence Log Updated: Inside=$isInside');
    } catch (e) {
      debugPrint('Error writing geofence log: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectedIndex == 0
              ? 'Dashboard'
              : _selectedIndex == 1
              ? 'Campus Map'
              : _selectedIndex == 2
              ? 'Attendance'
              : 'Security Settings',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      drawer: Drawer(
        child: Column(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: theme.colorScheme.primary,
                    child: Text(
                      _userName.isNotEmpty ? _userName[0].toUpperCase() : 'S',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _userName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          widget.currentUser.email ?? '',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _buildDrawerItem(
              index: 0,
              icon: Icons.dashboard_rounded,
              label: 'Dashboard',
            ),
            _buildDrawerItem(
              index: 1,
              icon: Icons.map_rounded,
              label: 'Campus Map',
            ),
            _buildDrawerItem(
              index: 2,
              icon: Icons.fact_check_rounded,
              label: 'Attendance',
            ),
            _buildDrawerItem(
              index: 3,
              icon: Icons.lock_reset_rounded,
              label: 'Change Password',
            ),
            const Spacer(),
            const Divider(indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: Colors.red),
              title: const Text(
                'Logout',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () => FirebaseAuth.instance.signOut(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildDrawerItem({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final theme = Theme.of(context);
    final isSelected = _selectedIndex == index;

    return ListTile(
      leading: Icon(icon, color: isSelected ? theme.colorScheme.primary : null),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? theme.colorScheme.primary : null,
        ),
      ),
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.3,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      onTap: () {
        setState(() => _selectedIndex = index);
        Navigator.pop(context);
      },
    );
  }

  Widget _buildBody(ThemeData theme) {
    switch (_selectedIndex) {
      case 0:
        return _buildHomeTab(theme);
      case 1:
        return _buildMapTab(theme);
      case 2:
        return _buildAttendanceTab(theme);
      case 3:
        return const ChangePasswordTab();
      default:
        return _buildHomeTab(theme);
    }
  }

  Widget _buildHomeTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Welcome,',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          Text(
            _userName,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 32),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.3,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _isEnrolled
                              ? Colors.green.withValues(alpha: 0.1)
                              : Colors.orange.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isEnrolled
                              ? Icons.face_rounded
                              : Icons.face_retouching_off_rounded,
                          color: _isEnrolled ? Colors.green : Colors.orange,
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Face Enrollment',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              _isEnrolled
                                  ? 'Your face is enrolled and ready.'
                                  : 'Enroll your face to mark attendance.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (!_isEnrolled) ...[
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const FaceEnrollmentScreen(),
                            ),
                          );
                          if (result == true) _fetchUserData();
                        },
                        icon: const Icon(Icons.face_unlock_outlined),
                        label: const Text('Enroll Now'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ).animate().fadeIn(delay: 200.ms).moveY(begin: 20, end: 0),
          const SizedBox(height: 24),
          // Quick status summary
          Row(
            children: [
              Expanded(
                child: _buildSummaryCard(
                  theme,
                  'Location',
                  _isInsideCampus == true ? 'On Campus' : 'Off Campus',
                  _isInsideCampus == true
                      ? Icons.location_on
                      : Icons.location_off,
                  _isInsideCampus == true ? Colors.blue : Colors.red,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildSummaryCard(
                  theme,
                  'Attendance',
                  _isVerifiedToday
                      ? 'Verified'
                      : _hasPendingRequest
                      ? 'Pending'
                      : 'Not Marked',
                  _isVerifiedToday
                      ? Icons.verified
                      : _hasPendingRequest
                      ? Icons.hourglass_top
                      : Icons.close,
                  _isVerifiedToday
                      ? Colors.green
                      : _hasPendingRequest
                      ? Colors.orange
                      : Colors.grey,
                ),
              ),
            ],
          ).animate().fadeIn(delay: 400.ms).moveY(begin: 20, end: 0),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(
    ThemeData theme,
    String title,
    String status,
    IconData icon,
    Color color,
  ) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 8),
            Text(title, style: theme.textTheme.labelMedium),
            Text(
              status,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapTab(ThemeData theme) {
    if (!_configLoaded) return const Center(child: CircularProgressIndicator());

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _currentPosition != null
                ? LatLng(
                    _currentPosition!.latitude,
                    _currentPosition!.longitude,
                  )
                : LatLng(_campusLat!, _campusLng!),
            initialZoom: 15.0,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.attendance_app',
            ),
            CircleLayer(
              circles: [
                CircleMarker(
                  point: LatLng(_campusLat!, _campusLng!),
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  borderStrokeWidth: 2,
                  borderColor: theme.colorScheme.primary,
                  useRadiusInMeter: true,
                  radius: _campusRadius!,
                ),
              ],
            ),
            MarkerLayer(
              markers: [
                if (_currentPosition != null)
                  Marker(
                    point: LatLng(
                      _currentPosition!.latitude,
                      _currentPosition!.longitude,
                    ),
                    width: 60,
                    height: 60,
                    child:
                        Icon(
                              Icons.person_pin_circle_rounded,
                              color: theme.colorScheme.error,
                              size: 50,
                            )
                            .animate(onPlay: (c) => c.repeat(reverse: true))
                            .scale(
                              begin: const Offset(1, 1),
                              end: const Offset(1.2, 1.2),
                              duration: 1000.ms,
                            ),
                  ),
                Marker(
                  point: LatLng(_campusLat!, _campusLng!),
                  width: 40,
                  height: 40,
                  child: Icon(
                    Icons.school_rounded,
                    color: theme.colorScheme.primary,
                    size: 30,
                  ),
                ),
              ],
            ),
          ],
        ),

        // Distance Footer
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.9),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 10,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _currentPosition == null
                      ? Icons.location_off_rounded
                      : Icons.straighten_rounded,
                  size: 20,
                  color: _currentPosition == null
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _currentPosition == null
                        ? 'Location is off. Please turn it on.'
                        : 'Distance to Campus: ${_calculateDistance().toStringAsFixed(0)} meters',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _currentPosition == null
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ).animate().slideY(begin: 1.0, end: 0.0),
        ),

        Positioned(
          bottom: 80,
          right: 20,
          child: FloatingActionButton(
            mini: true,
            backgroundColor: theme.colorScheme.surface,
            child: Icon(
              Icons.my_location_rounded,
              color: theme.colorScheme.primary,
            ),
            onPressed: () {
              if (_currentPosition != null) {
                _mapController.move(
                  LatLng(
                    _currentPosition!.latitude,
                    _currentPosition!.longitude,
                  ),
                  16.0,
                );
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAttendanceTab(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildAttendanceIllustration(theme),
          const SizedBox(height: 40),
          _buildAttendanceStatusText(theme),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StatusChip(
                label: _isInsideCampus == true ? 'On Campus' : 'Off Campus',
                icon: _isInsideCampus == true
                    ? Icons.location_on_rounded
                    : Icons.location_off_rounded,
                color: _isInsideCampus == true ? Colors.blue : Colors.red,
              ),
              const SizedBox(width: 8),
              _StatusChip(
                label: _isEnrolled ? 'Face Enrolled' : 'No Face Data',
                icon: Icons.face_rounded,
                color: _isEnrolled ? Colors.green : Colors.orange,
              ),
            ],
          ),
          const SizedBox(height: 40),
          SizedBox(width: double.infinity, child: _buildActionButton(theme)),
        ],
      ),
    );
  }

  Widget _buildAttendanceIllustration(ThemeData theme) {
    IconData icon;
    Color color;

    if (_isVerifiedToday) {
      icon = Icons.verified_rounded;
      color = Colors.green;
    } else if (_hasPendingRequest) {
      icon = Icons.pending_actions_rounded;
      color = Colors.orange;
    } else {
      icon = Icons.touch_app_rounded;
      color = theme.colorScheme.primary;
    }

    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 80, color: color),
    ).animate().scale(duration: 500.ms, curve: Curves.easeOutBack);
  }

  Widget _buildAttendanceStatusText(ThemeData theme) {
    String title;
    String subtitle;

    if (_isVerifiedToday) {
      title = 'Attendance Verified';
      subtitle = 'Your attendance has been recorded for today.';
    } else if (_hasPendingRequest) {
      title = 'Verification Pending';
      subtitle = 'An administrator will verify your request shortly.';
    } else if (!_isEnrolled) {
      title = 'Enrollment Required';
      subtitle = 'Please enroll your face before marking attendance.';
    } else if (_isInsideCampus == false) {
      title = 'Outside Campus';
      subtitle = 'You must be within the campus boundary to mark attendance.';
    } else {
      title = 'Ready to Mark';
      subtitle = 'You are on campus. Tap below to request attendance.';
    }

    return Column(
      children: [
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(ThemeData theme) {
    if (!_isEnrolled) {
      return ElevatedButton.icon(
        icon: const Icon(Icons.face_unlock_outlined),
        label: const Text('COMPLETE ENROLLMENT'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.orange,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.all(18),
        ),
        onPressed: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const FaceEnrollmentScreen()),
          );
          if (result == true) _fetchUserData();
        },
      );
    } else if (_isVerifiedToday) {
      return ElevatedButton.icon(
        icon: const Icon(Icons.verified_user_rounded),
        label: const Text('ATTENDANCE VERIFIED'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.all(18),
        ),
        onPressed: null,
      );
    } else if (_hasPendingRequest) {
      return ElevatedButton.icon(
        icon: const Icon(Icons.hourglass_empty_rounded),
        label: const Text('PENDING VERIFICATION'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blueGrey,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.all(18),
        ),
        onPressed: null,
      );
    } else {
      final canRequest = _isInsideCampus == true && !_isRequestingAttendance;
      return ElevatedButton.icon(
        icon: _isRequestingAttendance
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.touch_app_rounded),
        label: Text(
          _isRequestingAttendance ? 'SENDING REQUEST...' : 'MARK ATTENDANCE',
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: canRequest
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.all(18),
        ),
        onPressed: canRequest ? _requestAttendance : null,
      );
    }
  }

  double _calculateDistance() {
    if (_currentPosition == null || !_configLoaded) return 0;
    return Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      _campusLat!,
      _campusLng!,
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _StatusChip({
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class ChangePasswordTab extends StatefulWidget {
  const ChangePasswordTab({super.key});

  @override
  State<ChangePasswordTab> createState() => _ChangePasswordTabState();
}

class _ChangePasswordTabState extends State<ChangePasswordTab> {
  final _formKey = GlobalKey<FormState>();
  final _oldPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  bool _obscureOld = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _updatePassword() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception("User not logged in");

      final cred = EmailAuthProvider.credential(
        email: user.email!,
        password: _oldPasswordController.text,
      );

      await user.reauthenticateWithCredential(cred);
      await user.updatePassword(_newPasswordController.text);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password updated successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        _formKey.currentState!.reset();
        _oldPasswordController.clear();
        _newPasswordController.clear();
        _confirmPasswordController.clear();
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        final theme = Theme.of(context);
        String title = 'Error';
        String message = 'Something went wrong.';
        if (e.code == 'wrong-password') {
          title = 'Wrong Password';
          message = 'The current password you entered is incorrect.';
        } else if (e.code == 'weak-password') {
          title = 'Weak Password';
          message = 'The new password is too weak.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: theme.colorScheme.errorContainer,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(message, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.security_rounded,
              size: 80,
              color: Colors.blueAccent,
            ).animate().scale(duration: 600.ms, curve: Curves.easeOutBack),
            const SizedBox(height: 24),
            Text(
              'Secure Your Account',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 40),
            TextFormField(
              controller: _oldPasswordController,
              obscureText: _obscureOld,
              decoration: InputDecoration(
                labelText: 'Current Password',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureOld ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _obscureOld = !_obscureOld),
                ),
              ),
              validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _newPasswordController,
              obscureText: _obscureNew,
              decoration: InputDecoration(
                labelText: 'New Password',
                prefixIcon: const Icon(Icons.password_rounded),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureNew ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _obscureNew = !_obscureNew),
                ),
              ),
              validator: (v) =>
                  (v == null || v.length < 6) ? 'Min 6 chars' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirmPasswordController,
              obscureText: _obscureConfirm,
              decoration: InputDecoration(
                labelText: 'Confirm New Password',
                prefixIcon: const Icon(Icons.check_circle_outline_rounded),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureConfirm ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
              validator: (v) =>
                  (v != _newPasswordController.text) ? 'Mismatch' : null,
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isLoading ? null : _updatePassword,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
              child: _isLoading
                  ? const CircularProgressIndicator()
                  : const Text(
                      'Update Password',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
