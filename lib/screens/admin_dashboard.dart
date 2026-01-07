import 'package:attendance_app/screens/face_verification_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({
    super.key,
    required this.currentUser,
    required this.role,
    required this.isRootAdmin,
  });

  final User currentUser;
  final String role;
  final bool isRootAdmin;

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  int _selectedIndex = 0;

  final List<Widget> _screens = [
    const CreateUserTab(),
    const UserManagementTab(),
    const PendingVerificationTab(),
    const HistoryTab(),
    const ChangePasswordTab(),
  ];

  final List<String> _titles = const [
    'Provision Account',
    'User Management',
    'Pending Verification',
    'Attendance History',
    'Security Settings',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _titles[_selectedIndex],
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: false,
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
                    radius: 28,
                    backgroundColor: theme.colorScheme.primary,
                    child: const Icon(
                      Icons.admin_panel_settings_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Administrator',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onPrimaryContainer,
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
              icon: Icons.person_add_rounded,
              label: 'Create Account',
            ),
            _buildDrawerItem(
              index: 1,
              icon: Icons.people_alt_rounded,
              label: 'User Management',
            ),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('attendance_requests')
                  .where('status', isEqualTo: 'pending')
                  .snapshots(),
              builder: (context, snapshot) {
                final count = snapshot.data?.docs.length ?? 0;
                return _buildDrawerItem(
                  index: 2,
                  icon: Icons.fact_check_rounded,
                  label: 'Pending Verification',
                  trailing: count > 0
                      ? Badge(
                          label: Text(count.toString()),
                          backgroundColor: theme.colorScheme.error,
                        )
                      : null,
                );
              },
            ),
            _buildDrawerItem(
              index: 3,
              icon: Icons.history_rounded,
              label: 'History',
            ),
            _buildDrawerItem(
              index: 4,
              icon: Icons.lock_reset_rounded,
              label: 'Change Password',
            ),
            const Spacer(),
            const Divider(indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Logout'),
              onTap: () => FirebaseAuth.instance.signOut(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
      body: _screens[_selectedIndex],
    );
  }

  Widget _buildDrawerItem({
    required int index,
    required IconData icon,
    required String label,
    Widget? trailing,
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
      trailing: trailing,
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.3,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      onTap: () {
        setState(() => _selectedIndex = index);
        Navigator.pop(context); // Close drawer
      },
    );
  }
}

class PendingVerificationTab extends StatefulWidget {
  const PendingVerificationTab({super.key});

  @override
  State<PendingVerificationTab> createState() => _PendingVerificationTabState();
}

class _PendingVerificationTabState extends State<PendingVerificationTab> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search by student email...',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _searchQuery = '';
                        });
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value.toLowerCase().trim();
              });
            },
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('attendance_requests')
                .where('status', isEqualTo: 'pending')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
              }

              var docs = snapshot.data?.docs ?? [];

              // Client-side filtering
              if (_searchQuery.isNotEmpty) {
                docs = docs.where((doc) {
                  final email = (doc.data()['studentEmail'] as String? ?? '')
                      .toLowerCase();
                  return email.contains(_searchQuery);
                }).toList();
              }

              // Sorting
              final sortedDocs =
                  List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(docs);
              sortedDocs.sort((a, b) {
                final aTime = (a.data())['requestedAt'] as Timestamp?;
                final bTime = (b.data())['requestedAt'] as Timestamp?;
                if (aTime == null) return 1;
                if (bTime == null) return -1;
                return bTime.compareTo(aTime);
              });

              if (sortedDocs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _searchQuery.isEmpty
                            ? Icons.inbox_rounded
                            : Icons.search_off_rounded,
                        size: 64,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _searchQuery.isEmpty
                            ? 'No pending requests'
                            : 'No matches found for "$_searchQuery"',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: sortedDocs.length,
                itemBuilder: (context, index) {
                  final doc = sortedDocs[index];
                  final data = doc.data();
                  final name = data['studentName'] ?? 'Unknown';
                  final email = data['studentEmail'] ?? '';
                  final requestedAt = (data['requestedAt'] as Timestamp?)
                      ?.toDate();

                  return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(16),
                          leading: CircleAvatar(
                            backgroundColor: theme.colorScheme.primaryContainer,
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                              style: TextStyle(
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text(
                              '$email\nRequested: ${requestedAt?.toString().split('.')[0] ?? ''}',
                            ),
                          ),
                          isThreeLine: true,
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.onPrimary,
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => FaceVerificationScreen(
                                    studentUid: data['studentUid'],
                                    studentName: name,
                                    requestId: doc.id,
                                  ),
                                ),
                              );
                            },
                            child: const Text('Verify'),
                          ),
                        ),
                      )
                      .animate()
                      .fadeIn(delay: (index * 50).ms)
                      .moveX(begin: 20, end: 0);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class CreateUserTab extends StatefulWidget {
  const CreateUserTab({super.key});

  @override
  State<CreateUserTab> createState() => _CreateUserTabState();
}

