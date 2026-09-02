// ─────────────────────────────────────────────
// presentation/screens/auth/signup_screen.dart
//
// Sign Up: the BASICS ONLY — name, phone, email.
// Everything else (city, photo, provider profile…) is
// completed later from the You/Profile screen.
// Success → session saved → Home.
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api/auth_api.dart';
import '../../../core/theme/app_theme.dart';
import '../../../main.dart';

class SignupScreen extends StatefulWidget {
  /// Optional: prefill from the login screen
  /// (phone → phone field, email → email field).
  final String? prefillIdentifier;

  const SignupScreen({super.key, this.prefillIdentifier});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  bool _loading = false;
  String? _serverError;

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
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    setState(() => _serverError = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    final res = await AuthApi.signup(
      name: _nameCtrl.text.trim(),
      phone: _phoneCtrl.text.trim(),
      email: _emailCtrl.text.trim(),
      password: _passwordCtrl.text,
    );
    if (!mounted) return;
    setState(() => _loading = false);

    if (res.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Welcome to GMS! 🎉')),
      );
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const GMSMainPage()),
        (route) => false,
      );
    } else if (res.isOffline) {
      setState(() => _serverError =
          'Unable to connect. Please check your connection and try again.');
    } else {
      setState(() => _serverError = res.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.black87,
        elevation: 0,
        title: const Text('Create Account',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Just the basics 🚀',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text(
                  'You can complete the rest of your profile anytime from the You tab.',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                const SizedBox(height: 26),

                _label('Full name'),
                TextFormField(
                  controller: _nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z\s.]')),
                  ],
                  decoration: const InputDecoration(
                    hintText: 'e.g. Priya Raman',
                    prefixIcon: Icon(Icons.badge_outlined,
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

                _label('Phone number'),
                TextFormField(
                  controller: _phoneCtrl,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(15),
                  ],
                  decoration: const InputDecoration(
                    hintText: '98765 43210',
                    prefixIcon:
                        Icon(Icons.phone_outlined, color: AppTheme.primaryBlue),
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

                _label('Email'),
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _signUp(),
                  decoration: const InputDecoration(
                    hintText: 'you@email.com',
                    prefixIcon:
                        Icon(Icons.mail_outline, color: AppTheme.primaryBlue),
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
                const SizedBox(height: 18),

                _label('Password'),
                TextFormField(
                  controller: _passwordCtrl,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    hintText: 'At least 4 characters',
                    prefixIcon: const Icon(Icons.lock_outline,
                        color: AppTheme.primaryBlue),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: Colors.black45,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (v) {
                    if ((v ?? '').length < 4) {
                      return 'Password must be at least 4 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 18),

                _label('Confirm password'),
                TextFormField(
                  controller: _confirmPasswordCtrl,
                  obscureText: _obscureConfirm,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _signUp(),
                  decoration: InputDecoration(
                    hintText: 'Re-enter your password',
                    prefixIcon: const Icon(Icons.lock_outline,
                        color: AppTheme.primaryBlue),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirm
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: Colors.black45,
                      ),
                      onPressed: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                  validator: (v) {
                    if (v != _passwordCtrl.text) {
                      return 'Passwords do not match';
                    }
                    return null;
                  },
                ),

                if (_serverError != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_serverError!,
                        style: TextStyle(
                            color: Colors.red.shade700, fontSize: 13)),
                  ),
                ],

                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _signUp,
                    child: _loading
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.white))
                        : const Text('Create Account',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),

                const SizedBox(height: 16),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Already have an account?  Sign In',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
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
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      );
}
