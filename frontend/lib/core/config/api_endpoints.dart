/// Every backend endpoint in one place — mirrors gms_backend routes.
class ApiEndpoints {
  // ── Auth ──────────────────────────────────
  static const verifyOtp = '/auth/verify-otp';
  static const register  = '/auth/register';
  static const signup    = '/auth/signup';   // simple auth (MVP)
  static const login     = '/auth/login';    // simple auth (MVP)
  static const changePassword = '/auth/change-password';
  static const verifyPassword = '/auth/verify-password';

  // ── Users ─────────────────────────────────
  static const me        = '/users/me';           // GET, PUT
  static const fcmToken  = '/users/fcm';          // PUT
  static const meAvatar  = '/users/me/avatar';    // POST upload, DELETE remove
  static String userById(int id) => '/users/$id'; // GET

  // ── Services & categories ─────────────────
  static const categories   = '/services/categories';   // GET
  static const suggestions  = '/services/suggestions';  // GET ?q=, POST {term}
  static const services     = '/services';              // GET list, POST create
  static String serviceById(int id) => '/services/$id'; // GET, PUT, DELETE

  // ── Bookings ──────────────────────────────
  static const bookings         = '/bookings';           // POST create
  static const myBookings       = '/bookings/mine';      // GET (as customer)
  static const receivedBookings = '/bookings/received';  // GET (as provider)
  static String bookingById(int id)     => '/bookings/$id';        // GET
  static String bookingStatus(int id)   => '/bookings/$id/status'; // PUT (back-compat)
  static String bookingAction(int id)   => '/bookings/$id/action'; // PUT (workflow)
  static String bookingEvents(int id)   => '/bookings/$id/events'; // GET (timeline)

  // ── Notifications ─────────────────────────
  static const notifications = '/notifications';              // GET
  static const readAll       = '/notifications/read-all';     // PUT
  static String notifRead(int id)   => '/notifications/$id/read'; // PUT
  static String notifDelete(int id) => '/notifications/$id';      // DELETE

  // ── Chats ─────────────────────────────────
  static const chats = '/chats';                        // GET conversations
  static String chatThread(int userId) => '/chats/$userId'; // GET thread, POST send

  // ── Misc ──────────────────────────────────
  static const health = '/health'; // note: served at root, not /api
}
