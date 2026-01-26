import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/meeting_mode.dart';
import '../models/custom_meeting_mode.dart';
import '../services/meeting_mode_service.dart';
import '../providers/auth_provider.dart';

String _nextId() => '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(0x7fffffff)}';

class _TemplateSection {
  final String id;
  String title;
  String description;

  _TemplateSection({required this.id, required this.title, required this.description});
}

List<_TemplateSection> _parseNotesTemplate(String s) {
  if (s.trim().isEmpty) {
    return [_TemplateSection(id: _nextId(), title: 'Notes', description: '')];
  }
  final list = <_TemplateSection>[];
  final lines = s.split('\n');
  String? currentTitle;
  final descLines = <String>[];

  void flush() {
    if (currentTitle != null) {
      list.add(_TemplateSection(
        id: _nextId(),
        title: currentTitle!,
        description: descLines.join('\n').trim(),
      ));
      descLines.clear();
    }
    currentTitle = null;
  }

  for (final line in lines) {
    if (line.startsWith('## ')) {
      flush();
      currentTitle = line.substring(3).trim();
    } else if (line.startsWith('### ') || line.startsWith('#### ')) {
      flush();
      currentTitle = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    } else {
      descLines.add(line);
    }
  }
  flush();
  return list.isEmpty ? [_TemplateSection(id: _nextId(), title: 'Notes', description: '')] : list;
}

String _serializeNotesTemplate(List<_TemplateSection> items) {
  final buf = StringBuffer();
  for (final it in items) {
    buf.writeln('## ${it.title}');
    if (it.description.isNotEmpty) buf.writeln(it.description);
    buf.writeln();
  }
  return buf.toString().trim();
}

class ManageModePage extends StatefulWidget {
  const ManageModePage({super.key});

  @override
  State<ManageModePage> createState() => _ManageModePageState();
}

