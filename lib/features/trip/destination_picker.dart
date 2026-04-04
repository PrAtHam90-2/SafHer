// lib/features/trip/destination_picker.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../core/theme/app_colors.dart';

// ============================================================================
//  NominatimResult
// ============================================================================

class NominatimResult {
  final String displayName;
  final String shortName;
  final double lat;
  final double lng;

  NominatimResult({
    required this.displayName,
    required this.shortName,
    required this.lat,
    required this.lng,
  });

  factory NominatimResult.fromJson(Map<String, dynamic> json) {
    final display = json['display_name'] as String? ?? '';
    String short  = display;
    final addr    = json['address'] as Map<String, dynamic>?;
    if (addr != null) {
      final primary = (addr['road']         as String?) ??
                      (addr['amenity']       as String?) ??
                      (addr['suburb']        as String?) ??
                      (addr['neighbourhood'] as String?) ??
                      (addr['city_district'] as String?) ?? '';
      final secondary = (addr['suburb']       as String?) ??
                        (addr['city_district'] as String?) ??
                        (addr['city']          as String?) ??
                        (addr['town']          as String?) ?? '';
      if (primary.isNotEmpty && secondary.isNotEmpty && primary != secondary) {
        short = '$primary, $secondary';
      } else if (primary.isNotEmpty) {
        short = primary;
      } else {
        final parts = display.split(',');
        short = parts.length >= 2
            ? '${parts[0].trim()}, ${parts[1].trim()}'
            : parts[0].trim();
      }
    } else {
      final parts = display.split(',');
      short = parts.length >= 2
          ? '${parts[0].trim()}, ${parts[1].trim()}'
          : parts[0].trim();
    }
    return NominatimResult(
      displayName: display,
      shortName:   short,
      lat: double.tryParse(json['lat'] as String? ?? '') ?? 0,
      lng: double.tryParse(json['lon'] as String? ?? '') ?? 0,
    );
  }
}

// ============================================================================
//  Nominatim search helper
// ============================================================================

class NominatimRateLimitException implements Exception {}

Future<List<NominatimResult>> searchPlaces(
  String query, {
  http.Client? client,
}) async {
  if (query.trim().length < 3) return [];

  final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
    'q':              query.trim(),
    'format':         'json',
    'limit':          '6',
    'countrycodes':   'in',
    'viewbox':        '73.6,18.8,74.1,18.3',
    'bounded':        '1',
    'addressdetails': '1',
    'dedupe':         '1',
  });

  final headers = {
    'User-Agent':      'SafHer/1.0 (github.com/safher-app)',
    'Accept-Language': 'en',
  };

  final c = client ?? http.Client();
  try {
    final response = await c
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode == 429) throw NominatimRateLimitException();
    if (response.statusCode != 200) return [];
    final List<dynamic> data = jsonDecode(response.body);
    return data
        .map((j) => NominatimResult.fromJson(j as Map<String, dynamic>))
        .toList();
  } finally {
    if (client == null) c.close();
  }
}

// ============================================================================
//  DestinationPickerCard — UNCHANGED external API
// ============================================================================

class DestinationPickerCard extends ConsumerStatefulWidget {
  final void Function(LatLng latLng, String label) onDestinationChanged;

  /// Called when the user taps the × clear button.
  /// If null, no clear button is shown.
  final VoidCallback? onClear;

  const DestinationPickerCard({
    super.key,
    required this.onDestinationChanged,
    this.onClear,
  });

  @override
  ConsumerState<DestinationPickerCard> createState() =>
      _DestinationPickerCardState();
}

class _DestinationPickerCardState
    extends ConsumerState<DestinationPickerCard> {
  String _destLabel = 'Tap to set destination';

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _showSearchSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 2)),
          ],
        ),
        child: Row(
          children: [
            const Icon(LucideIcons.mapPin, color: AppColors.primaryPink, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('DESTINATION',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.textLight, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                Text(_destLabel,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis),
              ]),
            ),
            // Clear button when dest is set; search icon otherwise
            if (widget.onClear != null && _destLabel != 'Tap to set destination')
              GestureDetector(
                onTap: () {
                  widget.onClear!();
                  setState(() => _destLabel = 'Tap to set destination');
                },
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: Colors.grey.shade200, shape: BoxShape.circle),
                  child: const Icon(Icons.close, color: AppColors.textGrey, size: 14),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: AppColors.lightPink, borderRadius: BorderRadius.circular(20)),
                child: const Icon(LucideIcons.search, color: AppColors.primaryPink, size: 16),
              ),
          ],
        ),
      ),
    );
  }

  void _showSearchSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PlaceSearchSheet(
        onSelected: (result) {
          setState(() => _destLabel = result.shortName);
          widget.onDestinationChanged(LatLng(result.lat, result.lng), result.shortName);
        },
      ),
    );
  }
}

