// ═══════════════════════════════════════════════════════════
//  company_info.dart — THE ONE PLACE to set GMS's own contact
//  details: support email, phone, and address.
//
//  Every screen that shows this info (About GMS, Help & Support,
//  and anywhere else in the future — including a website, if one
//  gets built later) reads from here. Change it once, it's
//  reflected everywhere automatically — nothing else in the
//  codebase should ever hardcode these values directly.
// ═══════════════════════════════════════════════════════════
class CompanyInfo {
  static const String supportEmail = "getmyservice.gms@gmail.com";
  static const String supportPhone = "+91 87781 75453";
  static const String address = "Tamil Nadu, India";

  /// Same phone number, digits only, for tel: links.
  static String get supportPhoneDialable =>
      supportPhone.replaceAll(RegExp(r'[^0-9+]'), '');
}