class _CreateUserTabState extends State<CreateUserTab> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String _role = 'student';
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _message;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _createUser() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      final currentAdmin = FirebaseAuth.instance.currentUser;
      if (currentAdmin == null) throw Exception("No admin logged in");

      final tempApp = await Firebase.initializeApp(
        name: 'userCreation_${DateTime.now().millisecondsSinceEpoch}',
      );

      final tempAuth = FirebaseAuth.instanceFor(app: tempApp);
      final credential = await tempAuth.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      final uid = credential.user?.uid;
      if (uid == null) throw Exception('Failed to retrieve new user UID');

      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'name': _nameController.text.trim(),
        'email': _emailController.text.trim(),
        'role': _role,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': currentAdmin.uid,
        'isRootAdmin': false,
      });

      await tempApp.delete();

      if (mounted) {
        setState(() {
          _message = 'User created successfully!';
        });
        _formKey.currentState!.reset();
        _role = 'student';
        _nameController.clear();
        _emailController.clear();
        _passwordController.clear();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = 'Error: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Provision New Account', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Enter the student or admin details below.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 32),
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    hintText: 'Full Name',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                  validator: (value) => (value == null || value.isEmpty)
                      ? 'Name is required'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    hintText: 'Email Address',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Email is required';
                    }
                    if (!value.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    hintText: 'Temporary Password',
                    prefixIcon: const Icon(Icons.vpn_key_outlined),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                  ),
                  obscureText: _obscurePassword,
                  validator: (value) => (value != null && value.length < 6)
                      ? 'Min 6 characters'
                      : null,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _role,
                  decoration: const InputDecoration(
                    hintText: 'Assign Role',
                    prefixIcon: Icon(Icons.shield_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'admin',
                      child: Text('Administrator'),
                    ),
                    DropdownMenuItem(value: 'student', child: Text('Student')),
                  ],
                  onChanged: (value) => setState(() => _role = value!),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _createUser,
                    icon: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.person_add_alt_1_rounded),
                    label: const Text('CREATE ACCOUNT'),
                  ),
                ),
              ],
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _message!.startsWith('Error')
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    _message!.startsWith('Error')
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    color: _message!.startsWith('Error')
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _message!,
                      style: TextStyle(
                        color: _message!.startsWith('Error')
                            ? theme.colorScheme.onErrorContainer
                            : theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn().shake(duration: 300.ms),
          ],
        ],
      ),
    ).animate().fadeIn(duration: 400.ms);
  }
}

