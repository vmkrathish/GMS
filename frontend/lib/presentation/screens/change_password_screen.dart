// ─────────────────────────────────────────────
// presentation/screens/change_password_screen.dart
//
// Settings → Change Password. Requires the current password, a new
// password, and confirmation.
//
// The "Current password" field is checked live, debounced, as the
// person types — wrong is shown immediately under the field rather
// than waiting for the final Update button, since a wrong current
// password is the single most common reason this form fails and
// there's no reason to make someone submit the whole thing to find
// out. New password must differ from the current one and be at
// least 4 characters, matching signup's rule.
// ─────────────────────────────────────────────
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/auth_api.dart';
import '../../core/theme/app_theme.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _loading = false;
  String? _error;

  // Live current-password check state.
  Timer? _debounce;
  bool _checkingCurrent = false;
  bool? _currentIsValid; // null = not checked yet / empty field

  @override
  void initState() {
    super.initState();
    _currentCtrl.addListener(_onCurrentChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _currentCtrl.removeListener(_onCurrentChanged);
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _onCurrentChanged() {
    final value = _currentCtrl.text;
    _debounce?.cancel();
    if (value.isEmpty) {
      setState(() {
        _currentIsValid = null;
        _checkingCurrent = false;
      });
      return;
    }
    setState(() => _checkingCurrent = true);
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      final ok = await AuthApi.verifyPassword(value);
      if (!mounted || _currentCtrl.text != value) return; // stale response
      setState(() {
        _currentIsValid = ok; // null if the check itself failed (offline etc.)
        _checkingCurrent = false;
      });
    });
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;
    if (_currentIsValid == false) return; // already shown inline, don't submit

    setState(() => _loading = true);
    final res = await AuthApi.changePassword(
      currentPassword: _currentCtrl.text,
      newPassword: _newCtrl.text,
    );
    if (!mounted) return;
    setState(() => _loading = false);

    if (res.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated successfully ✅')),
      );
      Navigator.of(context).pop();
    } else {
      setState(() => _error = res.isOffline
          ? 'Unable to connect. Please check your connection and try again.'
          : res.message);
    }
  }

  Widget _passwordField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required bool obscure,
    required VoidCallback onToggle,
    required String? Function(String?) validator,
    TextInputAction action = TextInputAction.next,
    void Function(String)? onSubmitted,
    Widget? trailingStatus,
    String? liveError,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          textInputAction: action,
          onFieldSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon:
                const Icon(Icons.lock_outline, color: AppTheme.primaryBlue),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (trailingStatus != null) trailingStatus,
                IconButton(
                  icon: Icon(
                    obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    color: Colors.black45,
                  ),
                  onPressed: onToggle,
                ),
              ],
            ),
            errorText: liveError,
          ),
          validator: validator,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Live status indicator for the current-password field: a small
    // spinner while checking, a check/cross once we know.
    Widget? currentStatusIcon;
    String? currentLiveError;
    if (_checkingCurrent) {
      currentStatusIcon = const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (_currentIsValid == true) {
      currentStatusIcon =
          const Icon(Icons.check_circle, color: Colors.green, size: 20);
    } else if (_currentIsValid == false) {
      currentStatusIcon =
          const Icon(Icons.cancel, color: Colors.red, size: 20);
      currentLiveError = 'Current password is incorrect';
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Change Password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _passwordField(
                  controller: _currentCtrl,
                  label: 'Current password',
                  hint: 'Enter your current password',
                  obscure: _obscureCurrent,
                  onToggle: () =>
                      setState(() => _obscureCurrent = !_obscureCurrent),
                  trailingStatus: currentStatusIcon,
                  liveError: currentLiveError,
                  validator: (v) {
                    if ((v ?? '').isEmpty) return 'Enter your current password';
                    if (_currentIsValid == false) {
                      return 'Current password is incorrect';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 18),
                _passwordField(
                  controller: _newCtrl,
                  label: 'New password',
                  hint: 'At least 4 characters',
                  obscure: _obscureNew,
                  onToggle: () => setState(() => _obscureNew = !_obscureNew),
                  validator: (v) {
                    if ((v ?? '').length < 4) {
                      return 'Password must be at least 4 characters';
                    }
                    if (_currentCtrl.text.isNotEmpty &&
                        v == _currentCtrl.text) {
                      return 'New password must be different from your current password';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 18),
                _passwordField(
                  controller: _confirmCtrl,
                  label: 'Confirm new password',
                  hint: 'Re-enter your new password',
                  obscure: _obscureConfirm,
                  onToggle: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                  action: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  validator: (v) =>
                      v != _newCtrl.text ? 'Passwords do not match' : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_error!,
                        style: TextStyle(color: Colors.red.shade700)),
                  ),
                ],
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Update Password'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
