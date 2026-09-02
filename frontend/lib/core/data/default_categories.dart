// ─────────────────────────────────────────────
// core/data/default_categories.dart
//
// OFFLINE FALLBACK ONLY.
// Mirrors gms_backend/sql/seed_categories.sql so the home
// screen never renders empty when the API/DB is unreachable.
// Once the backend responds, live data replaces this list.
// ─────────────────────────────────────────────
class DefaultCategories {
  static const List<Map<String, dynamic>> list = [
    {'id': 1,  'name': 'Plumbing',           'emoji': '🔧'},
    {'id': 2,  'name': 'Electrical',         'emoji': '⚡'},
    {'id': 3,  'name': 'Cleaning',           'emoji': '🧹'},
    {'id': 4,  'name': 'AC & Appliances',    'emoji': '❄️'},
    {'id': 5,  'name': 'Carpentry',          'emoji': '🪚'},
    {'id': 6,  'name': 'Painting',           'emoji': '🎨'},
    {'id': 7,  'name': 'Bike Mechanic',      'emoji': '🏍️'},
    {'id': 8,  'name': 'Car Mechanic',       'emoji': '🚗'},
    {'id': 9,  'name': 'Beauty & Salon',     'emoji': '💇'},
    {'id': 10, 'name': 'Home Nursing',       'emoji': '🩺'},
    {'id': 11, 'name': 'Tutoring',           'emoji': '📚'},
    {'id': 12, 'name': 'Graphic Design',     'emoji': '🖌️'},
    {'id': 13, 'name': 'Video Editing',      'emoji': '🎬'},
    {'id': 14, 'name': 'Photography',        'emoji': '📸'},
    {'id': 15, 'name': 'Web Development',    'emoji': '💻'},
    {'id': 16, 'name': 'App Development',    'emoji': '📱'},
    {'id': 17, 'name': 'Digital Marketing',  'emoji': '📣'},
    {'id': 18, 'name': 'Content Writing',    'emoji': '✍️'},
    {'id': 19, 'name': 'Computer Repair',    'emoji': '🖥️'},
    {'id': 20, 'name': 'Mobile Repair',      'emoji': '📲'},
    {'id': 21, 'name': 'Pest Control',       'emoji': '🐜'},
    {'id': 22, 'name': 'Gardening',          'emoji': '🌱'},
    {'id': 23, 'name': 'Farming Assistance', 'emoji': '🚜'},
    {'id': 24, 'name': 'Babysitting',        'emoji': '👶'},
    {'id': 25, 'name': 'Elder Care',         'emoji': '🧓'},
    {'id': 26, 'name': 'Pet Care',           'emoji': '🐶'},
    {'id': 27, 'name': 'Cooking & Chef',     'emoji': '👨‍🍳'},
    {'id': 28, 'name': 'Laundry & Ironing',  'emoji': '👕'},
    {'id': 29, 'name': 'Event Support',      'emoji': '🎉'},
    {'id': 30, 'name': 'Packers & Movers',   'emoji': '📦'},
    {'id': 31, 'name': 'CCTV & Security',    'emoji': '📹'},
    {'id': 32, 'name': 'Tailoring',          'emoji': '🧵'},
    {'id': 33, 'name': 'Driver on Demand',   'emoji': '🚕'},
    {'id': 34, 'name': 'Yoga & Fitness',     'emoji': '🧘'},
    {'id': 35, 'name': 'Legal Services',     'emoji': '⚖️'},
    {'id': 36, 'name': 'Accounting & Tax',   'emoji': '🧾'},
    {'id': 37, 'name': 'Interior Design',    'emoji': '🛋️'},
    {'id': 38, 'name': 'Welding & Fabrication','emoji': '🔩'},
    {'id': 39, 'name': 'Water Purifier Service','emoji': '💧'},
    {'id': 40, 'name': 'Solar & Inverter',   'emoji': '🔆'},
  ];

  /// Fallback autocomplete terms (subset — server list is richer).
  static const List<String> searchTerms = [
    'plumber', 'electrician', 'house cleaning', 'ac repair', 'carpenter',
    'painter', 'bike service', 'car service', 'makeup artist', 'mehendi',
    'home tutor', 'logo design', 'wedding photography', 'drone photography',
    'website design', 'laptop repair', 'mobile repair', 'pest control',
    'gardener', 'coconut tree climber', 'babysitter', 'elder care',
    'pet grooming', 'cook', 'catering', 'laundry', 'birthday decoration',
    'house shifting', 'cctv installation', 'tailor', 'driver', 'yoga trainer',
    'gst filing', 'interior designer', 'ro service', 'solar panel installation',
  ];
}
