import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../models/contact.dart';
import '../../services/contacts_service.dart';
import '../../services/location_service.dart';
import '../../services/trip_provider.dart';
import '../../services/verification_service.dart';
import '../../widgets/profile_avatar.dart';
import 'destination_picker.dart';

// ============================================================================
//  TripScreen
// ============================================================================

class TripScreen extends ConsumerStatefulWidget {
  const TripScreen({super.key});

  @override
  ConsumerState<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends ConsumerState<TripScreen> {
  final MapController _mapController = MapController();

  LatLng? _userPosition;

  // Destination marker — null until user picks a destination.
  LatLng? _dest;

  final List<LatLng> _tripPath = [];
  bool _isDeviated = false;

  StreamSubscription<Position>? _positionSub;
  StreamSubscription<String>?   _anomalySub;

  // ── Called by DestinationPickerCard when user selects a place ─────────────
  void _onDestinationChanged(LatLng ll, String label) {
    setState(() => _dest = ll);
    ref.read(tripProvider.notifier).setDestination(
      ll.latitude,
      ll.longitude,
      label: label,
    );
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final locationService = ref.read(locationServiceProvider);

      _positionSub = locationService.positionStream.listen(
        (pos) {
          final ll = LatLng(pos.latitude, pos.longitude);
          setState(() {
            _userPosition = ll;
            if (ref.read(tripProvider).isTripActive) {
              _tripPath.add(ll);
            }
          });
          try {
            _mapController.move(ll, _mapController.camera.zoom);
          } catch (_) {}
        },
        onError: (_) {},
        cancelOnError: false,
      );

      _anomalySub = ref.read(tripProvider.notifier).anomalyStream.listen((msg) {
        if (!mounted) return;
        if (msg.contains('Unusual route')) {
          setState(() => _isDeviated = true);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: AppColors.primaryPink,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      });
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _anomalySub?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  void _shareTrip() {
    if (_userPosition != null) {
      final link =
          'https://www.google.com/maps?q=${_userPosition!.latitude},${_userPosition!.longitude}';
      Share.share('🚨 Live Trip Tracking:\n$link', subject: 'SafHer Live Trip');
    } else {
      Clipboard.setData(const ClipboardData(text: 'https://www.google.com/maps'));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location not available yet — link copied'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _startJourney() {
    setState(() {
      _tripPath.clear();
      _isDeviated = false;
      if (_userPosition != null) _tripPath.add(_userPosition!);
    });
    ref.read(tripProvider.notifier).startTripManually();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🚗 Journey started. Monitoring route…'),
        backgroundColor: AppColors.safeGreenDark,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 3),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final tripState = ref.watch(tripProvider);

    // Compute remaining distance from live TripState — respects dynamic destination.
    final double? remainingKm = tripState.hasDestination &&
            tripState.distanceToDestinationMetres != null
        ? tripState.distanceToDestinationMetres! / 1000.0
        : null;

    ref.listen<TripState>(tripProvider, (previous, next) {
      if (previous == null) return;
      if (!previous.isTripActive && next.isTripActive) {
        setState(() {
          _tripPath.clear();
          _isDeviated = false;
          if (_userPosition != null) _tripPath.add(_userPosition!);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🚗 Trip started automatically'),
            backgroundColor: AppColors.safeGreenDark,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
      } else if (previous.isTripActive && !next.isTripActive) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🏁 Trip ended safely'),
            backgroundColor: AppColors.primaryPink,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
      }
    });

    return Scaffold(
      backgroundColor: AppColors.background,
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
      body: Stack(
        children: [
          // ── Live map (top 40%) ─────────────────────────────────────────────
          Positioned(
            top: 0, left: 0, right: 0,
            height: MediaQuery.of(context).size.height * 0.4,
            child: _buildLiveMap(),
          ),

          // ── Destination picker overlay card ───────────────────────────────
          Positioned(
            top: 16, left: 16, right: 16,
            child: DestinationPickerCard(
              onDestinationChanged: _onDestinationChanged,
            ),
          ),

          // ── Scrollable content panel ──────────────────────────────────────
          Positioned.fill(
            top: MediaQuery.of(context).size.height * 0.35,
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(32),
                  topRight: Radius.circular(32),
                ),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(
                    top: 24, left: 16, right: 16, bottom: 100),
                child: Column(
                  children: [
                    _buildTripProgressCard(context, remainingKm, tripState),
                    const SizedBox(height: 16),
                    _buildDriverInfoCard(context),
                    const SizedBox(height: 16),
                    _buildSharedContactsCard(context),
                  ],
                ),
              ),
            ),
          ),

          // ── SOS button ────────────────────────────────────────────────────
          Positioned(
            bottom: 32, left: 16, right: 16,
            child: Container(
              decoration: BoxDecoration(boxShadow: [
                BoxShadow(
                  color: AppColors.primaryPink.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                )
              ]),
              child: ElevatedButton(
                onPressed: () => context.go('/sos'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryPink,
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('SOS',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                            )),
                    const SizedBox(width: 8),
                    Text('EMERGENCY',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            )),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Live map ——————————————————————————————————————————————————————————————
  // Falls back to a central Pune location if neither user nor destination known.
  Widget _buildLiveMap() {
    const fallback = LatLng(18.5167, 73.8450);
    final center = _userPosition ?? _dest ?? fallback;
    final polylineColor = _isDeviated ? Colors.red : AppColors.primaryPink;

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: 15,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate:
              'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
          subdomains: const ['a', 'b', 'c', 'd'],
          userAgentPackageName: 'com.example.safher',
          maxZoom: 19,
        ),
        if (_tripPath.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: List.unmodifiable(_tripPath),
                color: polylineColor,
                strokeWidth: 4,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            // Destination pin — only when user has picked one
            if (_dest != null)
              Marker(
                point: _dest!,
                width: 40,
                height: 40,
                child: const Icon(Icons.location_pin, color: Colors.red, size: 40),
              ),
            // User position dot
            if (_userPosition != null)
              Marker(
                point: _userPosition!,
                width: 28,
                height: 28,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.primaryPink,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryPink.withOpacity(0.4),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // ── Trip progress card ——————————————————————————————————————————————————
  // Uses dynamic remainingKm derived from TripState (not hardcoded stream).
  Widget _buildTripProgressCard(
    BuildContext context,
    double? remainingKm,
    TripState tripState,
  ) {
    final bool hasDestination = tripState.hasDestination;
    final double distance = remainingKm ?? 0.0;

    // Progress bar capped at 10 km for visual clarity
    const double maxDist = 10.0;
    final double progress = hasDestination && distance <= maxDist
        ? ((maxDist - distance) / maxDist).clamp(0.0, 1.0)
        : 0.0;

    final bool isActive = tripState.isTripActive;
    final Color pillBg = isActive ? AppColors.safeGreen : Colors.grey.shade200;
    final Color pillFg = isActive ? AppColors.safeGreenDark : AppColors.textGrey;
    final String pillLabel =
        isActive ? '● Trip Active: TRUE' : '○ Trip Active: FALSE';

    return Container(
      padding: const EdgeInsets.all(20),
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
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Trip in Progress',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            )),
                    const SizedBox(height: 4),
                    Text(
                      hasDestination
                          ? '${distance.toStringAsFixed(1)} km remaining to safety'
                          : 'Set a destination above to track progress',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(LucideIcons.checkCircle2,
                  color: AppColors.safeGreenDark, size: 28),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              pillLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: pillFg,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.4,
                  ),
            ),
          ),
          const SizedBox(height: 16),
          Stack(
            children: [
              Container(
                height: 8,
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              FractionallySizedBox(
                widthFactor: progress,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: AppColors.primaryPink,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('START',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.primaryPink, fontWeight: FontWeight.bold)),
              Text('PROGRESS',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.primaryPink, fontWeight: FontWeight.bold)),
              Text('DESTINATION',
                  style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _shareTrip,
                  icon: const Icon(LucideIcons.share2, size: 16),
                  label: const Text('Share Trip'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primaryPink,
                    side: const BorderSide(color: AppColors.primaryPink),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isActive ? null : _startJourney,
                  icon: const Icon(LucideIcons.play, size: 16),
                  label: Text(isActive ? 'Active' : 'Start Journey'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryPink,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.safeGreenDark,
                    disabledForegroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Driver info card — reads from verifyProvider ──────────────────────────
  Widget _buildDriverInfoCard(BuildContext context) {
    final verifyAsync = ref.watch(verifyProvider);

    final data = verifyAsync.maybeWhen(
      data: (value) => value,
      orElse: () => null,
    );

    final driverName  = data?.driverName  ?? 'No driver verified';
    final vehicleInfo = data?.vehicleInfo ?? 'Verify a driver on the Verify screen';
    final isVerified  = data != null && data.isActive;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
      ),
      child: Row(
        children: [
          // Avatar: initials-based
          Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: AppColors.lightPink,
                child: Text(
                  data != null && data.driverName.isNotEmpty
                      ? data.driverName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    color: AppColors.primaryPink,
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                  ),
                ),
              ),
              if (isVerified)
                Positioned(
                  bottom: -10,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.safeGreen,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.verified, size: 10,
                            color: AppColors.safeGreenDark),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  driverName,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                Text(
                  vehicleInfo,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.textGrey),
                ),
              ],
            ),
          ),
          Column(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                    color: AppColors.background, shape: BoxShape.circle),
                child: const Icon(LucideIcons.phone, size: 20),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.buttonBlue,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(LucideIcons.qrCode,
                    size: 20, color: AppColors.buttonBlueText),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Shared contacts card — reads from contactsProvider ────────────────────
  Widget _buildSharedContactsCard(BuildContext context) {
    final contactsAsync = ref.watch(contactsProvider);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Shared Contacts',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              contactsAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
                data: (contacts) => contacts.isEmpty
                    ? const SizedBox.shrink()
                    : Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.lightPink,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${contacts.length} Active',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: AppColors.primaryPink,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          contactsAsync.when(
            loading: () => const SizedBox(
              height: 70,
              child: Center(
                child: CircularProgressIndicator(
                  color: AppColors.primaryPink,
                  strokeWidth: 2,
                ),
              ),
            ),
            error: (_, _) => Text(
              'Could not load contacts.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textGrey),
            ),
            data: (contacts) {
              if (contacts.isEmpty) {
                return Text(
                  'No emergency contacts added yet.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.textGrey),
                );
              }
              final visible = contacts.take(4).toList();
              return Row(
                children: [
                  ...visible.map(
                    (c) => Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _buildContactAvatar(c),
                    ),
                  ),
                  if (contacts.length < 4)
                    GestureDetector(
                      onTap: () => context.go('/contacts'),
                      child: Column(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.add,
                                color: AppColors.textGrey),
                          ),
                          const SizedBox(height: 4),
                          const Text('', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Contact avatar — initials only ────────────────────────────────────────
  Widget _buildContactAvatar(Contact contact) {
    final initial =
        contact.name.isNotEmpty ? contact.name[0].toUpperCase() : '?';
    final shortName = contact.name.split(' ').first;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.primaryPink, width: 2),
          ),
          child: CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.lightPink,
            child: Text(
              initial,
              style: const TextStyle(
                color: AppColors.primaryPink,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          shortName,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
