import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/dashboard_provider.dart';

class DashboardWidgets extends StatelessWidget {
  const DashboardWidgets({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<DashboardProvider>(
      builder: (context, dashboardProvider, child) {
        final stats = dashboardProvider.stats;

        if (dashboardProvider.isLoading && stats == null) {
          return const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (stats == null) {
          return const SizedBox.shrink();
        }

        return Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.access_time,
                title: 'Total Meeting Time',
                value: stats.formattedTotalMeetingTime,
                color: Colors.blue,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.api,
                title: 'API Usage',
                value: '${stats.apiUsagePercentage.toStringAsFixed(1)}%',
                subtitle: '${_formatTokens(stats.apiUsedTokens)} / ${_formatTokens(stats.apiLimitTokens)}',
                color: Colors.orange,
                progress: stats.apiUsagePercentage / 100,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.workspace_premium,
                title: 'Subscription',
                value: stats.planDisplayName,
                color: Colors.purple,
              ),
            ),
          ],
        );
      },
    );
  }

  static String _formatTokens(int tokens) {
    if (tokens < 1000) return '$tokens';
    if (tokens < 1000000) return '${(tokens / 1000).toStringAsFixed(1)}K';
    return '${(tokens / 1000000).toStringAsFixed(1)}M';
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;
  final Color color;
  final double? progress;

  const _StatCard({
    required this.icon,
    required this.title,
    required this.value,
    this.subtitle,
    required this.color,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withValues(alpha: 0.1),
              color.withValues(alpha: 0.05),
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    icon,
                    color: color,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w500,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
              ),
            ],
            if (progress != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  backgroundColor: color.withValues(alpha: 0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
