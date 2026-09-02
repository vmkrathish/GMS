// ─────────────────────────────────────────────
// core/widgets/booking_sheet.dart
//
// Shared "request booking" bottom sheet — the address-picker (Home
// address / Pinned location / Current GPS, all reverse-geocoded to
// readable text), date/time picker, and notes field. Used from
// anywhere a service card can be tapped to book: Home's
// "Recommended for You", the live Map, and a provider's public
// profile page. Extracted from home_screen.dart so all three stay
// in sync automatically instead of drifting into duplicate,
// inconsistently-fixed copies (a repeated source of bugs earlier in
// this project).
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../api/booking_api.dart';
import '../api/geo_api.dart';
import '../api/user_api.dart';
import '../theme/app_theme.dart';

Future<void> openBookingSheet(BuildContext context, Map<String, dynamic> s) async {
  final serviceId = int.tryParse('${s['id'] ?? s['service_id']}');
  if (serviceId == null) return;

  final name = (s['provider_name'] ?? 'Provider').toString();
  final title = (s['title'] ?? s['service_title'] ?? '').toString();
  final price = (s['price'] ?? s['base_price'] ?? '—').toString();
  final emoji = (s['category_emoji'] ?? '🛠️').toString();

  final addressCtrl = TextEditingController();
  final notesCtrl = TextEditingController();
  DateTime? scheduledAt;
  double? bookingLat;
  double? bookingLng;
  String selectedAddressChip = ''; // 'home' | 'current' | ''
  bool booking = false;

  // Fetch the user's own profile fresh — self-sufficient, doesn't
  // depend on the You tab having been visited first (default 3
  // address suggestions vary per logged-in user).
  Map<String, dynamic> profile = {};
  final profileRes = await UserApi.getMe();
  if (profileRes.success && profileRes.data is Map) {
    profile = Map<String, dynamic>.from(profileRes.data['user'] ?? {});
  }

  String homeAddress() {
    final parts = [
      profile['address_line1'],
      profile['area_street_village'],
      profile['landmark'],
      profile['city'],
      profile['state'],
      profile['pincode'],
    ].where((e) => (e ?? '').toString().trim().isNotEmpty).join(', ');
    return parts.isEmpty ? (profile['location_text'] ?? '').toString() : parts;
  }

  final hasPinned =
      profile['latitude'] != null && profile['longitude'] != null;

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 30)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        Text('by $name  •  ₹$price',
                            style: const TextStyle(
                                fontSize: 13, color: Colors.black54)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // schedule picker (now or later — your Rapido+scheduling model)
              InkWell(
                onTap: () async {
                  final date = await showDatePicker(
                    context: ctx,
                    initialDate: DateTime.now(),
                    firstDate: DateTime.now(),
                    lastDate:
                        DateTime.now().add(const Duration(days: 30)),
                  );
                  if (date == null || !ctx.mounted) return;
                  final time = await showTimePicker(
                      context: ctx, initialTime: TimeOfDay.now());
                  if (time == null) return;
                  setSheet(() => scheduledAt = DateTime(date.year,
                      date.month, date.day, time.hour, time.minute));
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                      labelText: 'When do you need it?',
                      prefixIcon: Icon(Icons.event)),
                  child: Text(
                    scheduledAt == null
                        ? 'As soon as possible'
                        : '${scheduledAt!.day}/${scheduledAt!.month}/${scheduledAt!.year}  ${scheduledAt!.hour.toString().padLeft(2, '0')}:${scheduledAt!.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 14.5),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text('Service address',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // Home — this now IS what "Pinned Location" used to
                  // be: the exact coordinates pinned on the profile's
                  // map picker, reverse-geocoded to a readable label.
                  // Previously Home and Pinned Location silently used
                  // the identical coordinates but showed two
                  // different labels (one typed, one geocoded) — a
                  // confusing, redundant pair now merged into one.
                  ChoiceChip(
                    label: const Text('🏠 Home'),
                    selected: selectedAddressChip == 'home',
                    onSelected: !hasPinned
                        ? null
                        : (_) async {
                            final lat =
                                double.tryParse('${profile['latitude']}');
                            final lng =
                                double.tryParse('${profile['longitude']}');
                            if (lat == null || lng == null) return;

                            // Reverse-geocode via our own backend — the
                            // `geocoding` plugin has no Web
                            // implementation and used to silently fall
                            // back to raw coordinates on Flutter Web.
                            final resolved =
                                await GeoApi.reverseGeocode(lat, lng);
                            final label = resolved ?? homeAddress();

                            if (!ctx.mounted) return;
                            setSheet(() {
                              selectedAddressChip = 'home';
                              bookingLat = lat;
                              bookingLng = lng;
                              addressCtrl.text = label;
                            });
                          },
                  ),
                  // Option: Live GPS right now
                  ChoiceChip(
                    label: const Text('🧭 Current Location'),
                    selected: selectedAddressChip == 'current',
                    onSelected: (_) async {
                      LocationPermission perm =
                          await Geolocator.checkPermission();
                      if (perm == LocationPermission.denied) {
                        perm = await Geolocator.requestPermission();
                      }
                      if (perm == LocationPermission.denied ||
                          perm == LocationPermission.deniedForever) {
                        if (!ctx.mounted) return;
                        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                            content: Text('Location permission denied')));
                        return;
                      }
                      final pos = await Geolocator.getCurrentPosition();
                      // Reverse-geocode via our backend — the
                      // `geocoding` plugin has no Web implementation,
                      // which is why raw coordinates used to show up
                      // here instead of a place name.
                      final resolved = await GeoApi.reverseGeocode(
                          pos.latitude, pos.longitude);
                      final label = resolved ?? 'Current location pinned';
                      if (!ctx.mounted) return;
                      setSheet(() {
                        selectedAddressChip = 'current';
                        bookingLat = pos.latitude;
                        bookingLng = pos.longitude;
                        addressCtrl.text = label;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: addressCtrl,
                onChanged: (_) => setSheet(() => selectedAddressChip = ''),
                decoration: const InputDecoration(
                    hintText: 'Or type an address manually',
                    prefixIcon: Icon(Icons.location_on_outlined)),
              ),
              if (bookingLat != null && bookingLng != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.my_location,
                          size: 14, color: Colors.green),
                      const SizedBox(width: 4),
                      Text(
                        'Exact location attached (${bookingLat!.toStringAsFixed(4)}, ${bookingLng!.toStringAsFixed(4)})',
                        style: const TextStyle(
                            fontSize: 11.5, color: Colors.green),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              TextField(
                controller: notesCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                    labelText: 'Notes for the provider (optional)',
                    prefixIcon: Icon(Icons.notes_outlined)),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: booking
                      ? null
                      : () async {
                          setSheet(() => booking = true);
                          final res = await BookingApi.createBooking(
                            serviceId: serviceId,
                            scheduledAt: scheduledAt,
                            address: addressCtrl.text.trim().isEmpty
                                ? null
                                : addressCtrl.text.trim(),
                            notes: notesCtrl.text.trim().isEmpty
                                ? null
                                : notesCtrl.text.trim(),
                            latitude: bookingLat,
                            longitude: bookingLng,
                          );
                          if (!ctx.mounted) return;
                          setSheet(() => booking = false);
                          if (res.success) {
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Request sent! Provider will respond — track it in Bookings 📋')));
                          } else {
                            ScaffoldMessenger.of(ctx)
                                .showSnackBar(SnackBar(
                                    content: Text(res.isOffline
                                        ? 'Unable to connect. Please check your connection.'
                                        : res.message)));
                          }
                        },
                  child: booking
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white))
                      : const Text('Request Booking',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