// ============================================================================
//  SourcePickerCard — NEW
// ============================================================================

class SourcePickerCard extends StatelessWidget {
  final String label;
  final bool isUsingGps;
  final void Function(LatLng latLng, String label) onSourceChanged;
  final VoidCallback onResetToGps;

  const SourcePickerCard({
    super.key,
    required this.label,
    required this.isUsingGps,
    required this.onSourceChanged,
    required this.onResetToGps,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showSearchSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 2)),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 18, height: 18,
              decoration: BoxDecoration(
                color: AppColors.safeGreenDark, shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [BoxShadow(color: AppColors.safeGreenDark.withOpacity(0.3), blurRadius: 4)],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('STARTING FROM',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.textLight, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                Text(label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (isUsingGps)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: AppColors.safeGreenLight, borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(LucideIcons.navigation, color: AppColors.safeGreenDark, size: 12),
                  const SizedBox(width: 4),
                  Text('GPS',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.safeGreenDark, fontWeight: FontWeight.bold)),
                ]),
              )
            else
              GestureDetector(
                onTap: onResetToGps,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: Colors.grey.shade200, shape: BoxShape.circle),
                  child: const Icon(Icons.close, color: AppColors.textGrey, size: 14),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showSearchSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PlaceSearchSheet(
        title: 'Where are you starting from?',
        onSelected: (result) {
          onSourceChanged(LatLng(result.lat, result.lng), result.shortName);
        },
      ),
    );
  }
}

// ============================================================================
//  PlaceSearchSheet — formerly _DestinationSearchSheet (now public + title param)
// ============================================================================

class PlaceSearchSheet extends StatefulWidget {
  final void Function(NominatimResult) onSelected;
  final String title;

  const PlaceSearchSheet({
    super.key,
    required this.onSelected,
    this.title = 'Where are you going?',
  });

  @override
  State<PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<PlaceSearchSheet> {
  final _ctrl = TextEditingController();
  List<NominatimResult> _results = [];
  bool _loading = false;
  String? _error;
  Timer? _debounce;
  late http.Client _httpClient;

  @override
  void initState() {
    super.initState();
    _httpClient = http.Client();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _httpClient.close();
    _ctrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 3) {
      setState(() { _results = []; _error = null; _loading = false; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    _debounce = Timer(const Duration(milliseconds: 500), () => _executeSearch(query));
  }

  Future<void> _executeSearch(String query) async {
    if (!mounted) return;
    try {
      final results = await searchPlaces(query, client: _httpClient);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
        _error   = results.isEmpty ? 'No results found in Pune. Try a different search.' : null;
      });
    } on NominatimRateLimitException {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Too many searches. Please wait a moment.'; });
    } on TimeoutException {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Search timed out. Check your connection.'; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Search failed. Check your connection.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(widget.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Search for a place…',
                    prefixIcon: const Icon(LucideIcons.search, color: AppColors.primaryPink),
                    suffixIcon: _ctrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _ctrl.clear();
                              _debounce?.cancel();
                              setState(() { _results = []; _error = null; _loading = false; });
                            })
                        : null,
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                  onChanged: _onQueryChanged,
                ),
              ),
              const SizedBox(height: 8),
              if (_loading)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(color: AppColors.primaryPink, strokeWidth: 2))
              else if (_error != null)
                Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, style: const TextStyle(color: AppColors.textGrey)))
              else
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      return ListTile(
                        leading: const Icon(LucideIcons.mapPin, color: AppColors.primaryPink),
                        title: Text(r.shortName,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text(r.displayName,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: AppColors.textGrey, fontSize: 12)),
                        onTap: () {
                          Navigator.pop(context);
                          widget.onSelected(r);
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
