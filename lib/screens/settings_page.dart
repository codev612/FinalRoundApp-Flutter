import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io' show Platform;
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../providers/shortcuts_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../services/shortcuts_service.dart';
import '../services/appearance_service.dart';
import '../services/billing_service.dart';
import '../providers/speech_to_text_provider.dart';
import 'email_change_verification_dialog.dart';
import 'manage_mode_page.dart';
import 'manage_question_templates_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Left sidebar
        Container(
          width: 200,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              right: BorderSide(
                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
              ),
            ),
          ),
          child: _buildSidebar(),
        ),
        // Main content area
        Expanded(
          child: _buildContent(),
        ),
      ],
    );
  }

  Widget _buildSidebar() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _SidebarItem(
                icon: Icons.person,
                label: 'Profile',
                isSelected: _selectedIndex == 0,
                onTap: () => setState(() => _selectedIndex = 0),
              ),
              _SidebarItem(
                icon: Icons.keyboard,
                label: 'Shortcuts',
                isSelected: _selectedIndex == 1,
                onTap: () => setState(() => _selectedIndex = 1),
              ),
              _SidebarItem(
                icon: Icons.mic,
                label: 'Audio',
                isSelected: _selectedIndex == 2,
                onTap: () => setState(() => _selectedIndex = 2),
              ),
              _SidebarItem(
                icon: Icons.credit_card,
                label: 'Plan & Usage',
                isSelected: _selectedIndex == 3,
                onTap: () => setState(() => _selectedIndex = 3),
              ),
              _SidebarItem(
                icon: Icons.tune,
                label: 'Modes',
                isSelected: false,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ManageModePage()),
                  );
                },
              ),
              _SidebarItem(
                icon: Icons.quiz,
                label: 'Questions',
                isSelected: false,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ManageQuestionTemplatesPage()),
                  );
                },
              ),
              if (Platform.isWindows)
                _SidebarItem(
                  icon: Icons.palette,
                  label: 'Appearance',
                  isSelected: _selectedIndex == 4,
                  onTap: () => setState(() => _selectedIndex = 4),
                ),
            ],
          ),
        ),
        // Sign out button at bottom
        Consumer<AuthProvider>(
          builder: (context, authProvider, child) {
            return Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
              ),
              child: ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign Out'),
                onTap: () async {
                  await authProvider.signOut();
                  // Navigation will happen automatically via AppShell listening to auth state
                },
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildContent() {
    return Consumer<ShortcutsProvider>(
      builder: (context, shortcutsProvider, child) {
        switch (_selectedIndex) {
          case 0:
            return _buildProfileContent();
          case 1:
            return _buildShortcutsContent(shortcutsProvider);
          case 2:
            return _buildAudioDevicesContent();
          case 3:
            return const _PlanUsageSettings();
          case 4:
            return Platform.isWindows ? _buildAppearanceContent() : const _PlanUsageSettings();
          default:
            return _buildProfileContent();
        }
      },
    );
  }

  Widget _buildProfileContent() {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, child) {
        // Refresh user info when profile section is opened
        WidgetsBinding.instance.addPostFrameCallback((_) {
          authProvider.refreshUserInfo();
        });

        return _ProfileEditForm(authProvider: authProvider);
      },
    );
  }

  Widget _buildShortcutsContent(ShortcutsProvider shortcutsProvider) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                'Keyboard Shortcuts',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () async {
                await shortcutsProvider.resetToDefaults();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Shortcuts reset to defaults')),
                  );
                }
              },
              child: const Text('Reset to Defaults'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ShortcutTile(
          label: 'Toggle Record',
          action: 'toggleRecord',
          shortcutsProvider: shortcutsProvider,
        ),
        _ShortcutTile(
          label: 'Ask AI',
          action: 'askAi',
          shortcutsProvider: shortcutsProvider,
        ),
        _ShortcutTile(
          label: 'Save Session',
          action: 'saveSession',
          shortcutsProvider: shortcutsProvider,
        ),
        _ShortcutTile(
          label: 'Export Session',
          action: 'exportSession',
          shortcutsProvider: shortcutsProvider,
        ),
        _ShortcutTile(
          label: 'Mark Moment',
          action: 'markMoment',
          shortcutsProvider: shortcutsProvider,
        ),
        if (Platform.isWindows)
          _ShortcutTile(
            label: 'Toggle Hide/Show',
            action: 'toggleHide',
            shortcutsProvider: shortcutsProvider,
          ),
      ],
    );
  }

  Widget _buildAppearanceContent() {
    return _AppearanceSettings();
  }

  Widget _buildAudioDevicesContent() {
    return _AudioDeviceSettings();
  }
}

