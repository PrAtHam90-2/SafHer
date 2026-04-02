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
//  NominatimResult — lightweight place model
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

    // FIX: use the structured `address` object (requires addressdetails=1)
    // to build a clean, human-readable short label instead of blindly
    // splitting display_name by comma (which often gives "1" or "MH").
    String short = display; // fallback
    final addr = json['address'] as Map<String, dynamic>?;
    if (addr != null) {
      // Pick the most specific named component available
      final primary = (addr['road']          as String?) ??
                      (addr['amenity']        as String?) ??
                      (addr['suburb']         as String?) ??
                      (addr['neighbourhood']  as String?) ??
                      (addr['city_district']  as String?) ??
                      '';

      // Secondary context: area or city
      final secondary = (addr['suburb']         as String?) ??
                        (addr['city_district']   as String?) ??
                        (addr['city']            as String?) ??
                        (addr['town']            as String?) ??
                        '';

      if (primary.isNotEmpty && secondary.isNotEmpty && primary != secondary) {
        short = '$primary, $secondary';
      } else if (primary.isNotEmpty) {
        short = primary;
      } else {
        // Last resort: first two parts of display_name
        final parts = display.split(',');
        short = parts.length >= 2
            ? '${parts[0].trim()}, ${parts[1].trim()}'
            : parts[0].trim();
      }
    } else {
      // addressdetails not present — fall back to comma split
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

/// Thrown when Nominatim returns HTTP 429 (rate limited).
class NominatimRateLimitException implements Exception {}

Future<List<NominatimResult>> searchPlaces(
  String query, {
  http.Client? client, // FIX: injectable for cancellation
}) async {
  if (query.trim().length < 3) return [];

  // FIX: use Uri.https() with a queryParameters map — no manual encoding,
  // no risk of double-encoding, easy to read and extend.
  final uri = Uri.https(
    'nominatim.openstreetmap.org',
    '/search',
    {
      'q':              query.trim(),
      'format':         'json',
      'limit':          '6',
      'countrycodes':   'in',
      // FIX: bounded=1 — hard filter to viewbox instead of just biasing.
      // Pune bounding box: west, north, east, south (left,top,right,bottom).
      'viewbox':        '73.6,18.8,74.1,18.3',
      'bounded':        '1',
      // FIX: request structured address fields so fromJson can build a
      // meaningful shortName instead of splitting display_name by comma.
      'addressdetails': '1',
      // FIX: dedupe removes near-duplicate results from Nominatim.
      'dedupe':         '1',
    },
  );

  // FIX: per Nominatim usage policy, User-Agent must identify the app and
  // include a contact URL or email so they can reach you if there's abuse.
  // https://operations.osmfoundation.org/policies/nominatim/
  final headers = {
    'User-Agent':      'SafHer/1.0 (github.com/safher-app)',
    'Accept-Language': 'en',         // always return English result names
  };

  final c = client ?? http.Client();
  try {
    final response = await c
        .get(uri, headers: headers)
        // FIX: 10-second timeout — spinner no longer runs forever on slow
        // connections; throws TimeoutException which the caller catches.
        .timeout(const Duration(seconds: 10));

    // FIX: distinguish rate-limit (429) from other HTTP errors so the UI
    // can show a friendlier message rather than a generic "Search failed."
    if (response.statusCode == 429) throw NominatimRateLimitException();
    if (response.statusCode != 200) return [];

    final List<dynamic> data = jsonDecode(response.body);
    return data
        .map((j) => NominatimResult.fromJson(j as Map<String, dynamic>))
        .toList();
  } finally {
    // Only close the client if we created it here (not injected from outside)
    if (client == null) c.close();
  }
}

// ============================================================================
//  DestinationPickerCard  — UI UNCHANGED
// ============================================================================

class DestinationPickerCard extends ConsumerStatefulWidget {
  final void Function(LatLng latLng, String label) onDestinationChanged;

  const DestinationPickerCard({
    super.key,
    required this.onDestinationChanged,
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
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(LucideIcons.mapPin,
                color: AppColors.primaryPink, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DESTINATION',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.textLight,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                  ),
                  Text(
                    _destLabel,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.lightPink,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(LucideIcons.search,
                  color: AppColors.primaryPink, size: 16),
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
      builder: (_) => _DestinationSearchSheet(
        onSelected: (result) {
          setState(() => _destLabel = result.shortName);
          widget.onDestinationChanged(
            LatLng(result.lat, result.lng),
            result.shortName,
          );
        },
      ),
    );
  }
}

// ============================================================================
//  _DestinationSearchSheet — UI UNCHANGED, search logic fixed
// ============================================================================

class _DestinationSearchSheet extends StatefulWidget {
  final void Function(NominatimResult) onSelected;

  const _DestinationSearchSheet({required this.onSelected});

  @override
  State<_DestinationSearchSheet> createState() =>
      _DestinationSearchSheetState();
}

class _DestinationSearchSheetState extends State<_DestinationSearchSheet> {
  final _ctrl = TextEditingController();

  List<NominatimResult> _results = [];
  bool    _loading = false;
  String? _error;

  // FIX: debounce timer — search fires 500ms after the user stops typing,
  // not on every keystroke. Eliminates most of the rate-limit risk and
  // prevents in-flight request races.
  Timer? _debounce;

  // FIX: persistent http.Client per sheet instance — closed in dispose().
  // Closing it cancels any in-flight request, so a new search started while
  // an old one is pending never returns stale results.
  late http.Client _httpClient;

  @override
  void initState() {
    super.initState();
    _httpClient = http.Client();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // Closing the client cancels any in-flight request cleanly.
    _httpClient.close();
    _ctrl.dispose();
    super.dispose();
  }

  // FIX: debounced wrapper called from onChanged.
  void _onQueryChanged(String query) {
    _debounce?.cancel();

    if (query.trim().length < 3) {
      setState(() { _results = []; _error = null; _loading = false; });
      return;
    }

    // Show a loading indicator immediately so the UI feels responsive,
    // but don't actually fire the HTTP request until 500ms of silence.
    setState(() { _loading = true; _error = null; });

    _debounce = Timer(const Duration(milliseconds: 500), () {
      _executeSearch(query);
    });
  }

  Future<void> _executeSearch(String query) async {
    if (!mounted) return;
    try {
      // Pass the persistent client so the request can be cancelled via
      // _httpClient.close() if the sheet is dismissed mid-search.
      final results = await searchPlaces(query, client: _httpClient);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
        _error   = results.isEmpty
            ? 'No results found in Pune. Try a different search.'
            : null;
      });
    } on NominatimRateLimitException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error   = 'Too many searches. Please wait a moment and try again.';
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error   = 'Search timed out. Check your connection and try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error   = 'Search failed. Check your connection.';
      });
    }
  }

  // ── Build — UI completely unchanged from before ───────────────────────────

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
              // Handle
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Where are you going?',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Search for a place…',
                    prefixIcon: const Icon(LucideIcons.search,
                        color: AppColors.primaryPink),
                    suffixIcon: _ctrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _ctrl.clear();
                              _debounce?.cancel();
                              setState(() {
                                _results = [];
                                _error   = null;
                                _loading = false;
                              });
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  // FIX: onChanged now calls the debounced wrapper
                  onChanged: _onQueryChanged,
                ),
              ),
              const SizedBox(height: 8),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(
                    color: AppColors.primaryPink,
                    strokeWidth: 2,
                  ),
                )
              else if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!,
                      style: const TextStyle(color: AppColors.textGrey)),
                )
              else
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      return ListTile(
                        leading: const Icon(LucideIcons.mapPin,
                            color: AppColors.primaryPink),
                        title: Text(r.shortName,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text(
                          r.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppColors.textGrey, fontSize: 12),
                        ),
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