class UserManagementTab extends StatelessWidget {
  const UserManagementTab({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Students'),
              Tab(text: 'Administrators'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _UserList(role: 'student'),
                _UserList(role: 'admin'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UserList extends StatelessWidget {
  final String role;
  const _UserList({required this.role});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .where('role', isEqualTo: role)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
            child: Text(
              'No ${role}s found.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          );
        }

        // Sort A to Z
        final sortedDocs = List.from(docs);
        sortedDocs.sort((a, b) {
          final aName = (a.data() as Map)['name'] as String? ?? '';
          final bName = (b.data() as Map)['name'] as String? ?? '';
          return aName.toLowerCase().compareTo(bName.toLowerCase());
        });

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: sortedDocs.length,
          itemBuilder: (context, index) {
            final data = sortedDocs[index].data();
            final name = data['name'] as String? ?? 'Unknown';
            final email = data['email'] as String? ?? '';
            final isRootAdmin = (data['isRootAdmin'] as bool?) ?? false;

            final isAdmin = role == 'admin' || isRootAdmin;

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: isAdmin
                      ? theme.colorScheme.tertiaryContainer
                      : theme.colorScheme.secondaryContainer,
                  child: Icon(
                    isAdmin
                        ? Icons.admin_panel_settings_rounded
                        : Icons.person_rounded,
                    color: isAdmin
                        ? theme.colorScheme.onTertiaryContainer
                        : theme.colorScheme.onSecondaryContainer,
                  ),
                ),
                title: Text(
                  name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(email),
                trailing: isRootAdmin
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.deepPurple.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.deepPurple.withValues(alpha: 0.2),
                          ),
                        ),
                        child: const Text(
                          'ROOT',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.deepPurple,
                          ),
                        ),
                      )
                    : null,
              ),
            ).animate().fadeIn(delay: (index * 30).ms).moveY(begin: 10, end: 0);
          },
        );
      },
    );
  }
}

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  DateTime _selectedDate = DateTime.now();

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startOfDay = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    final endOfDay = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      23,
      59,
      59,
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              const Icon(Icons.calendar_today_rounded, size: 20),
              const SizedBox(width: 12),
              Text(
                '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _selectDate(context),
                icon: const Icon(Icons.edit_calendar_rounded),
                label: const Text('Change Date'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('attendance_requests')
                .where('status', isEqualTo: 'verified')
                .where(
                  'verifiedAt',
                  isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay),
                )
                .where(
                  'verifiedAt',
                  isLessThanOrEqualTo: Timestamp.fromDate(endOfDay),
                )
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
              }

              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.history_toggle_off_rounded,
                        size: 64,
                        color: theme.colorScheme.outline.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No attendance records found.',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final data = docs[index].data();
                  final studentName =
                      data['studentName'] as String? ?? 'Student';
                  final studentEmail = data['studentEmail'] as String? ?? '';
                  final verifiedAt = data['verifiedAt'] as Timestamp?;
                  final timeStr = verifiedAt != null
                      ? "${verifiedAt.toDate().hour.toString().padLeft(2, '0')}:${verifiedAt.toDate().minute.toString().padLeft(2, '0')}"
                      : '--:--';

                  return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: theme.colorScheme.primaryContainer,
                            child: Text(
                              studentName.isNotEmpty
                                  ? studentName[0].toUpperCase()
                                  : 'S',
                              style: TextStyle(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          title: Text(
                            studentName,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(studentEmail),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text(
                                'VERIFIED',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green,
                                ),
                              ),
                              Text(timeStr, style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      )
                      .animate()
                      .fadeIn(delay: (index * 30).ms)
                      .moveY(begin: 10, end: 0);
                },
              );
            },
          ),
        ),
      ],
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

      // 1. Re-authenticate user with old password
      final cred = EmailAuthProvider.credential(
        email: user.email!,
        password: _oldPasswordController.text,
      );

      await user.reauthenticateWithCredential(cred);

      // 2. Update password
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
        String message = 'Something went wrong. Please try again.';
        IconData icon = Icons.error_outline_rounded;

        if (e.code == 'wrong-password') {
          title = 'Wrong Password';
          message = 'The current password you entered is incorrect.';
          icon = Icons.lock_reset_rounded;
        } else if (e.code == 'weak-password') {
          title = 'Weak Password';
          message = 'The new password is too weak.';
          icon = Icons.warning_amber_rounded;
        } else if (e.code == 'network-request-failed') {
          title = 'Network Error';
          message = 'Please check your internet connection.';
          icon = Icons.wifi_off_rounded;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.red,
            content: Row(
              children: [
                Icon(icon, color: theme.colorScheme.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                      Text(
                        message,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                ),
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
            backgroundColor: Theme.of(context).colorScheme.error,
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
            const SizedBox(height: 8),
            Text(
              'Update your password to keep your administrator account secure.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 40),

            // Old Password
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
              validator: (v) =>
                  (v == null || v.isEmpty) ? 'Enter current password' : null,
            ),
            const SizedBox(height: 20),

            // New Password
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
              validator: (v) {
                if (v == null || v.isEmpty) return 'Enter new password';
                if (v.length < 6) {
                  return 'Password must be at least 6 characters';
                }
                return null;
              },
            ),
            const SizedBox(height: 20),

            // Confirm Password
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
              validator: (v) {
                if (v != _newPasswordController.text) {
                  return 'Passwords do not match';
                }
                return null;
              },
            ),
            const SizedBox(height: 40),

            ElevatedButton(
              onPressed: _isLoading ? null : _updatePassword,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
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