class _AudioDeviceSettings extends StatefulWidget {
  const _AudioDeviceSettings();

  @override
  State<_AudioDeviceSettings> createState() => _AudioDeviceSettingsState();
}

class _AudioDeviceSettingsState extends State<_AudioDeviceSettings> {
  final AudioRecorder _recorder = AudioRecorder();
  List<InputDevice> _devices = [];
  String? _selectedDeviceId;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _loadSelectedDevice();
  }

  Future<void> _loadDevices() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final devices = await _recorder.listInputDevices();
      if (mounted) {
        setState(() {
          _devices = devices;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load audio devices: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadSelectedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedDeviceId = prefs.getString('selected_audio_device_id');
      if (mounted && savedDeviceId != null) {
        setState(() {
          _selectedDeviceId = savedDeviceId;
        });
      }
    } catch (e) {
      print('[AudioDeviceSettings] Error loading selected device: $e');
    }
  }

  Future<void> _selectDevice(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_audio_device_id', deviceId);
      if (mounted) {
        setState(() {
          _selectedDeviceId = deviceId;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Audio device selected. Restart recording to apply changes.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save device selection: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Text(
              'Audio Devices',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh devices',
              onPressed: _loadDevices,
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Select the microphone/input device to use for recording',
          style: TextStyle(fontSize: 14, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        if (_isLoading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24.0),
              child: CircularProgressIndicator(),
            ),
          )
        else if (_errorMessage != null)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.error, color: Theme.of(context).colorScheme.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          )
        else if (_devices.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.info),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No audio input devices found',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          ..._devices.map((device) {
            final isSelected = _selectedDeviceId == device.id;
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: RadioListTile<String>(
                title: Text(device.label),
                subtitle: device.id.isNotEmpty
                    ? Text(
                        'ID: ${device.id}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      )
                    : null,
                value: device.id,
                groupValue: _selectedDeviceId,
                onChanged: (value) {
                  if (value != null) {
                    _selectDevice(value);
                  }
                },
                secondary: Icon(
                  isSelected ? Icons.mic : Icons.mic_none,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            );
          }),
        const SizedBox(height: 16),
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.info,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Note',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'The selected device will be used the next time you start recording. '
                  'If no device is selected, the system default will be used.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? theme.colorScheme.primaryContainer
                  : _isHovered
                      ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8)
                      : Colors.transparent,
              border: widget.isSelected
                  ? Border(
                      right: BorderSide(
                        color: theme.colorScheme.primary,
                        width: 3,
                      ),
                    )
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  size: 20,
                  color: widget.isSelected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 12),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: widget.isSelected ? FontWeight.w600 : FontWeight.normal,
                    color: widget.isSelected
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortcutTile extends StatefulWidget {
  final String label;
  final String action;
  final ShortcutsProvider shortcutsProvider;

  const _ShortcutTile({
    required this.label,
    required this.action,
    required this.shortcutsProvider,
  });

  @override
  State<_ShortcutTile> createState() => _ShortcutTileState();
}

class _ShortcutTileState extends State<_ShortcutTile> {
  bool _isCapturing = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _captureShortcut() async {
    setState(() => _isCapturing = true);
    
    final shortcut = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ShortcutCaptureDialog(
        currentShortcut: widget.shortcutsProvider.getShortcut(widget.action),
      ),
    );
    
    setState(() => _isCapturing = false);
    
    if (shortcut != null && shortcut.isNotEmpty) {
      await widget.shortcutsProvider.setShortcut(widget.action, shortcut);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Shortcut updated: $shortcut')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final shortcutString = widget.shortcutsProvider.getShortcut(widget.action);
    
    return ListTile(
      leading: const Icon(Icons.keyboard),
      title: Text(widget.label),
      subtitle: Text(
        shortcutString.isEmpty ? 'Not set' : shortcutString,
        style: TextStyle(
          color: shortcutString.isEmpty 
              ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)
              : Theme.of(context).colorScheme.primary,
          fontFamily: 'monospace',
        ),
      ),
      trailing: _isCapturing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit shortcut',
              iconSize: 20,
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
              onPressed: _captureShortcut,
            ),
    );
  }
}

