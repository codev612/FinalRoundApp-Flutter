import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io' show Platform;
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../providers/shortcuts_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../services/shortcuts_service.dart';
import '../services/appearance_service.dart';
import 'email_change_verification_dialog.dart';
import 'manage_mode_page.dart';

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
                icon: Icons.link,
                label: 'Connection',
                isSelected: _selectedIndex == 2,
                onTap: () => setState(() => _selectedIndex = 2),
              ),
              _SidebarItem(
                icon: Icons.mic,
                label: 'Audio',
                isSelected: _selectedIndex == 3,
                onTap: () => setState(() => _selectedIndex = 3),
              ),
              _SidebarItem(
                icon: Icons.tune,
                label: 'Manage Modes',
                isSelected: false,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ManageModePage()),
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
            return _buildConnectionContent();
          case 3:
            return _buildAudioDevicesContent();
          case 4:
            return Platform.isWindows ? _buildAppearanceContent() : _buildProfileContent();
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

  Widget _buildConnectionContent() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Connection',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.link),
          title: const Text('WebSocket URL'),
          subtitle: Text(AppConfig.serverWebSocketUrl),
          trailing: IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            iconSize: 20,
            constraints: const BoxConstraints(),
            padding: EdgeInsets.zero,
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: AppConfig.serverWebSocketUrl),
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Server URL copied')),
              );
            },
          ),
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
                return ExpansionTile(
                  leading: const Icon(Icons.palette),
                  title: const Text('Theme'),
                  subtitle: Text(_getThemeModeLabel(themeProvider.themeMode)),
                  shape: const RoundedRectangleBorder(
                    side: BorderSide.none,
                  ),
                  collapsedShape: const RoundedRectangleBorder(
                    side: BorderSide.none,
                  ),
                  children: [
                    RadioListTile<ThemeMode>(
                      title: const Text('Light'),
                      value: ThemeMode.light,
                      groupValue: themeProvider.themeMode,
                      onChanged: (value) {
                        if (value != null) {
                          themeProvider.setThemeMode(value, context: context);
                        }
                      },
                    ),
                    RadioListTile<ThemeMode>(
                      title: const Text('Dark'),
                      value: ThemeMode.dark,
                      groupValue: themeProvider.themeMode,
                      onChanged: (value) {
                        if (value != null) {
                          themeProvider.setThemeMode(value, context: context);
                        }
                      },
                    ),
                    RadioListTile<ThemeMode>(
                      title: const Text('System'),
                      value: ThemeMode.system,
                      groupValue: themeProvider.themeMode,
                      onChanged: (value) {
                        if (value != null) {
                          themeProvider.setThemeMode(value, context: context);
                        }
                      },
                    ),
                  ],
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
