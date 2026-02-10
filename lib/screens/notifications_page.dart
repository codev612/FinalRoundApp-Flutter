import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../providers/auth_provider.dart';
import '../services/http_client_service.dart';
import '../providers/notification_provider.dart';

class NotificationsPage extends StatefulWidget {
  final bool isActive;

  const NotificationsPage({super.key, required this.isActive});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool _isLoading = false;
  String _error = '';
  List<_NotificationItem> _items = const [];
  bool _hasLoadedOnce = false;

  @override
  void initState() {
    super.initState();
    // Don't load here; wait until the tab becomes active.
  }

  @override
  void didUpdateWidget(covariant NotificationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && !_hasLoadedOnce) {
      // First time the notifications tab becomes visible: load + mark read.
      _loadNotifications();
      _hasLoadedOnce = true;
    }
  }

  Future<void> _loadNotifications() async {
    setState(() {
      _isLoading = true;
      _error = '';
    });

    try {
      final auth = context.read<AuthProvider>();
      final token = auth.token;
      if (token == null || token.isEmpty) {
        setState(() {
          _isLoading = false;
          _error = 'You must be signed in to view notifications.';
        });
        return;
      }

      final uri = Uri.parse(AppConfig.serverHttpBaseUrl)
          .resolve('/api/notifications?limit=100');
      final res = await HttpClientService.client.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        final msg = (data is Map && data['error'] is String)
            ? data['error'] as String
            : 'Failed to load notifications.';
        setState(() {
          _isLoading = false;
          _error = msg;
        });
        return;
      }

      final list = (data['notifications'] as List<dynamic>? ?? [])
          .map((raw) => _NotificationItem.fromJson(raw))
          .toList();

      setState(() {
        _isLoading = false;
        _items = list;
      });

      // When user opens the notifications page, treat loaded items as "read".
      final unreadIds =
          list.where((n) => !n.isRead && n.id != null).map((n) => n.id!).toList();
      if (unreadIds.isNotEmpty) {
        await Future.wait(unreadIds.map((id) async {
          final uri = Uri.parse(AppConfig.serverHttpBaseUrl)
              .resolve('/api/notification/read');
          try {
            await HttpClientService.client.post(
              uri,
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'notificationId': id}),
            );
          } catch (_) {
            // Ignore errors for marking as read
          }
        }));
        if (mounted) {
          // Refresh unread badge state so the red dot disappears.
          await context.read<NotificationProvider>().checkForUnread();
        }
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Failed to load notifications.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Notifications',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: _isLoading ? null : _loadNotifications,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_isLoading)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(),
              ),
            )
          else if (_error.isNotEmpty)
            Expanded(
              child: Center(
                child: Text(
                  _error,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .error,
                      ),
                ),
              ),
            )
          else if (_items.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  'No notifications yet.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                      ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final n = _items[index];
                  final createdAt = n.createdAt;
                  final timeText = createdAt != null
                      ? '${createdAt.toLocal()}'
                      : '';
                  final isRead = n.isRead;
                  final bgColor = isRead
                      ? Theme.of(context)
                          .colorScheme
                          .surfaceVariant
                          .withValues(alpha: 0.3)
                      : Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.06);
                  final borderColor = isRead
                      ? Theme.of(context)
                          .colorScheme
                          .outline
                          .withValues(alpha: 0.2)
                      : Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.4);

                  return Card(
                    elevation: 0,
                    color: bgColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: borderColor),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (timeText.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                timeText,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.6),
                                    ),
                              ),
                            ),
                          Text(
                            n.message,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          if (n.buttonUrl != null &&
                              n.buttonUrl!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: TextButton(
                                onPressed: () async {
                                  final rawUrl = n.buttonUrl!.trim();
                                  if (rawUrl.isEmpty) return;

                                  // Ensure URL has a scheme; default to https like web version.
                                  final normalized = rawUrl.startsWith('http://') || rawUrl.startsWith('https://')
                                      ? rawUrl
                                      : 'https://$rawUrl';

                                  final uri = Uri.tryParse(normalized);
                                  if (uri == null) return;

                                  try {
                                    final canOpen = await canLaunchUrl(uri);
                                    if (canOpen) {
                                      await launchUrl(
                                        uri,
                                        mode: LaunchMode.externalApplication,
                                      );
                                    } else {
                                      // Optionally show a small error in UI; for now just ignore.
                                      debugPrint('Cannot launch notification URL: $normalized');
                                    }
                                  } catch (e) {
                                    debugPrint('Error launching notification URL: $e');
                                  }
                                },
                                child: Text(n.buttonLabel ?? 'Open'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _NotificationItem {
  final String? id;
  final String message;
  final DateTime? createdAt;
  final String? buttonLabel;
  final String? buttonUrl;
  final bool isRead;

  _NotificationItem({
    required this.id,
    required this.message,
    required this.createdAt,
    required this.buttonLabel,
    required this.buttonUrl,
    required this.isRead,
  });

  factory _NotificationItem.fromJson(dynamic raw) {
    if (raw is! Map) {
      return _NotificationItem(
        id: null,
        message: '',
        createdAt: null,
        buttonLabel: null,
        buttonUrl: null,
        isRead: true,
      );
    }
    final created = raw['createdAt'];
    DateTime? ts;
    if (created is String) {
      ts = DateTime.tryParse(created);
    }
    return _NotificationItem(
      id: raw['id'] as String?,
      message: (raw['message'] as String?) ?? '',
      createdAt: ts,
      buttonLabel: raw['buttonLabel'] as String?,
      buttonUrl: raw['buttonUrl'] as String?,
      isRead: raw['isRead'] == true,
    );
  }
}

