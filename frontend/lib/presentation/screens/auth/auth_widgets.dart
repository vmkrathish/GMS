// ─────────────────────────────────────────────
// presentation/screens/auth/auth_widgets.dart
//
// Shared pieces of the Sign In / Sign Up screens so every auth screen has
// the same GMS header, widths, buttons and transitions:
//   • AuthHeader       — the existing blue GMS header (logo + tagline),
//                         optionally with a back arrow
//   • AuthBody         — centred, max 480 px wide (phones AND Flutter Web)
//   • GoogleButton     — "Continue with Google" — NOT available yet: shown
//                         greyed with a "Coming soon" tag; tapping only
//                         explains that (no OAuth in this phase)
//   • SoonTag          — the small grey "Coming soon" tag
//   • OrDivider, AuthLabel, PasswordRule
//   • authRoute()      — fade + slight slide page transition
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Fade + small upward slide, used between the auth screens.
Route<T> authRoute<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, anim, _, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.04), end: Offset.zero)
                .animate(curved),
            child: child,
          ),
        );
      },
    );

class AuthHeader extends StatelessWidget {
  /// Shows a back arrow (Sign Up screens).
  final bool showBack;

  /// Smaller header for the inner Sign Up steps.
  final bool compact;

  const AuthHeader({super.key, this.showBack = false, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: compact ? 22 : 40),
      decoration: const BoxDecoration(
        gradient: AppTheme.gmsGradient,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(36),
          bottomRight: Radius.circular(36),
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Column(
            children: [
              Container(
                padding: EdgeInsets.all(compact ? 10 : 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(compact ? 16 : 22),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 14,
                        offset: const Offset(0, 6)),
                  ],
                ),
                child: Image.asset('assets/images/gms_logo.png',
                    height: compact ? 40 : 56),
              ),
              SizedBox(height: compact ? 10 : 14),
              Text('Get My Service',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: compact ? 19 : 22,
                      fontWeight: FontWeight.bold)),
              if (!compact) ...[
                const SizedBox(height: 4),
                const Text('Any service. Any time. One app.',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
              ],
            ],
          ),
          if (showBack)
            Positioned(
              left: 4,
              top: 0,
              child: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
        ],
      ),
    );
  }
}

/// Centres the form and caps its width so it looks right on wide web
/// windows as well as phones.
class AuthBody extends StatelessWidget {
  final Widget child;
  const AuthBody({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: child,
        ),
      ),
    );
  }
}

class AuthLabel extends StatelessWidget {
  final String text;
  const AuthLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      );
}

class OrDivider extends StatelessWidget {
  const OrDivider({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Row(children: [
          Expanded(child: Divider()),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('OR',
                style: TextStyle(color: Colors.black45, fontSize: 12)),
          ),
          Expanded(child: Divider()),
        ]),
      );
}

/// Same height/shape as the blue buttons, outlined in white.
class AuthOutlinedButton extends StatelessWidget {
  final Widget leading;
  final String label;
  final VoidCallback? onPressed;
  final Key? buttonKey;

  /// Placeholder look: muted text + a "Coming soon" tag.
  final bool unavailable;

  const AuthOutlinedButton({
    super.key,
    required this.leading,
    required this.label,
    required this.onPressed,
    this.buttonKey,
    this.unavailable = false,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 50,
        child: OutlinedButton(
          key: buttonKey,
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            backgroundColor: unavailable ? Colors.grey.shade50 : Colors.white,
            foregroundColor: unavailable ? Colors.black45 : Colors.black87,
            side: BorderSide(color: Colors.grey.shade300),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Opacity(opacity: unavailable ? 0.5 : 1, child: leading),
              const SizedBox(width: 10),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              if (unavailable) ...[
                const SizedBox(width: 8),
                const SoonTag(),
              ],
            ],
          ),
        ),
      );
}

/// Small grey "Coming soon" tag for controls that don't work yet.
class SoonTag extends StatelessWidget {
  const SoonTag({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text('Coming soon',
            style: TextStyle(
                fontSize: 10.5,
                color: Colors.black54,
                fontWeight: FontWeight.w600)),
      );
}

/// "Continue with Google" — NOT available yet (UI placeholder, clearly
/// marked; tapping only explains it).
class GoogleButton extends StatelessWidget {
  const GoogleButton({super.key});

  static const comingSoonMessage =
      'Google sign-in isn\'t available yet. Please use your phone number or email.';

  @override
  Widget build(BuildContext context) => AuthOutlinedButton(
        buttonKey: const ValueKey('google-button'),
        leading: const _GoogleG(),
        label: 'Continue with Google',
        unavailable: true,
        onPressed: () => ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text(comingSoonMessage))),
      );
}

/// Google-coloured "G" drawn with text — no image asset or dependency.
class _GoogleG extends StatelessWidget {
  const _GoogleG();

  @override
  Widget build(BuildContext context) => ShaderMask(
        shaderCallback: (r) => const SweepGradient(colors: [
          Color(0xFF4285F4),
          Color(0xFF34A853),
          Color(0xFFFBBC05),
          Color(0xFFEA4335),
          Color(0xFF4285F4),
        ]).createShader(r),
        child: const Text('G',
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Colors.white)),
      );
}

/// A live check row under the password fields.
class PasswordRule extends StatelessWidget {
  final String text;
  final bool ok;
  const PasswordRule({super.key, required this.text, required this.ok});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(children: [
          Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16, color: ok ? Colors.green : Colors.black38),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12.5,
                    color: ok ? Colors.green.shade700 : Colors.black54)),
          ),
        ]),
      );
}