class _ShortcutCaptureDialog extends StatefulWidget {
  final String currentShortcut;

  const _ShortcutCaptureDialog({required this.currentShortcut});

  @override
  State<_ShortcutCaptureDialog> createState() => _ShortcutCaptureDialogState();
}

class _ShortcutCaptureDialogState extends State<_ShortcutCaptureDialog> {
  String _capturedShortcut = '';
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  String _formatKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return '';
    
    final parts = <String>[];
    final keyboardState = HardwareKeyboard.instance;
    
    if (keyboardState.isControlPressed) parts.add('Control');
    if (keyboardState.isShiftPressed) parts.add('Shift');
    if (keyboardState.isAltPressed) parts.add('Alt');
    if (keyboardState.isMetaPressed) parts.add('Meta');
    
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      parts.add('Enter');
    } else if (event.logicalKey == LogicalKeyboardKey.space) {
      parts.add('Space');
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      parts.add('Escape');
    } else {
      final keyLabel = event.logicalKey.keyLabel.toUpperCase();
      if (keyLabel.length == 1 && keyLabel.codeUnitAt(0) >= 65 && keyLabel.codeUnitAt(0) <= 90) {
        parts.add('Key$keyLabel');
      } else {
        parts.add(keyLabel);
      }
    }
    
    return parts.join('+');
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: (event) {
        if (event is KeyDownEvent) {
          final shortcut = _formatKeyEvent(event);
          if (shortcut.isNotEmpty && !shortcut.contains('Escape')) {
            setState(() => _capturedShortcut = shortcut);
          }
        }
      },
      child: AlertDialog(
        title: const Text('Capture Shortcut'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Press the key combination for "${widget.currentShortcut}"'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              child: Text(
                _capturedShortcut.isEmpty ? 'Press keys...' : _capturedShortcut,
                style: TextStyle(
                  fontSize: 16,
                  fontFamily: 'monospace',
                  color: _capturedShortcut.isEmpty
                      ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Current: ${widget.currentShortcut.isEmpty ? "Not set" : widget.currentShortcut}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: _capturedShortcut.isEmpty
                ? null
                : () => Navigator.of(context).pop(_capturedShortcut),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _ProfileEditForm extends StatefulWidget {
  final AuthProvider authProvider;

  const _ProfileEditForm({required this.authProvider});

  @override
  State<_ProfileEditForm> createState() => _ProfileEditFormState();
}

class _ProfileEditFormState extends State<_ProfileEditForm> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _nameFormKey = GlobalKey<FormState>();
  final _emailFormKey = GlobalKey<FormState>();
  final _passwordFormKey = GlobalKey<FormState>();
  bool _isEditingName = false;
  bool _isEditingEmail = false;
  bool _isEditingPassword = false;
  bool _obscureCurrentPassword = true;
  bool _obscureNewPassword = true;
  bool _obscureConfirmPassword = true;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.authProvider.userName ?? '';
    _emailController.text = widget.authProvider.userEmail ?? '';
    widget.authProvider.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.authProvider.removeListener(_onAuthChanged);
    _nameController.dispose();
    _emailController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) {
      setState(() {
        if (!_isEditingName) {
          _nameController.text = widget.authProvider.userName ?? '';
        }
        if (!_isEditingEmail) {
          _emailController.text = widget.authProvider.userEmail ?? '';
        }
      });
    }
  }

  Future<void> _saveName() async {
    if (!_nameFormKey.currentState!.validate()) return;

    final name = _nameController.text.trim();
    if (name == widget.authProvider.userName) {
      setState(() => _isEditingName = false);
      return;
    }

    final error = await widget.authProvider.updateProfile(name: name);
    if (mounted) {
      if (error == null) {
        setState(() => _isEditingName = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Name updated successfully')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $error')),
        );
      }
    }
  }

  Future<void> _saveEmail() async {
    if (!_emailFormKey.currentState!.validate()) return;

    final email = _emailController.text.trim();
    if (email == widget.authProvider.userEmail) {
      setState(() => _isEditingEmail = false);
      return;
    }

    final error = await widget.authProvider.updateProfile(email: email);
    if (mounted) {
      if (error != null && error.startsWith('PENDING_EMAIL:')) {
        // Extract pending email
        final pendingEmail = error.substring('PENDING_EMAIL:'.length);
        // Show verification dialog
        final result = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => EmailChangeVerificationDialog(
            currentEmail: widget.authProvider.userEmail ?? '',
            newEmail: pendingEmail,
            authProvider: widget.authProvider,
          ),
        );
        if (result == true) {
          setState(() {
            _isEditingEmail = false;
            _emailController.text = pendingEmail;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Email changed successfully!')),
          );
        } else {
          // User cancelled, reset email field
          _emailController.text = widget.authProvider.userEmail ?? '';
        }
      } else if (error == null) {
        setState(() => _isEditingEmail = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated successfully')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $error')),
        );
      }
    }
  }

  Future<void> _savePassword() async {
    if (!_passwordFormKey.currentState!.validate()) return;

    final error = await widget.authProvider.changePassword(
      _currentPasswordController.text,
      _newPasswordController.text,
    );
    if (mounted) {
      if (error == null) {
        setState(() {
          _isEditingPassword = false;
          _currentPasswordController.clear();
          _newPasswordController.clear();
          _confirmPasswordController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password changed successfully')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Profile',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 24),
        // Name field
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.person),
                    const SizedBox(width: 8),
                    const Text(
                      'Full Name',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const Spacer(),
                    if (!_isEditingName)
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => setState(() => _isEditingName = true),
                        tooltip: 'Edit name',
                      )
                    else
                      Consumer<AuthProvider>(
                        builder: (context, authProvider, child) {
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: authProvider.isLoading ? null : () {
                                  setState(() {
                                    _isEditingName = false;
                                    _nameController.text = widget.authProvider.userName ?? '';
                                  });
                                },
                                child: const Text('Cancel'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: authProvider.isLoading ? null : _saveName,
                                child: authProvider.isLoading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Text('Save'),
                              ),
                            ],
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_isEditingName)
                  Form(
                    key: _nameFormKey,
                    child: TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'Enter your full name',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Name is required';
                        }
                        if (value.trim().length < 2) {
                          return 'Name must be at least 2 characters';
                        }
                        return null;
                      },
                      autofocus: true,
                    ),
                  )
                else
                  Text(
                    widget.authProvider.userName ?? 'Not set',
                    style: TextStyle(
                      fontSize: 16,
                      color: widget.authProvider.userName == null
                          ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Email field
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.email),
                    const SizedBox(width: 8),
                    const Text(
                      'Email',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 8),
                    if (widget.authProvider.emailVerified == true)
                      Icon(
                        Icons.verified,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    const Spacer(),
                    if (!_isEditingEmail)
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => setState(() => _isEditingEmail = true),
                        tooltip: 'Edit email',
                      )
                    else
                      Consumer<AuthProvider>(
                        builder: (context, authProvider, child) {
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: authProvider.isLoading ? null : () {
                                  setState(() {
                                    _isEditingEmail = false;
                                    _emailController.text = widget.authProvider.userEmail ?? '';
                                  });
                                },
                                child: const Text('Cancel'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: authProvider.isLoading ? null : _saveEmail,
                                child: authProvider.isLoading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Text('Save'),
                              ),
                            ],
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_isEditingEmail)
                  Form(
                    key: _emailFormKey,
                    child: TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        hintText: 'Enter your email',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Email is required';
                        }
                        final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
                        if (!emailRegex.hasMatch(value.trim())) {
                          return 'Invalid email format';
                        }
                        return null;
                      },
                      autofocus: true,
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.authProvider.userEmail ?? 'Not set',
                        style: TextStyle(
                          fontSize: 16,
                          color: widget.authProvider.userEmail == null
                              ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)
                              : null,
                        ),
                      ),
                      if (widget.authProvider.emailVerified != true)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Email not verified',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Password field
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lock),
                    const SizedBox(width: 8),
                    const Text(
                      'Password',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const Spacer(),
                    if (!_isEditingPassword)
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => setState(() => _isEditingPassword = true),
                        tooltip: 'Change password',
                      )
                    else
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _isEditingPassword = false;
                            _currentPasswordController.clear();
                            _newPasswordController.clear();
                            _confirmPasswordController.clear();
                          });
                        },
                        child: const Text('Cancel'),
                      ),
                  ],
                ),
                if (_isEditingPassword) ...[
                  const SizedBox(height: 16),
                  Form(
                    key: _passwordFormKey,
                    child: Column(
                      children: [
                        TextFormField(
                          controller: _currentPasswordController,
                          decoration: InputDecoration(
                            labelText: 'Current Password',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureCurrentPassword ? Icons.visibility : Icons.visibility_off,
                              ),
                              onPressed: () {
                                setState(() => _obscureCurrentPassword = !_obscureCurrentPassword);
                              },
                            ),
                          ),
                          obscureText: _obscureCurrentPassword,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Current password is required';
                            }
                            return null;
                          },
                          autofocus: true,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _newPasswordController,
                          decoration: InputDecoration(
                            labelText: 'New Password',
                            hintText: 'At least 8 characters',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureNewPassword ? Icons.visibility : Icons.visibility_off,
                              ),
                              onPressed: () {
                                setState(() => _obscureNewPassword = !_obscureNewPassword);
                              },
                            ),
                          ),
                          obscureText: _obscureNewPassword,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'New password is required';
                            }
                            if (value.length < 8) {
                              return 'Password must be at least 8 characters';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _confirmPasswordController,
                          decoration: InputDecoration(
                            labelText: 'Confirm New Password',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureConfirmPassword ? Icons.visibility : Icons.visibility_off,
                              ),
                              onPressed: () {
                                setState(() => _obscureConfirmPassword = !_obscureConfirmPassword);
                              },
                            ),
                          ),
                          obscureText: _obscureConfirmPassword,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please confirm your password';
                            }
                            if (value != _newPasswordController.text) {
                              return 'Passwords do not match';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        Consumer<AuthProvider>(
                          builder: (context, authProvider, child) {
                            return SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: authProvider.isLoading ? null : _savePassword,
                                child: authProvider.isLoading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Text('Change Password'),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AppearanceSettings extends StatefulWidget {
  const _AppearanceSettings();

  @override
  State<_AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<_AppearanceSettings> {
  bool _undetectable = false;
  bool _skipTaskbar = true;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    final undetectable = await AppearanceService.getUndetectable();
    final skipTaskbar = await AppearanceService.getSkipTaskbar();
    setState(() {
      _undetectable = undetectable;
      _skipTaskbar = skipTaskbar;
      _isLoading = false;
    });
  }

  Future<void> _onUndetectableChanged(bool value) async {
    setState(() => _undetectable = value);
    await AppearanceService.setUndetectable(value);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(value 
            ? 'Window is now undetectable in screen sharing'
            : 'Window is now detectable in screen sharing'),
        ),
      );
    }
  }

  Future<void> _onSkipTaskbarChanged(bool value) async {
    setState(() => _skipTaskbar = value);
    await AppearanceService.setSkipTaskbar(value);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(value 
            ? 'Taskbar icon hidden'
            : 'Taskbar icon shown'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Appearance',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 24),
        if (_isLoading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24.0),
              child: CircularProgressIndicator(),
            ),
          )
        else ...[
          Card(
            child: SwitchListTile(
              title: const Text('Undetectable in Screen Sharing'),
              subtitle: const Text(
                'Hide the window from screen capture and screen sharing applications',
              ),
              value: _undetectable,
              onChanged: _onUndetectableChanged,
              secondary: const Icon(Icons.visibility_off),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              title: const Text('Hide Taskbar Icon'),
              subtitle: const Text(
                'Hide the app icon from the Windows taskbar',
              ),
              value: _skipTaskbar,
              onChanged: _onSkipTaskbarChanged,
              secondary: const Icon(Icons.task_alt),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Consumer<ThemeProvider>(
              builder: (context, themeProvider, child) {
                // Avoid ExpansionTile on Windows here: it triggers an accessibility "announce"
                // message that can spam the console with:
                // "Announce message 'viewId' property must be a FlutterViewId."
                //
                // This custom expandable card keeps the UX but doesn't call announce.
                return _ThemeModeCard(
                  label: _getThemeModeLabel(themeProvider.themeMode),
                  value: themeProvider.themeMode,
                  onChanged: (mode) => themeProvider.setThemeMode(mode, context: context),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  String _getThemeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
      case ThemeMode.system:
        return 'System';
    }
  }
}

class _ThemeModeCard extends StatefulWidget {
  final String label;
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeModeCard({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_ThemeModeCard> createState() => _ThemeModeCardState();
}

class _ThemeModeCardState extends State<_ThemeModeCard> with TickerProviderStateMixin {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.palette),
          title: const Text('Theme'),
          subtitle: Text(widget.label),
          trailing: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Column(
                  children: [
                    RadioListTile<ThemeMode>(
                      title: const Text('Light'),
                      value: ThemeMode.light,
                      groupValue: widget.value,
                      onChanged: (value) {
                        if (value == null) return;
                        widget.onChanged(value);
                      },
                    ),
                    RadioListTile<ThemeMode>(
                      title: const Text('Dark'),
                      value: ThemeMode.dark,
                      groupValue: widget.value,
                      onChanged: (value) {
                        if (value == null) return;
                        widget.onChanged(value);
                      },
                    ),
                    RadioListTile<ThemeMode>(
                      title: const Text('System'),
                      value: ThemeMode.system,
                      groupValue: widget.value,
                      onChanged: (value) {
                        if (value == null) return;
                        widget.onChanged(value);
                      },
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _PlanUsageSettings extends StatefulWidget {
  const _PlanUsageSettings();

  @override
  State<_PlanUsageSettings> createState() => _PlanUsageSettingsState();
}

class _PlanUsageSettingsState extends State<_PlanUsageSettings> {
  final BillingService _billing = BillingService();
  bool _loading = false;
  String? _error;
  BillingInfo? _info;
  String? _lastToken;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final token = context.read<AuthProvider>().token;
    if (token != _lastToken) {
      _lastToken = token;
      _billing.setAuthToken(token);
      _refresh();
      
      // Set up plan update callback to refresh billing info when plan changes
      try {
        final speechProvider = context.read<SpeechToTextProvider>();
        speechProvider.setOnPlanUpdated(() {
          if (mounted) {
            _refresh();
          }
        });
      } catch (e) {
        // SpeechToTextProvider might not be available in all contexts, ignore
        print('[PlanUsageSettings] Could not set plan update callback: $e');
      }
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await _billing.getMe();
      if (!mounted) return;
      setState(() {
        _info = info;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _planLabel(String plan) {
    switch (plan.trim().toLowerCase()) {
      case 'pro_plus':
        return 'Pro+';
      case 'pro':
        return 'Pro';
      case 'free':
      default:
        return 'Free';
    }
  }

  String _fmtInt(int n) => n.toString();

  /// Format billing period for display. Server sends [start, end) in UTC
  /// (calendar month). Show date-only in UTC so the period is unambiguous.
  String _formatBillingPeriod(DateTime periodStartUtc, DateTime periodEndUtc) {
    // end is exclusive (first day of next period); last day = end - 1 day
    final lastDayUtc = periodEndUtc.subtract(const Duration(days: 1));
    final y1 = periodStartUtc.year;
    final m1 = periodStartUtc.month.toString().padLeft(2, '0');
    final d1 = periodStartUtc.day.toString().padLeft(2, '0');
    final y2 = lastDayUtc.year;
    final m2 = lastDayUtc.month.toString().padLeft(2, '0');
    final d2 = lastDayUtc.day.toString().padLeft(2, '0');
    return '$y1-$m1-$d1 – $y2-$m2-$d2 (UTC)';
  }

  String _fmtNumber(int n) {
    if (n >= 1000000000) {
      final b = n / 1000000000.0;
      return b % 1 == 0 ? '${b.toInt()}B' : '${b.toStringAsFixed(1)}B';
    } else if (n >= 1000000) {
      final m = n / 1000000.0;
      return m % 1 == 0 ? '${m.toInt()}M' : '${m.toStringAsFixed(1)}M';
    } else if (n >= 1000) {
      final k = n / 1000.0;
      return k % 1 == 0 ? '${k.toInt()}K' : '${k.toStringAsFixed(1)}K';
    }
    return n.toString();
  }

  static const List<String> _planOrder = ['free', 'pro', 'pro_plus'];

  // Keep these in sync with server `PLAN_CONFIGS` (server/src/server.ts).
  static const _PlanOffer _freePlan = _PlanOffer(
    key: 'free',
    name: 'Free',
    price: 0,
    minutesPerMonth: 65,
    aiTokensPerMonth: 50000,
    aiRequestsPerMonth: 200,
    canUseSummary: false,
    allowedModels: ['gpt-4.1-mini', 'gpt-4.1', 'gpt-4o-mini'],
  );
  static const _PlanOffer _proPlan = _PlanOffer(
    key: 'pro',
    name: 'Pro',
    price: 20,
    minutesPerMonth: 600,
    aiTokensPerMonth: 1300000,
    aiRequestsPerMonth: 3000,
    canUseSummary: true,
    allowedModels: ['gpt-5', 'gpt-5.1', 'gpt-4.1', 'gpt-4.1-mini', 'gpt-4o', 'gpt-4o-mini'],
  );
  static const _PlanOffer _proPlusPlan = _PlanOffer(
    key: 'pro_plus',
    name: 'Pro+',
    price: 50,
    minutesPerMonth: 1700,
    aiTokensPerMonth: 3000000,
    aiRequestsPerMonth: 15000,
    canUseSummary: true,
    allowedModels: ['gpt-5.2', 'gpt-5', 'gpt-5.1', 'gpt-4.1', 'gpt-4.1-mini', 'gpt-4o', 'gpt-4o-mini'],
  );

  List<_PlanOffer> _allPlans() => const [_freePlan, _proPlan, _proPlusPlan];

  int _planRank(String planKey) {
    final k = planKey.trim().toLowerCase();
    final idx = _planOrder.indexOf(k);
    return idx < 0 ? 0 : idx;
  }

  List<_PlanOffer> _upgradablePlans(String currentPlanKey) {
    final cur = _planRank(currentPlanKey);
    return _allPlans().where((p) => _planRank(p.key) >= cur).toList(growable: false);
  }

  Future<void> _openBillingPage() async {
    final url = Uri.parse('https://app.finalroundapp.com/dashboard#billing');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open billing page')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening billing page: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final info = _info;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Plan & Usage',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _refresh,
              icon: _loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Card(
            color: cs.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: cs.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: cs.onErrorContainer),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (info == null && _error == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (info != null) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.workspace_premium),
              title: Text('Current plan: ${_planLabel(info.plan)}'),
              subtitle: Text(
                'Billing period: ${_formatBillingPeriod(info.periodStartUtc, info.periodEndUtc)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: info.plan.trim().toLowerCase() != 'free'
                  ? TextButton(
                      onPressed: _openBillingPage,
                      child: const Text('Manage'),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          Text('Plans', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ..._allPlans().map((p) {
            final isCurrent = p.key == info.plan.trim().toLowerCase();
            final isUpgrade = !isCurrent && _planRank(p.key) > _planRank(info.plan);
            final isDowngrade = !isCurrent && _planRank(p.key) < _planRank(info.plan);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: isCurrent ? cs.primary : cs.outline.withValues(alpha: 0.2),
                    width: isCurrent ? 2 : 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p.name,
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                if (p.price > 0)
                                  Text(
                                    '\$${_fmtInt(p.price)}/month',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  )
                                else
                                  Text(
                                    'Free',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (isCurrent)
                            Chip(
                              label: const Text('Current'),
                              backgroundColor: cs.primary.withValues(alpha: 0.12),
                              labelStyle: TextStyle(color: cs.primary, fontWeight: FontWeight.w700),
                              side: BorderSide(color: cs.primary.withValues(alpha: 0.25)),
                            )
                          else if (isUpgrade)
                            FilledButton(
                              onPressed: _openBillingPage,
                              child: const Text('Upgrade'),
                            )
                          else if (isDowngrade)
                            OutlinedButton(
                              onPressed: _openBillingPage,
                              child: const Text('Downgrade'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_fmtNumber(p.minutesPerMonth)} transcription minutes / month',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_fmtNumber(p.aiTokensPerMonth)} AI tokens / month • ${_fmtNumber(p.aiRequestsPerMonth)} requests / month',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        p.canUseSummary ? 'Summary: enabled' : 'Summary: not included',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: p.allowedModels.map((m) => Chip(label: Text(m))).toList(growable: false),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Transcription', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: info.limitMinutes <= 0 ? null : (info.usedMinutes / info.limitMinutes).clamp(0, 1),
                    minHeight: 8,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Used ${_fmtInt(info.usedMinutes)} / ${_fmtInt(info.limitMinutes)} minutes • Remaining ${_fmtInt(info.remainingMinutes)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('AI usage', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                      if (info.canUseSummary == false)
                        Text('Summary disabled on this plan', style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: info.aiLimitTokens <= 0 ? null : (info.aiUsedTokens / info.aiLimitTokens).clamp(0, 1),
                    minHeight: 8,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tokens: ${_fmtInt(info.aiUsedTokens)} / ${_fmtInt(info.aiLimitTokens)} • Remaining ${_fmtInt(info.aiRemainingTokens)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (info.aiLimitRequests != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Requests: ${_fmtInt(info.aiUsedRequests)} / ${_fmtInt(info.aiLimitRequests!)}'
                      '${info.aiRemainingRequests == null ? '' : ' • Remaining ${_fmtInt(info.aiRemainingRequests!)}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text('Allowed models', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: info.allowedModels.isEmpty
                        ? [const Chip(label: Text('None'))]
                        : info.allowedModels.map((m) => Chip(label: Text(m))).toList(growable: false),
                  ),
                ],
              ),
            ),
          ),
          if (info.aiByModel.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('AI by model', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Model')),
                          DataColumn(label: Text('Tokens')),
                          DataColumn(label: Text('Requests')),
                          DataColumn(label: Text('Cap')),
                          DataColumn(label: Text('Remaining')),
                        ],
                        rows: info.aiByModel.entries.map((e) {
                          final m = e.key;
                          final v = e.value;
                          final used = v['usedTokens'] ?? 0;
                          final req = v['requests'] ?? 0;
                          final cap = v['limitTokens'];
                          final rem = v['remainingTokens'];
                          return DataRow(cells: [
                            DataCell(Text(m)),
                            DataCell(Text(_fmtInt(used))),
                            DataCell(Text(_fmtInt(req))),
                            DataCell(Text(cap == null ? '—' : _fmtInt(cap))),
                            DataCell(Text(rem == null ? '—' : _fmtInt(rem))),
                          ]);
                        }).toList(growable: false),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _PlanOffer {
  final String key; // free, pro, pro_plus
  final String name;
  final int price; // Price in USD per month
  final int minutesPerMonth;
  final int aiTokensPerMonth;
  final int aiRequestsPerMonth;
  final bool canUseSummary;
  final List<String> allowedModels;

  const _PlanOffer({
    required this.key,
    required this.name,
    required this.price,
    required this.minutesPerMonth,
    required this.aiTokensPerMonth,
    required this.aiRequestsPerMonth,
    required this.canUseSummary,
    required this.allowedModels,
  });
}
