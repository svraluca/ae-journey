import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../data/procedure_repository.dart';
import 'post_auth_stamp_splash.dart';
import 'procedure_selection_theme.dart';
import 'signup_screen.dart';
import 'soft_auth_swap_route.dart';
import '../services/auth_service.dart';
import '../services/session_prefs.dart';
import 'widgets/notification_permission_sheet.dart';
import 'widgets/step1_background.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _obscure = true;
  bool _loading = false;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_loading) return;

    final email = _email.text.trim();
    final pass = _pass.text;
    if (email.isEmpty || pass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter email and password.')),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      await SessionPrefs.setKeepSignedIn(true);
      await AuthService().signInWithEmail(email: email, password: pass);
      if (!mounted) return;
      await NotificationPermissionSheet.promptAfterAuthIfNeeded(context);
      if (!mounted) return;
      openHomeWithStampSplash(context, widget.repo);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sign in failed: ${_friendlyAuthErrorCode(e.code)}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sign in failed. ${e.toString()}')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmThenSignInWithGoogle() async {
    if (!mounted || _loading) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Google Sign-In',
          style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700,
            color: ProcedureSelectionTheme.ink,
          ),
        ),
        content: Text(
          'A browser will open for Google. If nothing loads on the simulator, cancel and use email/password. On a real device it usually works.',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            color: ProcedureSelectionTheme.muted,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: GoogleFonts.plusJakartaSans(color: ProcedureSelectionTheme.muted),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: ProcedureSelectionTheme.buttonPrimary,
              foregroundColor: Colors.white,
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (go == true && mounted) _signInWithGoogle();
  }

  Future<void> _signInWithGoogle() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await SessionPrefs.setKeepSignedIn(true);
      await AuthService().signInWithGoogle();
      if (!mounted) return;
      await NotificationPermissionSheet.promptAfterAuthIfNeeded(context);
      if (!mounted) return;
      openHomeWithStampSplash(context, widget.repo);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Google sign in failed')),
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return;
      if (!mounted) return;
      final desc = e.description ?? '';
      final msg = AuthService.isLikelySimulatorGoogleError(desc)
          ? 'Google Sign-In often fails on the iOS Simulator. Try a device or email sign-in.'
          : (desc.isNotEmpty ? desc : 'Google sign in failed');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } on PlatformException catch (e) {
      if (!mounted) return;
      final msg = e.code == 'channel-error'
          ? 'Google Sign-In needs a full app restart after adding the plugin.'
          : (e.message ?? e.toString());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      final msg = AuthService.isLikelySimulatorGoogleError(e.toString())
          ? 'Google Sign-In often fails on the simulator. Try a device or email sign-in.'
          : e.toString();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyAuthErrorCode(String code) {
    switch (code) {
      case 'user-not-found':
        return 'No account found for that email.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'Wrong email or password.';
      case 'invalid-email':
        return 'That email looks invalid.';
      case 'operation-not-allowed':
        return 'Email/password sign-in is not enabled in Firebase.';
      case 'network-request-failed':
        return 'Check your internet connection.';
      case 'too-many-requests':
        return 'Too many attempts. Try again later.';
      default:
        return code;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ProcedureSelectionTheme.pageBackground,
      body: Stack(
        children: [
          const Step1Background(),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.chevron_left_rounded, size: 28),
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    children: [
                      Text(
                        'Sign in with email',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: ProcedureSelectionTheme.ink,
                          letterSpacing: -0.5,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Enter your email and password',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: ProcedureSelectionTheme.muted,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 36),
                      _UnderlineField(
                        hint: 'E-mail',
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        showClear: true,
                      ),
                      const SizedBox(height: 20),
                      _UnderlineField(
                        hint: 'Password',
                        controller: _pass,
                        obscureText: _obscure,
                        trailing: IconButton(
                          onPressed: () => setState(() => _obscure = !_obscure),
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                            color: ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {},
                          style: TextButton.styleFrom(
                            foregroundColor: ProcedureSelectionTheme.ink,
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            'Forgot password?',
                            style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      _PrimaryAuthButton(
                        loading: _loading,
                        label: 'Sign In',
                        onTap: _login,
                      ),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          const Expanded(child: Divider(color: Color(0xFFE4E4E8))),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              'or continue with',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: ProcedureSelectionTheme.muted,
                              ),
                            ),
                          ),
                          const Expanded(child: Divider(color: Color(0xFFE4E4E8))),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: _SocialButton(
                              label: 'Google',
                              icon: Icons.g_mobiledata_rounded,
                              onTap: () {
                                if (!_loading) _confirmThenSignInWithGoogle();
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _SocialButton(
                              label: 'Apple',
                              icon: Icons.apple,
                              onTap: () {},
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      Center(
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              "Don't have an account? ",
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13,
                                color: ProcedureSelectionTheme.muted,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            InkWell(
                              onTap: () {
                                Navigator.of(context).pushReplacement(
                                  SoftAuthSwapRoute<void>(
                                    page: SignUpScreen(repo: widget.repo),
                                    forward: true,
                                  ),
                                );
                              },
                              child: Text(
                                'Sign up',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 13,
                                  color: ProcedureSelectionTheme.ink,
                                  fontWeight: FontWeight.w700,
                                  decoration: TextDecoration.underline,
                                  decorationColor:
                                      ProcedureSelectionTheme.ink.withValues(alpha: 0.35),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Text.rich(
                    TextSpan(
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 11,
                        height: 1.5,
                        color: ProcedureSelectionTheme.muted,
                      ),
                      children: [
                        const TextSpan(text: 'By continuing, you agree to our '),
                        TextSpan(
                          text: 'Privacy Policy',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: ProcedureSelectionTheme.ink.withValues(alpha: 0.7),
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        const TextSpan(text: ' and '),
                        TextSpan(
                          text: 'Terms of Service',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: ProcedureSelectionTheme.ink.withValues(alpha: 0.7),
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        const TextSpan(text: '.'),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryAuthButton extends StatelessWidget {
  const _PrimaryAuthButton({
    required this.loading,
    required this.label,
    required this.onTap,
  });

  final bool loading;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ProcedureSelectionTheme.buttonPrimary,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: loading ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 22),
          child: Center(
            child: loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(
                    label,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1.0,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE4E4E8)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: ProcedureSelectionTheme.ink),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnderlineField extends StatefulWidget {
  const _UnderlineField({
    required this.hint,
    required this.controller,
    this.keyboardType,
    this.obscureText = false,
    this.showClear = false,
    this.trailing,
  });

  final String hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool obscureText;
  final bool showClear;
  final Widget? trailing;

  @override
  State<_UnderlineField> createState() => _UnderlineFieldState();
}

class _UnderlineFieldState extends State<_UnderlineField> {
  late final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    widget.controller.addListener(_onText);
  }

  void _onText() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final hasText = widget.controller.text.isNotEmpty;

    Widget? suffix;
    if (widget.trailing != null) {
      suffix = widget.trailing;
    } else if (widget.showClear && hasText) {
      suffix = IconButton(
        onPressed: () => widget.controller.clear(),
        visualDensity: VisualDensity.compact,
        icon: Icon(
          Icons.cancel_rounded,
          size: 18,
          color: ProcedureSelectionTheme.muted.withValues(alpha: 0.7),
        ),
      );
    }

    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      keyboardType: widget.keyboardType,
      obscureText: widget.obscureText,
      style: GoogleFonts.plusJakartaSans(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: ProcedureSelectionTheme.ink,
      ),
      cursorColor: ProcedureSelectionTheme.ink,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        hintStyle: GoogleFonts.plusJakartaSans(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: ProcedureSelectionTheme.muted.withValues(alpha: 0.75),
        ),
        contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
        suffixIcon: suffix,
        suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        border: UnderlineInputBorder(
          borderSide: BorderSide(
            color: focused ? ProcedureSelectionTheme.ink : const Color(0xFFD0D0D6),
            width: focused ? 1.4 : 1,
          ),
        ),
        enabledBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Color(0xFFD0D0D6), width: 1),
        ),
        focusedBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: ProcedureSelectionTheme.ink, width: 1.4),
        ),
      ),
    );
  }
}
