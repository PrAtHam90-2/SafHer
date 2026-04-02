import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/app_colors.dart';
import '../services/auth_provider.dart';

/// Reusable profile avatar for every screen's AppBar.
/// Shows a generic person icon (no network image).
/// Tapping it opens a profile bottom sheet.
class ProfileAvatar extends ConsumerWidget {
  const ProfileAvatar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(right: 16.0),
      child: GestureDetector(
        onTap: () => _showProfileSheet(context, ref),
        child: const CircleAvatar(
          backgroundColor: AppColors.lightPink,
          child: Icon(
            Icons.person_rounded,
            color: AppColors.primaryPink,
            size: 22,
          ),
        ),
      ),
    );
  }

  // ── Profile bottom sheet ─────────────────────────────────────────────────
  void _showProfileSheet(BuildContext context, WidgetRef ref) {
    final user = ref.read(authStateProvider).value;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ProfileSheet(
        displayName: user?.displayName ?? 'User',
        email:       user?.email       ?? '',
        onLogout: () async {
          Navigator.pop(context); // close sheet first
          await ref.read(authServiceProvider).signOut();
          // authStateProvider emits null → app.dart shows LoginScreen
        },
      ),
    );
  }
}

// ── Bottom sheet widget ──────────────────────────────────────────────────────

class _ProfileSheet extends StatelessWidget {
  final String displayName;
  final String email;
  final VoidCallback onLogout;

  const _ProfileSheet({
    required this.displayName,
    required this.email,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // Avatar + name + email
          const CircleAvatar(
            radius: 36,
            backgroundColor: AppColors.lightPink,
            child: Icon(Icons.person_rounded,
                color: AppColors.primaryPink, size: 40),
          ),
          const SizedBox(height: 12),
          Text(
            displayName,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (email.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              email,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ],
          const SizedBox(height: 28),
          const Divider(height: 1),
          const SizedBox(height: 8),

          // Menu items
          _SheetTile(
            icon: Icons.person_outline_rounded,
            label: 'View Profile',
            onTap: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Profile page coming soon'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          _SheetTile(
            icon: Icons.route_rounded,
            label: 'Previous Trips',
            onTap: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Trip history coming soon'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          _SheetTile(
            icon: Icons.settings_outlined,
            label: 'Settings',
            onTap: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Settings coming soon'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          const Divider(height: 1),
          const SizedBox(height: 4),
          _SheetTile(
            icon: Icons.logout_rounded,
            label: 'Logout',
            color: AppColors.primaryPink,
            onTap: onLogout,
          ),
        ],
      ),
    );
  }
}

class _SheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _SheetTile({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textDark;
    return ListTile(
      leading: Icon(icon, color: c, size: 22),
      title: Text(label,
          style: TextStyle(
              color: c, fontWeight: FontWeight.w500, fontSize: 15)),
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
    );
  }
}
