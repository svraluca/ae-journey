import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_clinic_identity.dart';

/// A Tirana peel search rejected most of the city's aesthetic clinics as
/// `wrong_business_type`, because the clinic-name vocabulary only knew the
/// Latin spellings: `clinic`, `estetic`, `dermat`. Albanian writes `klinika`,
/// `estetike` and `dermo` — none of which contain those substrings.
void main() {
  group('Albanian clinic names are recognised', () {
    const rejectedInTheWild = [
      'Klinika Estetike Dermolife - Kirurgjia Italiane',
      'Klinika Vivia - Klinikë Dermo Estetike',
      'Klinika Dermaplus',
      'Klinikë Mjekësie Estetike & Dermo-Estetikë ne Tirane',
    ];

    for (final name in rejectedInTheWild) {
      test('"$name" is a clinic', () {
        expect(placesNameLooksLikeMedicalClinic(name), isTrue);
      });
    }
  });

  group('the same gap in other markets', () {
    const names = [
      'Klinik Dr. Müller', // German
      'Estetik Klinik İstanbul', // Turkish
      'Klinika Kozmetik Warszawa', // Polish
      'Клиника Эстетики', // Russian
      'Κλινική Αισθητικής', // Greek
      'Cerrahi Estetik Merkezi', // Turkish surgery
    ];
    for (final name in names) {
      test('"$name" is a clinic', () {
        expect(placesNameLooksLikeMedicalClinic(name), isTrue);
      });
    }
  });

  group('established recognition is unchanged', () {
    const clinics = [
      'Concept Clinic',
      'Clinica Estetica Bucuresti',
      'Clinique Chirurgie Plastique',
      'Harley Street Aesthetic Clinic',
      'Dubai Cosmetic Surgery',
      'Dr. Smith Dermatology',
      'Perla Skin Clinic',
    ];
    for (final name in clinics) {
      test('"$name" is still a clinic', () {
        expect(placesNameLooksLikeMedicalClinic(name), isTrue);
      });
    }
  });

  group('non-clinics are still rejected', () {
    const notClinics = [
      'Bar Tirana',
      'Hotel Plaza',
      'Supermarket Conad',
      'Studio Unghii Bella',
      'Frizer Salon',
      'Barber Shop Tirana',
    ];
    for (final name in notClinics) {
      test('"$name" is not a clinic', () {
        expect(placesNameLooksLikeMedicalClinic(name), isFalse);
      });
    }
  });
}
