// ─────────────────────────────────────────────
// presentation/screens/auth/signup_screen.dart
//
// Sign Up, in three steps (matches the GMS onboarding reference):
//   1. SignupScreen          — "Create an account": Continue with Google
//                              (UI only for now) · Sign up with Email ·
//                              "Already have an account? Sign In"
//   2. SignupDetailsScreen   — the BASICS ONLY: full name, phone, email → Next
//   3. SignupPasswordScreen  — password + confirm (show/hide, live checks)
//                              → Create Account
// Step 3 calls the SAME AuthApi.signup as before (name, phone, email,
// password); success → session saved → Home. Everything else (city,
// photo, provider profile…) is completed later from the You tab.
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api/auth_api.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/request_outcome.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/connection_error_banner.dart';
import '../../../main.dart';
import 'auth_widgets.dart';

// ── Step 1: choose how to sign up ─────────────────────────────────────
class SignupScreen extends StatefulWidget {
  /// Optional: prefill from the login screen
  /// (phone → phone field, email → email field).
  final String? prefillIdentifier;

  const SignupScreen({super.key, this.prefillIdentifier});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  @override
  void initState() {
    super.initState();
    ApiService.warmUp();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(children: [
            const AuthHeader(showBack: true),
            AuthBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                    Text('Create an account',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold)),
                    Icon(Icons.person_add_alt_1_outlined,
                        color: AppTheme.primaryBlue),
                  ]),
                  const SizedBox(height: 6),
                  const Text('Get started with GMS in a few steps',
                      style: TextStyle(color: Colors.black54)),
                  const SizedBox(height: 28),
                  const GoogleButton(),
                  const SizedBox(height: 14),
                  AuthOutlinedButton(
                    buttonKey: const ValueKey('signup-email-button'),
                    leading: const Icon(Icons.mail_outline,
                        color: AppTheme.primaryBlue),
                    label: 'Sign up with Email',
                    onPressed: () => Navigator.of(context).push(authRoute(
                        SignupDetailsScreen(
                            prefillIdentifier: widget.prefillIdentifier))),
                  ),
                  const OrDivider(),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('Already have an account?',
                          style: TextStyle(color: Colors.black54)),
                      TextButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('Sign In',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Center(
                    child: Text(
                      'By continuing you agree to GMS Terms & Privacy Policy',
                      style: TextStyle(fontSize: 11, color: Colors.black38),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Step 2: basic details ─────────────────────────────────────────────
class SignupDetailsScreen extends StatefulWidget {
  final String? prefillIdentifier;
  const SignupDetailsScreen({super.key, this.prefillIdentifier});

  @override
  State<SignupDetailsScreen> createState() => _SignupDetailsScreenState();
}

class _SignupDetailsScreenState extends State<SignupDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final p = widget.prefillIdentifier?.trim() ?? '';
    if (p.isNotEmpty) {
      if (p.contains('@')) {
        _emailCtrl.text = p;
      } else {
        _phoneCtrl.text = p.replaceAll(RegExp(r'[\s-]'), '');
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  void _next() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).push(authRoute(SignupPasswordScreen(
      name: _nameCtrl.text.trim(),
      phone: _phoneCtrl.text.trim(),
      email: _emailCtrl.text.trim(),
    )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(children: [
            const AuthHeader(showBack: true, compact: true),
            AuthBody(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Just the basics 🚀',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    const Text(
                      'You can complete the rest of your profile anytime from the You tab.',
                      style: TextStyle(color: Colors.black54, fontSize: 13),
                    ),
                    const SizedBox(height: 26),
                    const AuthLabel('Full name'),
                    TextFormField(
                      key: const ValueKey('signup-name'),
                      controller: _nameCtrl,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[a-zA-Z\s.]')),
                      ],
                      decoration: const InputDecoration(
                        hintText: 'e.g. Priya Raman',
                        prefixIcon: Icon(Icons.person_outline,
                            color: AppTheme.primaryBlue),
                      ),
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.length < 2) return 'Enter your name';
                        if (!RegExp(r'^[a-zA-Z\s.]+$').hasMatch(t)) {
                          return 'Name should contain letters only';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 18),
                    const AuthLabel('Phone number'),
                    TextFormField(
                      key: const ValueKey('signup-phone'),
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(15),
                      ],
                      decoration: const InputDecoration(
                        hintText: '98765 43210',
                        prefixIcon: Icon(Icons.phone_outlined,
                            color: AppTheme.primaryBlue),
                      ),
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (!RegExp(r'^[0-9]{10,15}$').hasMatch(t)) {
                          return 'Enter a valid phone number';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 18),
                    const AuthLabel('Email'),
                    TextFormField(
                      key: const ValueKey('signup-email'),
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _next(),
                      decoration: const InputDecoration(
                        hintText: 'you@email.com',
                        prefixIcon: Icon(Icons.mail_outline,
                            color: AppTheme.primaryBlue),
                      ),
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Enter your email';
                        if (!RegExp(
                                r'^[a-zA-Z0-9.\_%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$')
                            .hasMatch(t)) {
                          return 'Enter a valid email address (e.g. name@example.com)';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        key: const ValueKey('signup-next'),
                        onPressed: _next,
                        child: const Text('Next',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Step 3: password → Create Account ─────────────────────────────────
class SignupPasswordScreen extends StatefulWidget {
  final String name;
  final String phone;
  final String email;

  const SignupPasswordScreen({
    super.key,
    required this.name,
    required this.phone,
    required this.email,
  });

  @override
  State<SignupPasswordScreen> createState() => _SignupPasswordScreenState();
}

class _SignupPasswordScreenState extends State<SignupPasswordScreen> {
  static const int minLength = 4; // unchanged rule

  final _formKey = GlobalKey<FormState>();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  bool _loading = false;
  String? _serverError;
  bool _canRetry = false; // connection / timeout / server error only

  @override
  void initState() {
    super.initState();
    // Live rule ticks.
    _passwordCtrl.addListener(() => setState(() {}));
    _confirmCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_loading) return;
    setState(() {
      _serverError = null;
      _canRetry = false;
    });
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    final res = await AuthApi.signup(
      name: widget.name,
      phone: widget.phone,
      email: widget.email,
      password: _passwordCtrl.text,
    );
    if (!mounted) return;
    setState(() => _loading = false);

    if (res.success) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const GMSMainPage()),
        (route) => false,
      );
    } else {
      final problem = res.problem;
      setState(() {
        _canRetry = RequestOutcome.isRetryable(problem);
        _serverError =
            RequestOutcome.message(problem, serverMessage: res.message);
      });
      if (_canRetry) ApiService.warmUp();
    }
  }

  Widget _visibility(bool obscure, VoidCallback toggle) => IconButton(
        tooltip: obscure ? 'Show password' : 'Hide password',
        icon: Icon(
          obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          color: Colors.black45,
        ),
        onPressed: toggle,
      );

  @override
  Widget build(BuildContext context) {
    final longEnough = _passwordCtrl.text.length >= minLength;
    final matches =
        _passwordCtrl.text.isNotEmpty && _passwordCtrl.text == _confirmCtrl.text;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(children: [
            const AuthHeader(showBack: true, compact: true),
            AuthBody(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('Create Password',
                              style: TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.bold)),
                          Icon(Icons.lock_outline, color: AppTheme.primaryBlue),
                        ]),
                    const SizedBox(height: 6),
                    const Text('Set a secure password for your account.',
                        style: TextStyle(color: Colors.black54, fontSize: 13)),
                    const SizedBox(height: 26),
                    const AuthLabel('Password'),
                    TextFormField(
                      key: const ValueKey('signup-password'),
                      controller: _passwordCtrl,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        hintText: 'At least $minLength characters',
                        prefixIcon: const Icon(Icons.lock_outline,
                            color: AppTheme.primaryBlue),
                        suffixIcon: _visibility(_obscurePassword,
                            () => setState(() => _obscurePassword = !_obscurePassword)),
                      ),
                      validator: (v) => (v ?? '').length < minLength
                          ? 'Password must be at least $minLength characters'
                          : null,
                    ),
                    const SizedBox(height: 18),
                    const AuthLabel('Confirm password'),
                    TextFormField(
                      key: const ValueKey('signup-confirm'),
                      controller: _confirmCtrl,
                      obscureText: _obscureConfirm,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _create(),
                      decoration: InputDecoration(
                        hintText: 'Re-enter your password',
                        prefixIcon: const Icon(Icons.lock_outline,
                            color: AppTheme.primaryBlue),
                        suffixIcon: _visibility(_obscureConfirm,
                            () => setState(() => _obscureConfirm = !_obscureConfirm)),
                      ),
                      validator: (v) =>
                          v != _passwordCtrl.text ? 'Passwords do not match' : null,
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          PasswordRule(
                              text: 'At least $minLength characters',
                              ok: longEnough),
                          PasswordRule(text: 'Passwords must match', ok: matches),
                        ],
                      ),
                    ),
                    if (_serverError != null) ...[
                      const SizedBox(height: 14),
                      ConnectionErrorBanner(
                        message: _serverError!,
                        onRetry: _canRetry && !_loading ? _create : null,
                      ),
                    ],
                    const SizedBox(height: 26),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        key: const ValueKey('signup-create'),
                        onPressed: _loading ? null : _create,
                        child: _loading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Colors.white))
                            : const Text('Create Account',
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
