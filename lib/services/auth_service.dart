import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  AuthService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  User? get currentUser => _auth.currentUser;

  /// Google OAuth + Firebase credential, then merges `users/{uid}` in Firestore.
  Future<UserCredential> signInWithGoogle({
    String? displayNameOverride,
  }) async {
    // Match TeTa: initialize for each attempt (more reliable across hot restarts).
    final googleSignIn = GoogleSignIn.instance;
    await googleSignIn.initialize();
    final account = await googleSignIn.authenticate();
    final authTokens = account.authentication;
    final idToken = authTokens.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw PlatformException(code: 'missing-id-token', message: 'Google did not return an ID token.');
    }
    final oauth = GoogleAuthProvider.credential(
      idToken: idToken,
      accessToken: null,
    );
    final cred = await _auth.signInWithCredential(oauth);
    final user = cred.user;
    if (user == null) return cred;

    final isNew = cred.additionalUserInfo?.isNewUser ?? false;
    final displayName = displayNameOverride ?? account.displayName ?? user.displayName;
    await _mergeGoogleProfileIntoFirestore(user, displayName: displayName, isNew: isNew);

    return cred;
  }

  static bool isLikelySimulatorGoogleError(String message) {
    final m = message.toLowerCase();
    return m.contains('cannot parse response') ||
        m.contains('token request') ||
        m.contains('oauth2.googleapis.com') ||
        m.contains('connection error');
  }

  Future<UserCredential> signUpWithEmail({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    DateTime? dob,
  }) async {
    final cred = await _auth.createUserWithEmailAndPassword(email: email, password: password);
    final user = cred.user;
    if (user == null) return cred;

    final display = [firstName.trim(), lastName.trim()]
        .where((s) => s.isNotEmpty)
        .join(' ');
    if (display.isNotEmpty) {
      try {
        await user.updateDisplayName(display);
      } catch (_) {}
    }

    await _upsertUserDoc(
      uid: user.uid,
      email: user.email,
      firstName: firstName,
      lastName: lastName,
      dob: dob,
      isNew: true,
    );

    return cred;
  }

  Future<UserCredential> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
    final user = cred.user;
    if (user == null) return cred;

    await _upsertUserDoc(uid: user.uid, email: user.email, isNew: false);
    return cred;
  }

  Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e, st) {
      debugPrint('Google signOut: $e\n$st');
    }
    await _auth.signOut();
  }

  DocumentReference<Map<String, dynamic>> userDocRef(String uid) => _firestore.collection('users').doc(uid);

  Stream<DocumentSnapshot<Map<String, dynamic>>> userProfileStream(String uid) =>
      userDocRef(uid).snapshots();

  Future<void> _upsertUserDoc({
    required String uid,
    required String? email,
    String? firstName,
    String? lastName,
    DateTime? dob,
    required bool isNew,
  }) async {
    final ref = userDocRef(uid);

    final data = <String, dynamic>{
      'uid': uid,
      'email': email,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (isNew) {
      data['createdAt'] = FieldValue.serverTimestamp();
    }

    if (firstName != null) data['firstName'] = firstName;
    if (lastName != null) data['lastName'] = lastName;
    if (dob != null) data['dob'] = Timestamp.fromDate(DateTime(dob.year, dob.month, dob.day));

    await ref.set(data, SetOptions(merge: true));
  }

  Future<void> _mergeGoogleProfileIntoFirestore(
    User user, {
    String? displayName,
    required bool isNew,
  }) async {
    final ref = userDocRef(user.uid);
    final snap = await ref.get();
    final existing = snap.data();

    final data = <String, dynamic>{
      'uid': user.uid,
      'email': user.email,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (isNew || !snap.exists) {
      data['createdAt'] = FieldValue.serverTimestamp();
    }

    final hasFirst = _nonEmpty(existing?['firstName'] as String?);
    final hasLast = _nonEmpty(existing?['lastName'] as String?);
    final name = (displayName ?? user.displayName ?? '').trim();
    if (name.isNotEmpty && (!hasFirst || !hasLast)) {
      final parts = name.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
      if (parts.length >= 2) {
        if (!hasFirst) data['firstName'] = parts.first;
        if (!hasLast) data['lastName'] = parts.sublist(1).join(' ');
      } else if (!hasFirst && !hasLast) {
        data['firstName'] = name;
      }
    }

    final hasPhoto = _nonEmpty(existing?['photoUrl'] as String?);
    final googlePhoto = (user.photoURL ?? '').trim();
    if (!hasPhoto && googlePhoto.isNotEmpty) {
      data['photoUrl'] = googlePhoto;
    }

    await ref.set(data, SetOptions(merge: true));
  }

  /// Saves [photoUrl] on `users/{uid}` and mirrors it to Firebase Auth when possible.
  /// Also stores [photoStoragePath] when provided (Firebase Storage object path).
  Future<void> updateProfilePhotoUrl(
    String? photoUrl, {
    String? photoStoragePath,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Must be signed in to update profile photo');

    final trimmed = (photoUrl ?? '').trim();
    final value = trimmed.isEmpty ? null : trimmed;

    final data = <String, dynamic>{
      'photoUrl': value,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (value == null) {
      data['photoStoragePath'] = null;
    } else if (photoStoragePath != null && photoStoragePath.trim().isNotEmpty) {
      data['photoStoragePath'] = photoStoragePath.trim();
    }

    await userDocRef(user.uid).set(data, SetOptions(merge: true));

    try {
      await user.updatePhotoURL(value);
      await user.reload();
    } catch (e, st) {
      debugPrint('updatePhotoURL: $e\n$st');
    }
  }

  /// True when the signed-in user has an active paid plan (not free/cancelled).
  Future<bool> hasPaidSubscription() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      final snap = await userDocRef(user.uid).get();
      final data = snap.data();
      final plan =
          (data?['subscriptionPlan'] as String?)?.trim().toLowerCase() ?? '';
      final status =
          (data?['subscriptionStatus'] as String?)?.trim().toLowerCase() ?? '';
      if (status == 'cancelled' || status == 'expired') return false;
      return plan == 'monthly' || plan == 'yearly' || plan == 'lifetime';
    } catch (_) {
      return false;
    }
  }

  /// Persists a simulated / store subscription on `users/{uid}`.
  /// [plan] should be `monthly`, `yearly`, or `lifetime`.
  Future<void> setSubscriptionPlan({
    required String plan,
    required String planTitle,
    String status = 'active',
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Must be signed in to update subscription');

    final normalized = plan.trim().toLowerCase();
    await userDocRef(user.uid).set(
      {
        'subscriptionPlan': normalized,
        'subscriptionPlanTitle': planTitle.trim(),
        'subscriptionStatus': status,
        'subscribedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  /// Clears paid plan fields and returns the account to Free.
  /// Keeps `previousSubscription*` so Restore can recover the last paid plan.
  Future<void> cancelSubscription() async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Must be signed in to cancel subscription');

    final snap = await userDocRef(user.uid).get();
    final data = snap.data();
    final current = (data?['subscriptionPlan'] as String?)?.trim().toLowerCase() ?? '';
    final title = (data?['subscriptionPlanTitle'] as String?)?.trim() ?? '';

    final payload = <String, dynamic>{
      'subscriptionPlan': 'free',
      'subscriptionPlanTitle': 'Free plan',
      'subscriptionStatus': 'cancelled',
      'cancelledAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (current.isNotEmpty && current != 'free') {
      payload['previousSubscriptionPlan'] = current;
      payload['previousSubscriptionPlanTitle'] =
          title.isNotEmpty ? title : _defaultPlanTitle(current);
    }

    await userDocRef(user.uid).set(payload, SetOptions(merge: true));
  }

  /// Simulated Store restore — reactivates [previousSubscriptionPlan] when present.
  Future<RestoreSubscriptionResult> restoreSubscription() async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Must be signed in to restore subscription');

    final snap = await userDocRef(user.uid).get();
    final data = snap.data();
    final current = (data?['subscriptionPlan'] as String?)?.trim().toLowerCase() ?? '';
    if (current == 'monthly' || current == 'yearly' || current == 'lifetime') {
      return RestoreSubscriptionResult.alreadyActive(current);
    }

    final previous =
        (data?['previousSubscriptionPlan'] as String?)?.trim().toLowerCase() ?? '';
    if (previous != 'monthly' && previous != 'yearly' && previous != 'lifetime') {
      return const RestoreSubscriptionResult.none();
    }

    final title = (data?['previousSubscriptionPlanTitle'] as String?)?.trim();
    await setSubscriptionPlan(
      plan: previous,
      planTitle: (title != null && title.isNotEmpty) ? title : _defaultPlanTitle(previous),
      status: 'active',
    );
    return RestoreSubscriptionResult.restored(previous);
  }

  static String _defaultPlanTitle(String plan) => switch (plan) {
        'monthly' => 'Monthly Pro',
        'yearly' => 'Yearly Pro',
        'lifetime' => 'Lifetime Pro',
        _ => 'ÆSTHETIC JOURNEY Pro',
      };

  bool _nonEmpty(String? s) => (s ?? '').trim().isNotEmpty;
}

/// Outcome of a simulated App Store restore.
class RestoreSubscriptionResult {
  const RestoreSubscriptionResult._({this.plan, required this.kind});

  const RestoreSubscriptionResult.none() : this._(kind: RestoreSubscriptionKind.none);
  const RestoreSubscriptionResult.restored(String plan)
      : this._(plan: plan, kind: RestoreSubscriptionKind.restored);
  const RestoreSubscriptionResult.alreadyActive(String plan)
      : this._(plan: plan, kind: RestoreSubscriptionKind.alreadyActive);

  final String? plan;
  final RestoreSubscriptionKind kind;

  bool get found => kind != RestoreSubscriptionKind.none;
}

enum RestoreSubscriptionKind { none, restored, alreadyActive }

