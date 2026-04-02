import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../core/theme/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../services/auth_provider.dart';
import '../../services/trip_provider.dart';
import '../../services/trip_history_service.dart'; // ← NEW
import '../../widgets/profile_avatar.dart';

// ============================================================================
//  HomeScreen
// ============================================================================

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning 👋';
    if (hour < 17) return 'Good afternoon 👋';
    if (hour < 21) return 'Good evening 👋';
    return 'Good night 👋';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user       = ref.watch(authStateProvider).value;
    final firstName  = _extractFirstName(user?.displayName);
    final trip       = ref.watch(tripProvider);
    final historyAsync = ref.watch(tripHistoryProvider); // ← NEW

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(LucideIcons.shield, color: AppColors.primaryPink),
            const SizedBox(width: 8),
            Text(
              'SafHer',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppColors.primaryPink,
                    fontWeight: FontWeight.w800,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ],
        ),
        actions: const [ProfileAvatar()],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppConstants.padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _greeting(),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppColors.textGrey,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              firstName,
              style: Theme.of(context).textTheme.displayMedium,
            ),
            const SizedBox(height: 24),
            _buildStatusCard(context, trip),
            const SizedBox(height: 32),
            Text('Quick Actions', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            _buildQuickActions(context),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Recent Trips', style: Theme.of(context).textTheme.titleLarge),
                // Refresh button — useful after a trip completes
                TextButton(
                  onPressed: () => ref.invalidate(tripHistoryProvider),
                  child: const Text(
                    'Refresh',
                    style: TextStyle(
                        color: AppColors.primaryPink, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // ← CHANGED: now driven by Firestore data
            _buildRecentTrips(context, historyAsync),
          ],
        ),
      ),
    );
  }

  static String _extractFirstName(String? displayName) {
    if (displayName == null || displayName.trim().isEmpty) return 'there';
    return displayName.trim().split(' ').first;
  }

  // ── Status card — unchanged logic ─────────────────────────────────────────
  Widget _buildStatusCard(BuildContext context, TripState trip) {
    final bool isActive = trip.isTripActive;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CURRENT STATUS',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.textLight,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  isActive ? 'Trip in progress' : 'No active trip',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your location is being monitored.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isActive ? AppColors.lightPink : AppColors.safeGreen,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isActive ? Icons.location_on_rounded : Icons.check_circle,
                  size: 16,
                  color: isActive ? AppColors.primaryPink : AppColors.safeGreenDark,
                ),
                const SizedBox(width: 4),
                Text(
                  isActive ? 'Tracking' : 'Safe',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: isActive
                            ? AppColors.primaryPink
                            : AppColors.safeGreenDark,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Quick actions — unchanged ──────────────────────────────────────────────
  Widget _buildQuickActions(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 1.4,
      children: [
        _ActionCard(
          title: 'Start Trip',
          subtitle: 'Real-time tracking',
          icon: LucideIcons.map,
          color: AppColors.lightPurple,
          iconColor: AppColors.primaryPink,
          onTap: () => context.go('/trip'),
        ),
        _ActionCard(
          title: 'Verify Driver',
          subtitle: 'Check credentials',
          icon: LucideIcons.shieldCheck,
          color: AppColors.lightPink,
          iconColor: AppColors.primaryPink,
          onTap: () => context.go('/verify'),
        ),
        _ActionCard(
          title: 'SOS Panic',
          subtitle: 'Instant emergency',
          icon: LucideIcons.alertCircle,
          color: AppColors.lightRed,
          iconColor: AppColors.primaryPink,
          titleColor: AppColors.primaryPink,
          onTap: () => context.go('/sos'),
        ),
        _ActionCard(
          title: 'Contacts',
          subtitle: 'Emergency circle',
          icon: LucideIcons.users,
          color: AppColors.lightPurple,
          iconColor: AppColors.primaryPink,
          onTap: () => context.go('/contacts'),
        ),
      ],
    );
  }

  // ── Recent trips — NEW: driven by tripHistoryProvider ─────────────────────
  Widget _buildRecentTrips(
    BuildContext context,
    AsyncValue<List<TripRecord>> historyAsync,
  ) {
    return historyAsync.when(
      loading: () => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.cardWhite,
          borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        ),
        child: const Center(
          child: CircularProgressIndicator(
            color: AppColors.primaryPink,
            strokeWidth: 2,
          ),
        ),
      ),
      error: (_, _) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.cardWhite,
          borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        ),
        child: Center(
          child: Text(
            'Could not load trips.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textGrey,
                ),
          ),
        ),
      ),
      data: (trips) {
        if (trips.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.cardWhite,
              borderRadius: BorderRadius.circular(AppConstants.borderRadius),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.mapPin, color: AppColors.textLight, size: 32),
                  const SizedBox(height: 12),
                  Text(
                    'No trips yet',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppColors.textGrey,
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Your completed trips will appear here.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.textLight,
                        ),
                  ),
                ],
              ),
            ),
          );
        }

        // Show up to 5 most recent trips
        final recent = trips.take(5).toList();
        return Column(
          children: recent
              .map((trip) => _TripHistoryTile(trip: trip))
              .toList(),
        );
      },
    );
  }
}

// ============================================================================
//  _TripHistoryTile — one row per completed trip  (NEW)
// ============================================================================

class _TripHistoryTile extends StatelessWidget {
  final TripRecord trip;
  const _TripHistoryTile({required this.trip});

  @override
  Widget build(BuildContext context) {
    // Format date: "31 Mar, 07:19"
    final dt = trip.startedAt;
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final dateLabel =
        '${dt.day} ${months[dt.month - 1]}, ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    // Duration: "12 min" or "1h 5m"
    final mins = trip.duration.inMinutes;
    final durationLabel =
        mins >= 60 ? '${mins ~/ 60}h ${mins % 60}m' : '$mins min';

    // Distance
    final distLabel = '${trip.distanceTravelledKm.toStringAsFixed(1)} km';

    final bool safe = !trip.hadAnomaly;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Icon
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: safe ? AppColors.safeGreen : AppColors.lightPink,
              shape: BoxShape.circle,
            ),
            child: Icon(
              safe ? LucideIcons.checkCircle2 : LucideIcons.alertCircle,
              size: 18,
              color: safe ? AppColors.safeGreenDark : AppColors.primaryPink,
            ),
          ),
          const SizedBox(width: 14),

          // Date + distance
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dateLabel,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$durationLabel · $distLabel',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textGrey,
                      ),
                ),
              ],
            ),
          ),

          // Status badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: safe ? AppColors.safeGreen : AppColors.lightPink,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              safe ? 'Safe' : 'Alert',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: safe ? AppColors.safeGreenDark : AppColors.primaryPink,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  _ActionCard — unchanged
// ============================================================================

class _ActionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Color iconColor;
  final Color? titleColor;
  final VoidCallback onTap;

  const _ActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.iconColor,
    this.titleColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppConstants.borderRadius),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.cardWhite,
          borderRadius: BorderRadius.circular(AppConstants.borderRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const Spacer(),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: titleColor ?? AppColors.textDark,
                  ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: titleColor?.withOpacity(0.7) ?? AppColors.textGrey,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