class _ManageModePageState extends State<ManageModePage> {
  final MeetingModeService _modeService = MeetingModeService();
  List<CustomMeetingMode> _customModes = [];
  bool _isLoading = true;
  bool _showingTemplates = false;
  CustomMeetingMode? _selected;
  /// Set while a delete is in progress so we never save that mode (e.g. from dispose flush).
  String? _deletingModeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _modeService.setAuthToken(context.read<AuthProvider>().token);
      _loadAll();
    });
  }

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);
    try {
      final custom = await _modeService.getCustomModes();
      if (mounted) {
        setState(() {
          _customModes = custom;
          _selected ??= custom.isNotEmpty ? custom.first : null;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load: $e')),
        );
      }
    }
  }

  Future<void> _saveCustomMode(CustomMeetingMode custom, {bool silent = false}) async {
    try {
      await _modeService.updateCustomMode(custom);
      if (mounted) {
        setState(() {
          final i = _customModes.indexWhere((c) => c.id == custom.id);
          if (i >= 0) {
            _customModes[i] = custom;
          } else {
            _customModes.add(custom);
          }
          // Only update selection for Save prompt, or when auto-save is for the currently selected mode
          if (!silent || _selected?.id == custom.id) {
            _selected = custom;
          }
        });
        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Custom mode saved')),
          );
        }
      }
    } catch (e) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  /// Called after user confirms in the editor. [authToken] is from the editor's context at tap time.
  Future<void> _performDeleteCustomMode(CustomMeetingMode custom, {String? authToken}) async {
    debugPrint('[RemoveMode] _performDeleteCustomMode id=${custom.id} label="${custom.label}" hasToken=${authToken != null && authToken.isNotEmpty}');
    final previousModes = List<CustomMeetingMode>.from(_customModes);
    final previousSelected = _selected;
    _deletingModeId = custom.id;
    try {
      if (mounted) {
        setState(() {
          _customModes.removeWhere((m) => m.id == custom.id);
          if (_selected?.id == custom.id) {
            _selected = _customModes.isNotEmpty ? _customModes.first : null;
          }
        });
        debugPrint('[RemoveMode] Optimistic update done, _customModes.length=${_customModes.length}');
      }
      await _modeService.deleteCustomMode(custom.id, authToken: authToken);
      debugPrint('[RemoveMode] deleteCustomMode succeeded');
      if (mounted) {
        await _loadAll();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Custom mode removed')),
          );
        }
      }
    } catch (e, st) {
      debugPrint('[RemoveMode] deleteCustomMode threw: $e');
      debugPrint('[RemoveMode] stack: $st');
      if (mounted) {
        setState(() {
          _customModes = previousModes;
          _selected = previousSelected;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    } finally {
      _deletingModeId = null;
    }
  }

  Future<void> _showAddCustomModeDialog() async {
    final result = await showDialog<CustomMeetingMode>(
      context: context,
      builder: (ctx) => _AddCustomModeDialog(),
    );
    if (result == null || !mounted) return;
    final previous = List<CustomMeetingMode>.from(_customModes);
    final previousSelected = _selected;
    setState(() {
      _customModes = [..._customModes, result];
      _selected = result;
      _showingTemplates = false;
    });
    try {
      await _modeService.addCustomMode(result);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Custom mode added')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _customModes = previous;
          _selected = previousSelected;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add: $e')),
        );
      }
    }
  }

  Future<void> _addFromTemplate(MeetingMode template) async {
    final config = MeetingModeService.getDefaultConfig(template);
    final custom = CustomMeetingMode(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      label: template.label,
      iconCodePoint: template.icon.codePoint,
      realTimePrompt: config.realTimePrompt,
      notesTemplate: config.notesTemplate,
    );
    final previous = List<CustomMeetingMode>.from(_customModes);
    final previousSelected = _selected;
    setState(() {
      _customModes = [..._customModes, custom];
      _selected = custom;
      _showingTemplates = false;
    });
    try {
      await _modeService.addCustomMode(custom);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "${template.label}" as custom mode')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _customModes = previous;
          _selected = previousSelected;
          _showingTemplates = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add: $e')),
        );
      }
    }
  }

  static const Map<MeetingMode, String> _templateSummaries = {
    MeetingMode.general: 'Casual conversation, quick Q&A, and general follow-ups.',
    MeetingMode.interview: 'Structured Q&A, candidate answers, and evaluation notes.',
    MeetingMode.presentation: 'Slide flow, key points, and audience questions.',
    MeetingMode.discussion: 'Multiple viewpoints, decisions, and action items.',
    MeetingMode.lecture: 'Main topics, definitions, and takeaways.',
    MeetingMode.meeting: 'Agenda, decisions, and next steps.',
    MeetingMode.call: 'Call summary, outcomes, and follow-up tasks.',
    MeetingMode.brainstorm: 'Ideas, themes, and prioritized next steps.',
    MeetingMode.other: 'Free-form notes for any other meeting type.',
  };

  Widget _buildTemplatesView() {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.layers, size: 32, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  'Templates',
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Choose a template to add as your own custom mode. You can edit it after adding.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: ListView.separated(
                itemCount: MeetingMode.values.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final mode = MeetingMode.values[index];
                  final summary = _templateSummaries[mode] ?? '';
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
                    leading: CircleAvatar(
                      child: Icon(mode.icon, color: theme.colorScheme.onPrimary),
                    ),
                    title: Text(mode.label),
                    subtitle: Text(summary, style: theme.textTheme.bodySmall),
                    trailing: FilledButton(
                      onPressed: () => _addFromTemplate(mode),
                      child: const Text('Add'),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage modes'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 260,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _showAddCustomModeDialog,
                            icon: const Icon(Icons.add, size: 20),
                            label: const Text('Add mode'),
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: _customModes.isEmpty
                            ? const Center(
                                child: Text(
                                  'No custom modes\n\nUse "Add mode" or add from Templates.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 13),
                                ),
                              )
                            : ListView(
                                padding: const EdgeInsets.only(bottom: 8),
                                children: _customModes.map((c) {
                                  final isSelected = !_showingTemplates && _selected?.id == c.id;
                                  return ListTile(
                                    selected: isSelected,
                                    leading: Icon(c.icon),
                                    title: Text(c.label),
                                    onTap: () => setState(() {
                                      _showingTemplates = false;
                                      _selected = c;
                                    }),
                                  );
                                }).toList(),
                              ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        child: SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => setState(() => _showingTemplates = !_showingTemplates),
                            icon: const Icon(Icons.layers, size: 18),
                            label: const Text('Templates'),
                            style: _showingTemplates
                                ? OutlinedButton.styleFrom(
                                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                                    foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surface,
                    child: _showingTemplates
                        ? _buildTemplatesView()
                        : _selected == null
                            ? const Center(child: Text('Select a mode to configure'))
                            : _CustomModeEditor(
                                key: ValueKey(_selected!.id),
                                custom: _selected!,
                                onSavePrompt: (updated) async {
                                  if (!mounted) return;
                                  if (updated.id == _deletingModeId) return;
                                  if (!_customModes.any((m) => m.id == updated.id)) return;
                                  _modeService.setAuthToken(context.read<AuthProvider>().token);
                                  await _saveCustomMode(updated, silent: false);
                                },
                                onNotesSaved: (updated) async {
                                  if (!mounted) return;
                                  if (updated.id == _deletingModeId) return;
                                  if (!_customModes.any((m) => m.id == updated.id)) return;
                                  _modeService.setAuthToken(context.read<AuthProvider>().token);
                                  await _saveCustomMode(updated, silent: true);
                                },
                                onDelete: (c, token) => _performDeleteCustomMode(c, authToken: token),
                              ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Custom mode editor: notes template auto-saves; Save button applies only to real-time prompt.
class _CustomModeEditor extends StatefulWidget {
  final CustomMeetingMode custom;
  final Future<void> Function(CustomMeetingMode updated) onSavePrompt;
  final Future<void> Function(CustomMeetingMode updated) onNotesSaved;
  final Future<void> Function(CustomMeetingMode mode, String? authToken)? onDelete;

  const _CustomModeEditor({
    super.key,
    required this.custom,
    required this.onSavePrompt,
    required this.onNotesSaved,
    this.onDelete,
  });

  @override
  State<_CustomModeEditor> createState() => _CustomModeEditorState();
}

class _CustomModeEditorState extends State<_CustomModeEditor> {
  late final TextEditingController _promptController;
  late final TextEditingController _notesController;
  Timer? _notesSaveTimer;
  static const Duration _debounce = Duration(milliseconds: 800);

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController(text: widget.custom.realTimePrompt);
    _notesController = TextEditingController(text: widget.custom.notesTemplate);
    _notesController.addListener(_scheduleNotesSave);
  }

  @override
  void dispose() {
    _notesSaveTimer?.cancel();
    _flushNotesSave();
    _notesController.removeListener(_scheduleNotesSave);
    _promptController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _scheduleNotesSave() {
    _notesSaveTimer?.cancel();
    _notesSaveTimer = Timer(_debounce, () {
      _notesSaveTimer = null;
      _flushNotesSave();
    });
  }

  void _flushNotesSave() {
    final updated = widget.custom.copyWith(notesTemplate: _notesController.text);
    widget.onNotesSaved(updated);
  }

  Future<void> _savePrompt() async {
    final updated = widget.custom.copyWith(
      realTimePrompt: _promptController.text,
      notesTemplate: _notesController.text,
    );
    await widget.onSavePrompt(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(widget.custom.icon, size: 32),
              const SizedBox(width: 12),
              Text(widget.custom.label, style: Theme.of(context).textTheme.headlineSmall),
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Text('(Custom)', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final available = constraints.maxHeight;
                final promptHeight = (available * 0.36).clamp(120.0, 320.0);
                final templateHeight = (available * 0.54).clamp(180.0, 520.0);
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.auto_awesome, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Real-time Prompt',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Used when asking AI questions during the meeting. Save with the button below.',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                    ),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                height: promptHeight,
                                child: TextField(
                                  controller: _promptController,
                                  maxLines: null,
                                  expands: true,
                                  decoration: const InputDecoration(
                                    hintText: 'Enter the real-time prompt...',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.note, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Notes Template',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '• auto-saved',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: Theme.of(context).colorScheme.primary,
                                          fontStyle: FontStyle.italic,
                                        ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Template for notes. Changes are saved automatically.',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                    ),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                height: templateHeight,
                                child: _NotesTemplateEditor(controller: _notesController),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              widget.onDelete != null
                  ? TextButton.icon(
                      onPressed: () async {
                        debugPrint('[RemoveMode] Remove mode button pressed, custom.id=${widget.custom.id} label="${widget.custom.label}"');
                        final confirm = await showDialog<bool>(
                          context: context,
                          useRootNavigator: true,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Remove custom mode?'),
                            content: Text(
                                'Delete "${widget.custom.label}"? This cannot be undone.'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Delete')),
                            ],
                          ),
                        );
                        debugPrint('[RemoveMode] Dialog result: confirm=$confirm mounted=$mounted onDelete=${widget.onDelete != null ? "set" : "null"}');
                        if (confirm == true && mounted && widget.onDelete != null) {
                          final token = context.read<AuthProvider>().token;
                          debugPrint('[RemoveMode] Calling onDelete id=${widget.custom.id} hasToken=${token != null && token.isNotEmpty} tokenLength=${token?.length ?? 0}');
                          await widget.onDelete!(widget.custom, token);
                          debugPrint('[RemoveMode] onDelete returned');
                        }
                      },
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Remove mode'),
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                    )
                  : const SizedBox.shrink(),
              FilledButton(
                onPressed: _savePrompt,
                child: const Text('Save prompt'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NotesTemplateEditor extends StatefulWidget {
  final TextEditingController controller;

  const _NotesTemplateEditor({required this.controller});

  @override
  State<_NotesTemplateEditor> createState() => _NotesTemplateEditorState();
}

class _NotesTemplateEditorState extends State<_NotesTemplateEditor> {
  late List<_TemplateSection> _items;

  @override
  void initState() {
    super.initState();
    _items = _parseNotesTemplate(widget.controller.text);
  }

  @override
  void didUpdateWidget(covariant _NotesTemplateEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _items = _parseNotesTemplate(widget.controller.text);
    }
  }

  void _syncToController() {
    widget.controller.text = _serializeNotesTemplate(_items);
  }

  void _addSection() {
    setState(() {
      _items.add(_TemplateSection(id: _nextId(), title: '', description: ''));
      _syncToController();
    });
  }

  void _addDefaultTemplate() {
    setState(() {
      _items = _parseNotesTemplate(MeetingModeService.defaultNotesTemplate);
      _syncToController();
    });
  }

  Future<void> _editSection(int index) async {
    final section = _items[index];
    final titleCtrl = TextEditingController(text: section.title);
    final descCtrl = TextEditingController(text: section.description);
    const double dialogWidth = 440;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit section'),
        content: SizedBox(
          width: dialogWidth,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: titleCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    hintText: 'Section title',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descCtrl,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'Description or placeholder',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Done')),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _items[index].title = titleCtrl.text.trim();
        _items[index].description = descCtrl.text.trim();
        _syncToController();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.max,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Drag to reorder. Tap to edit. Changes auto-save.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: _addDefaultTemplate,
                  icon: const Icon(Icons.library_add, size: 18),
                  label: const Text('Add template'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _addSection,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add section'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: _items.length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                final item = _items.removeAt(oldIndex);
                _items.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, item);
                _syncToController();
              });
            },
            itemBuilder: (context, index) {
              final section = _items[index];
              final titleDisplay = section.title.isEmpty ? 'Untitled' : section.title;
              final descPreview = section.description.isEmpty
                  ? 'No description'
                  : (section.description.length > 60
                      ? '${section.description.substring(0, 60)}…'
                      : section.description);
              return Card(
                key: ValueKey(section.id),
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_handle, color: Colors.grey),
                  ),
                  title: Text(titleDisplay, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    descPreview,
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline, size: 20, color: Theme.of(context).colorScheme.error),
                    onPressed: () {
                      setState(() {
                        _items.removeAt(index);
                        _syncToController();
                      });
                    },
                  ),
                  onTap: () => _editSection(index),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AddCustomModeDialog extends StatefulWidget {
  @override
  State<_AddCustomModeDialog> createState() => _AddCustomModeDialogState();
}

class _AddCustomModeDialogState extends State<_AddCustomModeDialog> {
  final _labelController = TextEditingController();
  final _promptController = TextEditingController();
  final _templateController = TextEditingController();
  int _iconCodePoint = Icons.star.codePoint;

  static final List<IconData> _iconChoices = [
    Icons.star,
    Icons.work,
    Icons.lightbulb_outline,
    Icons.favorite,
    Icons.flag,
    Icons.bookmark,
    Icons.business_center,
    Icons.psychology,
  ];

  @override
  void dispose() {
    _labelController.dispose();
    _promptController.dispose();
    _templateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add custom mode'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Label', style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              TextField(
                controller: _labelController,
                decoration: const InputDecoration(hintText: 'Mode name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: _iconChoices.map((icon) {
                  final codePoint = icon.codePoint;
                  return IconButton(
                    onPressed: () => setState(() => _iconCodePoint = codePoint),
                    icon: Icon(icon, color: _iconCodePoint == codePoint ? Theme.of(context).colorScheme.primary : null),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              const Text('Real-time prompt', style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              TextField(
                controller: _promptController,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'Optional', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              const Text('Notes template (optional)', style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              TextField(
                controller: _templateController,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Leave empty to add later, or use "Add template" in the editor',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final custom = CustomMeetingMode(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              label: _labelController.text.trim().isEmpty ? 'Custom' : _labelController.text.trim(),
              iconCodePoint: _iconCodePoint,
              realTimePrompt: _promptController.text,
              notesTemplate: _templateController.text,
            );
            Navigator.pop(context, custom);
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
