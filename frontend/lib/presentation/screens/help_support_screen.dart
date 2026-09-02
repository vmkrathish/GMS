// ─────────────────────────────────────────────
// presentation/screens/help_support_screen.dart
//
// Lets someone send a real question or issue without leaving the
// app to go find an email address — fills out a short form here,
// then opens their own mail app with everything pre-filled,
// addressed to CompanyInfo.supportEmail. No backend email-sending
// service exists yet (see README's known limitations), so this is
// the honest, reliable v1: it always works, on every platform,
// with zero new backend infrastructure. If in-app submission
// without leaving the app is wanted later, this is the one place
// to swap for a real API call.
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/company_info.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/session_manager.dart';

class HelpSupportScreen extends StatefulWidget {
  const HelpSupportScreen({super.key});

  @override
  State<HelpSupportScreen> createState() => _HelpSupportScreenState();
}

class _HelpSupportScreenState extends State<HelpSupportScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _prefillName();
  }

  Future<void> _prefillName() async {
    final user = await SessionManager.getUser();
    final name = user?['name']?.toString() ?? '';
    if (name.isNotEmpty && mounted) {
      setState(() => _nameCtrl.text = name);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _subjectCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendQuery() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _sending = true);

    final subject = Uri.encodeComponent(
        'GMS Support: ${_subjectCtrl.text.trim()}');
    final body = Uri.encodeComponent(
        'From: ${_nameCtrl.text.trim()}\n\n${_messageCtrl.text.trim()}');
    final uri = Uri.parse(
        'mailto:${CompanyInfo.supportEmail}?subject=$subject&body=$body');

    bool opened = false;
    try {
      opened = await launchUrl(uri);
    } catch (_) {
      opened = false;
    }

    if (!mounted) return;
    setState(() => _sending = false);

    if (opened) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Opening your mail app to send this query…')));
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Could not open a mail app — please email us directly at ${CompanyInfo.supportEmail}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help & Support')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "We'll get back to you soon 👋",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                const Text(
                  "Got a question, ran into an issue, or have feedback? "
                  "Send it here — it'll go straight to our support team.",
                  style: TextStyle(fontSize: 14, color: Colors.black54),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Your name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Enter your name' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _subjectCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Subject',
                    hintText: 'What is this about?',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Enter a subject' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _messageCtrl,
                  minLines: 5,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Your message',
                    hintText: 'Tell us what\'s going on…',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  validator: (v) => (v ?? '').trim().length < 5
                      ? 'Please add a few more details'
                      : null,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _sending ? null : _sendQuery,
                    icon: _sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send_rounded),
                    label: Text(_sending ? 'Opening mail app…' : 'Send Query'),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
                const SizedBox(height: 28),
                const Divider(),
                const SizedBox(height: 16),
                const Text('Or reach us directly',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                _contactRow(Icons.email_outlined, CompanyInfo.supportEmail),
                const SizedBox(height: 8),
                _contactRow(Icons.phone_outlined, CompanyInfo.supportPhone),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _contactRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.primaryBlue),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontSize: 14)),
      ],
    );
  }
}
