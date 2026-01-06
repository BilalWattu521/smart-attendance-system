# Smart Attendance App 🚀

A modern, biometric-based attendance management system built with Flutter and Firebase. This application leverages facial recognition and geofencing technology to ensure accurate, secure, and location-aware attendance tracking for educational institutions.

## 🌟 Key Features

### 🔐 Multi-Role Authentication
- **Secure Login**: Personalized access for both Administrators and Students.
- **Role-Based Routing**: Dynamic dashboard loading based on user permissions.
- **Password Management**: Full support for updating credentials with secure re-authentication inside the dashboard.

### 🛡️ Admin Dashboard (Management Powerhouse)
- **User Management**: Create and manage student accounts directly from a dedicated tab.
- **Real-Time Verification**: Live stream of pending attendance requests with badge counters.
- **Historical Records**: Filterable and searchable attendance history for all students.
- **Biometric Verification**: One-tap face matching using AI to verify student identity against their enrolled baseline.

### 👨‍🎓 Student Dashboard (Personalized Hub)
- **Drawer Navigation**: Modern drawer for easy navigation between Home, Map, and Attendance.
- **Smart Home Screen**: Personalized welcome message and real-time status display (Location, Enrollment, Attendance).
- **Biometric Enrollment**: Guided face enrollment interface with pulsing scan animations.
- **Campus Map**: Interactive map showing your current location relative to the campus geofence boundary.

### 🗺️ Geofencing & Location Awareness
- **Distance Tracking**: Real-time distance calculation (in meters) between the student and campus center.
- **Automated Validation**: Restricts attendance marking to students physically present within the predefined campus radius.
- **Midnight Reset**: Automatic status reset at 12:00 AM daily, allowing for fresh attendance requests every day.

### 🎨 Premium UI/UX
- **Material 3 Design**: Clean, vibrant, and follows modern design tokens.
- **Fluid Animations**: Strategic use of `flutter_animate` for entrance effects and state transitions.
- **Responsive Layouts**: Optimized for a wide range of mobile devices.

## 📱 Permissions Required
- **Camera**: For capturing biometric data for enrollment and verification.
- **Location**: For validating presence within the campus geofence.
- **Storage**: Required for camera buffer and AI model inference.

## 🛠️ Tech Stack
- **Framework**: [Flutter](https://flutter.dev/) (Dart)
- **Backend**: [Firebase](https://firebase.google.com/) (Auth, Firestore)
- **AI/ML**: Google ML Kit (Face Detection) + TFLite (MobileFaceNet for Embeddings)
- **Maps**: [Flutter Map](https://pub.dev/packages/flutter_map) + OpenStreetMap

## 🚀 Getting Started

### Installation
1. **Clone the repository**
   ```bash
   git clone https://github.com/BilalWattu521/smart-attendance-system.git
   ```
2. **Setup Firebase**
   - Add your `google-services.json` to `android/app/`.
   - Enable Email/Password Auth in Firebase Console.
   - Deploy Firestore rules to allow user-based access.
3. **Download Model**
   - Ensure `mobilefacenet.tflite` is present in the `assets/` folder.
4. **Run**
   ```bash
   flutter pub get
   ```


## Developed By: Muhammad Bilal Ahmed
