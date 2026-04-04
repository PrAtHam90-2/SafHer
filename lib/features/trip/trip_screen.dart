// lib/features/trip/trip_screen.dart

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
import '../../services/risk_engine.dart';            // ← NEW
import '../../services/routing_service.dart';
import '../../services/trip_provider.dart';
import '../../services/verification_service.dart';
import '../../widgets/profile_avatar.dart';
import 'destination_picker.dart';

// ============================================================================
//  Stadia Maps configuration
//  Sign up for a free API key (200k tiles/month) at https://client.stadiamaps.com/
// ============================================================================
const _kStadiaMapsApiKey = '59a00577-d14e-4018-bb73-938d4f6331a8';

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

  // ── Live map state ────────────────────────────────────────────────────────
  LatLng? _userPosition;
  LatLng? _source;          // null = use _userPosition as source
  LatLng? _dest;
  String  _sourceLabel      = 'My Location (GPS)';
  bool    _sourceSetManually = false;
  bool    _hasInitialGpsFix  = false; // prevents multiple auto-fetches

  // ── Route ─────────────────────────────────────────────────────────────────
  List<LatLng> _routePolyline = []; // OSRM decoded geometry
  int?         _etaMinutes;
  bool         _isRouteLoading = false;

  // ── Trip path (tracked during active trip) ────────────────────────────────
  final List<LatLng> _tripPath = [];
  bool _isDeviated = false;

  // ── Stream subscriptions ──────────────────────────────────────────────────
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<String>?   _anomalySub;

  // ── Destination change callback ────────────────────────────────────────────
  void _onDestinationChanged(LatLng ll, String label) {
    setState(() => _dest = ll);
    ref.read(tripProvider.notifier).setDestination(ll.latitude, ll.longitude, label: label);
    _fetchRoute();
  }

  // ── Source change callback ────────────────────────────────────────────────
  void _onSourceChanged(LatLng ll, String label) {
    setState(() {
      _source           = ll;
      _sourceLabel      = label;
      _sourceSetManually = true;
    });
    ref.read(tripProvider.notifier).setSource(ll.latitude, ll.longitude, label: label);
    _fetchRoute();
  }

  // ── Reset source to GPS ───────────────────────────────────────────────────
  void _resetSourceToGps() {
    setState(() {
      _source            = _userPosition;
      _sourceLabel       = 'My Location (GPS)';
      _sourceSetManually = false;
    });
    // Clear source in provider so hasSource returns false
    ref.read(tripProvider.notifier).setSource(0, 0, label: '');
    if (_dest != null) _fetchRoute();
  }

  // ── Clear destination ──────────────────────────────────────────────────────
  void _clearDestination() {
    setState(() {
      _dest          = null;
      _routePolyline = [];
      _etaMinutes    = null;
    });
    ref.read(tripProvider.notifier).setDestination(0, 0, label: '');
  }

  // ── Fetch OSRM route ──────────────────────────────────────────────────────
  Future<void> _fetchRoute() async {
    // Always prefer the explicitly-set source; fall back to live GPS.
    // Both source and destination must be known before calling OSRM.
    final origin = _sourceSetManually ? _source : _userPosition;
    if (origin == null || _dest == null) return;

    setState(() { _isRouteLoading = true; });

    // Determine vehicle profile from verified driver's vehicle model.
    // All current vehicles map to driving; structure is extensible.
    final profile = _resolveVehicleProfile();

    final result = await ref.read(routingServiceProvider).fetchRoute(
      origin:      origin,
      destination: _dest!,
      profile:     profile,
    );

    if (!mounted) return;
    setState(() {
      _routePolyline = result?.points ?? [];
      _etaMinutes    = result?.etaMinutes;
      _isRouteLoading = false;
    });
  }

  VehicleProfile _resolveVehicleProfile() {
    // Currently always driving. When bike/walk modes are added, check
    // the verified driver's vehicleModel here and return the right profile.
    return VehicleProfile.driving;
  }

  // ── Journey controls ──────────────────────────────────────────────────────
  void _startJourney() {
    setState(() {
      _tripPath.clear();
      _isDeviated = false;
      if (_userPosition != null) _tripPath.add(_userPosition!);
    });
    ref.read(tripProvider.notifier).startTripManually();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('🚗 Journey started. Monitoring route…'),
      backgroundColor: AppColors.safeGreenDark,
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 3),
    ));
  }

  void _pauseJourney() {
    ref.read(tripProvider.notifier).pauseTripManually();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('⏸ Trip paused'),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 2),
    ));
  }

  void _resumeJourney() {
    ref.read(tripProvider.notifier).resumeTrip();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('▶ Trip resumed'),
      backgroundColor: AppColors.safeGreenDark,
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 2),
    ));
  }

  void _endJourney() {
    ref.read(tripProvider.notifier).endTripManually();
    setState(() {
      _tripPath.clear();
      _isDeviated = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('🏁 Trip ended safely'),
      backgroundColor: AppColors.primaryPink,
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 3),
    ));
  }

  void _shareTrip() {
    if (_userPosition != null) {
      final link = 'https://www.google.com/maps?q=${_userPosition!.latitude},${_userPosition!.longitude}';
      Share.share('🚨 Live Trip Tracking:\n$link', subject: 'SafHer Live Trip');
    } else {
      Clipboard.setData(const ClipboardData(text: 'https://www.google.com/maps'));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Location not available yet — link copied'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
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
            // Auto-track source from GPS until user sets it manually
            if (!_sourceSetManually) _source = ll;
            if (ref.read(tripProvider).isTripActive) _tripPath.add(ll);
          });

          // On first GPS fix: fetch route if destination is already set.
          // Works for both GPS source (most common) and manual source
          // (user picked source before GPS was ready).
          if (!_hasInitialGpsFix && _dest != null) {
            _hasInitialGpsFix = true;
            _fetchRoute();
          }

          try {
            _mapController.move(ll, _mapController.camera.zoom);
          } catch (_) {}
        },
        onError: (_) {},
        cancelOnError: false,
      );

      _anomalySub = ref.read(tripProvider.notifier).anomalyStream.listen((msg) {
        if (!mounted) return;
        if (msg.contains('Unusual route')) setState(() => _isDeviated = true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor: AppColors.primaryPink,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ));
      });

      // ── NEW: risk alert stream ──────────────────────────────────────────
      // Fires only when risk escalates to High Risk or Critical for the first
      // time — not on every GPS tick. Non-destructive: never auto-triggers SOS.
      ref.read(tripProvider.notifier).riskAlertStream.listen((snapshot) {
        if (!mounted) return;
        final color = snapshot.level == RiskLevel.critical
            ? const Color(0xFFB91C1C)  // deep red
            : const Color(0xFFD97706); // amber
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${snapshot.level.label}: ${snapshot.reason}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          backgroundColor: color,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ));
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

  // ══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final tripState = ref.watch(tripProvider);

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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('🚗 Trip started automatically'),
          backgroundColor: AppColors.safeGreenDark,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ));
      } else if (previous.isTripActive && !next.isTripActive) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('🏁 Trip ended safely'),
          backgroundColor: AppColors.primaryPink,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ));
      }
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(LucideIcons.shield, color: AppColors.primaryPink),
            const SizedBox(width: 8),
            Text('SafHer',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppColors.primaryPink,
                    fontWeight: FontWeight.w800,
                    fontStyle: FontStyle.italic)),
          ],
        ),
        actions: const [ProfileAvatar()],
      ),
      body: Stack(
        children: [
          // ── Map (top 40%) ─────────────────────────────────────────────────
          Positioned(
            top: 0, left: 0, right: 0,
            height: MediaQuery.of(context).size.height * 0.4,
            child: _buildLiveMap(),
          ),

          // ── Route planner overlay — source + destination stacked ──────────
          Positioned(
            top: 16, left: 16, right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Source picker
                SourcePickerCard(
                  label:         _sourceLabel,
                  isUsingGps:    !_sourceSetManually,
                  onSourceChanged: _onSourceChanged,
                  onResetToGps:  _resetSourceToGps,
                ),
                // Connector dots between source and destination rows
                Padding(
                  padding: const EdgeInsets.only(left: 22, top: 2, bottom: 2),
                  child: Column(
                    children: List.generate(
                      3,
                      (_) => Container(
                        width: 3, height: 3,
                        margin: const EdgeInsets.symmetric(vertical: 1.5),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade400, shape: BoxShape.circle),
                      ),
                    ),
                  ),
                ),
                // Destination picker
                DestinationPickerCard(onDestinationChanged: _onDestinationChanged, onClear: _clearDestination),
              ],
            ),
          ),

          // ── Draggable bottom sheet ────────────────────────────────────────
          // Snaps between 35% (map-first) and 75% (content-first).
          // User drags the handle to show more map or more content.
          DraggableScrollableSheet(
            initialChildSize: 0.45,
            minChildSize:     0.18,
            maxChildSize:     0.82,
            snap:             true,
            snapSizes:        const [0.18, 0.45, 0.82],
            builder: (_, scrollController) {
              return Container(
                decoration: const BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(32), topRight: Radius.circular(32)),
                  boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 16)],
                ),
                child: Column(
                  children: [
                    // ── Drag handle ──────────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 4),
                      child: Container(
                        width: 40, height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // ── SOS button (always visible at top of sheet) ──────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: Container(
                        decoration: BoxDecoration(boxShadow: [
                          BoxShadow(
                              color: AppColors.primaryPink.withOpacity(0.25),
                              blurRadius: 12,
                              offset: const Offset(0, 4))
                        ]),
                        child: ElevatedButton(
                          onPressed: () => context.go('/sos'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryPink,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('SOS',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 2)),
                              const SizedBox(width: 8),
                              Text('EMERGENCY',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ── Scrollable cards ─────────────────────────────────────
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                        children: [
                          _buildTripProgressCard(context, remainingKm, tripState),
                          if (tripState.isTripActive) ...[
                            const SizedBox(height: 12),
                            _buildRiskCard(context, tripState.risk),
                          ],
                          const SizedBox(height: 12),
                          _buildDriverInfoCard(context),
                          const SizedBox(height: 12),
                          _buildSharedContactsCard(context),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Live map ──────────────────────────────────────────────────────────────
  Widget _buildLiveMap() {
    const fallback = LatLng(18.5167, 73.8450);
    final center   = _userPosition ?? _dest ?? fallback;

    // Route polyline: blue (OSRM geometry, shown before/during trip)
    // Trip path: pink / red when deviated (GPS trail during active trip)
    final routeColor = const Color(0xFF4285F4); // Google Maps blue
    final pathColor  = _isDeviated ? Colors.red : AppColors.primaryPink;

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom:   15,
        interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag),
      ),
      children: [
        // ── Stadia Maps tile layer ─────────────────────────────────────────
        TileLayer(
          urlTemplate:
              'https://tiles.stadiamaps.com/tiles/alidade_smooth/{z}/{x}/{y}.png'
              '?api_key=$_kStadiaMapsApiKey',
          userAgentPackageName: 'com.example.safher',
          maxZoom: 19,
        ),

        // ── OSRM route polyline (shown when route is available) ────────────
        if (_routePolyline.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points:      List.unmodifiable(_routePolyline),
                color:       routeColor,
                strokeWidth: 5,
              ),
            ],
          ),

        // ── Tracked trip path polyline (only during active trip) ───────────
        if (_tripPath.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points:      List.unmodifiable(_tripPath),
                color:       pathColor,
                strokeWidth: 4,
              ),
            ],
          ),

        // ── Markers ────────────────────────────────────────────────────────
        MarkerLayer(
          markers: [
            // Source marker: green dot (only shown when manually set,
            // otherwise user position marker already marks the origin)
            if (_dest != null)
              Marker(
                point: _dest!,
                width: 40, height: 40,
                child: const Icon(Icons.location_pin, color: Colors.red, size: 40),
              ),

            // Source marker (only when manually chosen — different from GPS)
            if (_sourceSetManually && _source != null)
              Marker(
                point: _source!,
                width: 28, height: 28,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.safeGreenDark,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                          color: AppColors.safeGreenDark.withOpacity(0.4),
                          blurRadius: 8)
                    ],
                  ),
                ),
              ),

            // User position (live GPS dot)
            if (_userPosition != null)
              Marker(
                point: _userPosition!,
                width: 28, height: 28,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.primaryPink,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                          color: AppColors.primaryPink.withOpacity(0.4),
                          blurRadius: 8)
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // ── Trip progress card ─────────────────────────────────────────────────────
  Widget _buildTripProgressCard(
    BuildContext context,
    double? remainingKm,
    TripState tripState,
  ) {
    final bool hasDestination = tripState.hasDestination;
    final double distance     = remainingKm ?? 0.0;
    const double maxDist      = 10.0;
    final double progress     = hasDestination && distance <= maxDist
        ? ((maxDist - distance) / maxDist).clamp(0.0, 1.0)
        : 0.0;

    final bool isActive = tripState.isTripActive;
    final bool isPaused = tripState.isPaused;

    final Color pillBg    = isActive ? AppColors.safeGreen : Colors.grey.shade200;
    final Color pillFg    = isActive ? AppColors.safeGreenDark : AppColors.textGrey;
    final String pillLabel = isPaused
        ? '⏸ Trip Paused'
        : isActive
            ? '● Trip Active: TRUE'
            : '○ Trip Active: FALSE';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Trip in Progress',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      hasDestination
                          ? '${distance.toStringAsFixed(1)} km remaining to safety'
                          : 'Set source and destination above',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Route loading spinner shown next to icon when fetching
              if (_isRouteLoading)
                const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(color: AppColors.primaryPink, strokeWidth: 2),
                )
              else
                const Icon(LucideIcons.checkCircle2, color: AppColors.safeGreenDark, size: 28),
            ],
          ),
          const SizedBox(height: 8),

          // Status pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: pillBg, borderRadius: BorderRadius.circular(20)),
            child: Text(pillLabel,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: pillFg, fontWeight: FontWeight.bold, letterSpacing: 0.4)),
          ),

          // ETA row — shown when route is available
          if (_etaMinutes != null && hasDestination) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(LucideIcons.clock, size: 15, color: AppColors.textGrey),
                const SizedBox(width: 5),
                Text(
                  'ETA: ${_formatEta(_etaMinutes!)}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textGrey, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (!_isRouteLoading)
                  GestureDetector(
                    onTap: _fetchRoute,
                    child: Row(
                      children: [
                        const Icon(LucideIcons.refreshCw, size: 13, color: AppColors.textLight),
                        const SizedBox(width: 3),
                        Text('Recalculate',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: AppColors.textLight)),
                      ],
                    ),
                  ),
              ],
            ),
          ],

          const SizedBox(height: 10),

          // Progress bar
          Stack(
            children: [
              Container(
                height: 8,
                decoration: BoxDecoration(
                    color: Colors.grey.shade200, borderRadius: BorderRadius.circular(4)),
              ),
              FractionallySizedBox(
                widthFactor: progress,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                      color: AppColors.primaryPink, borderRadius: BorderRadius.circular(4)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('START',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.primaryPink, fontWeight: FontWeight.bold)),
              Text('PROGRESS',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.primaryPink, fontWeight: FontWeight.bold)),
              Text('DESTINATION', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: 10),

          // ── Action buttons ───────────────────────────────────────────────
          // IDLE: [Share Trip] [▶ Start Journey]
          // ACTIVE: [Share Trip] [⏸ Pause] [⏹ End Trip]
          // PAUSED: [Share Trip] [▶ Resume] [⏹ End Trip]

          if (!isActive)
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _startJourney,
                    icon: const Icon(LucideIcons.play, size: 16),
                    label: const Text('Start Journey'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryPink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                // Share as icon button to save space for controls
                IconButton(
                  onPressed: _shareTrip,
                  icon: const Icon(LucideIcons.share2, color: AppColors.primaryPink),
                  tooltip: 'Share Trip',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isPaused ? _resumeJourney : _pauseJourney,
                    icon: Icon(isPaused ? LucideIcons.play : LucideIcons.pause, size: 15),
                    label: Text(isPaused ? 'Resume' : 'Pause'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primaryPink,
                      side: const BorderSide(color: AppColors.primaryPink),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _endJourney,
                    icon: const Icon(Icons.close, size: 15),
                    label: const Text('End Trip'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryPink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _formatEta(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  // ── Driver info card — reads from verifyProvider (UNCHANGED) ─────────────
  Widget _buildDriverInfoCard(BuildContext context) {
    final verifyAsync = ref.watch(verifyProvider);
    final data = verifyAsync.maybeWhen(data: (v) => v, orElse: () => null);
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
                      color: AppColors.primaryPink, fontWeight: FontWeight.bold, fontSize: 22),
                ),
              ),
              if (isVerified)
                Positioned(
                  bottom: -10, left: 0, right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                        color: AppColors.safeGreen, borderRadius: BorderRadius.circular(10)),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [Icon(Icons.verified, size: 10, color: AppColors.safeGreenDark)],
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
                Text(driverName,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                Text(vehicleInfo,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textGrey)),
              ],
            ),
          ),
          Column(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(color: AppColors.background, shape: BoxShape.circle),
                child: const Icon(LucideIcons.phone, size: 20),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: AppColors.buttonBlue, borderRadius: BorderRadius.circular(8)),
                child: const Icon(LucideIcons.qrCode, size: 20, color: AppColors.buttonBlueText),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Shared contacts card — reads from contactsProvider (UNCHANGED) ────────
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
              Text('Shared Contacts',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              contactsAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
                data: (contacts) => contacts.isEmpty
                    ? const SizedBox.shrink()
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                            color: AppColors.lightPink, borderRadius: BorderRadius.circular(10)),
                        child: Text('${contacts.length} Active',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: AppColors.primaryPink, fontWeight: FontWeight.bold)),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          contactsAsync.when(
            loading: () => const SizedBox(
              height: 70,
              child: Center(
                  child: CircularProgressIndicator(color: AppColors.primaryPink, strokeWidth: 2)),
            ),
            error: (_, _) => Text('Could not load contacts.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textGrey)),
            data: (contacts) {
              if (contacts.isEmpty) {
                return Text('No emergency contacts added yet.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textGrey));
              }
              final visible = contacts.take(4).toList();
              return Row(
                children: [
                  ...visible.map((c) => Padding(
                      padding: const EdgeInsets.only(right: 12), child: _buildContactAvatar(c))),
                  if (contacts.length < 4)
                    GestureDetector(
                      onTap: () => context.go('/contacts'),
                      child: Column(
                        children: [
                          Container(
                            width: 50, height: 50,
                            decoration: BoxDecoration(
                                color: Colors.grey.shade200, shape: BoxShape.circle),
                            child: const Icon(Icons.add, color: AppColors.textGrey),
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

  Widget _buildContactAvatar(Contact contact) {
    final initial   = contact.name.isNotEmpty ? contact.name[0].toUpperCase() : '?';
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
            child: Text(initial,
                style: const TextStyle(
                    color: AppColors.primaryPink, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ),
        const SizedBox(height: 4),
        Text(shortName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
      ],
    );
  }

  // ── NEW: Live Risk Card ─────────────────────────────────────────────────
  // Only rendered while isTripActive == true (see insertion point in build()).
  // Layout: coloured left border + score badge + level label + reason text.

  Widget _buildRiskCard(BuildContext context, RiskSnapshot risk) {
    final cfg = _riskConfig(risk.level);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cfg.bg,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        border: Border(left: BorderSide(color: cfg.accent, width: 4)),
        boxShadow: [
          BoxShadow(
            color: cfg.accent.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Score circle ─────────────────────────────────────────────
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cfg.accent,
            ),
            child: Center(
              child: Text(
                '${risk.score}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),

          // ── Text ──────────────────────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(cfg.icon, color: cfg.accent, size: 15),
                    const SizedBox(width: 5),
                    Text(
                      'RISK: ${risk.level.label.toUpperCase()}',
                      style: TextStyle(
                        color: cfg.accent,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  risk.score == 0 ? 'Monitoring your journey' : risk.reason,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textDark,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),

          // ── Progress bar (vertical mini) ──────────────────────────────
          Column(
            children: [
              Text(
                '${risk.score}/100',
                style: TextStyle(
                  color: cfg.accent,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: 40,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: risk.score / 100.0,
                    minHeight: 6,
                    backgroundColor: cfg.accent.withOpacity(0.15),
                    valueColor: AlwaysStoppedAnimation<Color>(cfg.accent),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  _RiskConfig _riskConfig(RiskLevel level) {
    switch (level) {
      case RiskLevel.safe:
        return _RiskConfig(
          bg:     AppColors.safeGreenLight,
          accent: AppColors.safeGreenDark,
          icon:   Icons.shield_outlined,
        );
      case RiskLevel.caution:
        return _RiskConfig(
          bg:     const Color(0xFFFEF3C7), // amber-50
          accent: AppColors.warningOrange,
          icon:   Icons.warning_amber_outlined,
        );
      case RiskLevel.highRisk:
        return _RiskConfig(
          bg:     AppColors.alertBg,
          accent: AppColors.primaryPink,
          icon:   Icons.warning_rounded,
        );
      case RiskLevel.critical:
        return _RiskConfig(
          bg:     const Color(0xFFFEE2E2),
          accent: const Color(0xFFB91C1C),
          icon:   Icons.crisis_alert_rounded,
        );
    }
  }
}

// ── Risk card styling helper ──────────────────────────────────────────────
class _RiskConfig {
  final Color   bg;
  final Color   accent;
  final IconData icon;
  const _RiskConfig({required this.bg, required this.accent, required this.icon});
}
