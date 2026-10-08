"""Public-page failures distilled to small, network-free regressions."""
import unittest

from price_fixtures import e


def accepted(body, procedure='botox', url='https://aster.example/precios/'):
    html = '<html><title>Aster Clinic</title>' + body + '<footer>Valencia</footer></html>'
    return [row for row in e.extract_price_evidence(html, url, procedure)
            if e.validate_evidence(row, e.page_text(html), html, 'Valencia')[0]]


class PriceBinding(unittest.TestCase):
    def test_treatment_page_without_a_fee_cannot_supply_a_price(self):
        # Representative offline page, not a fetch or current-site assertion.
        rows = accepted('<h1>Botox en Valencia</h1>'
                        '<p>Toxina botulínica para las arrugas faciales.</p>'
                        '<p>Valoración 4.9 de 5, 230 reseñas.</p>'
                        '<p>Teléfono +34 963 456 789. Solicita una valoración.</p>',
                        url='https://clinicadraolmo.com/botox-en-valencia/')
        self.assertFalse(rows)

    def test_market_average_is_not_owned_even_on_a_price_menu(self):
        for sentence in ['El precio promedio de un aumento de labios entre los 200 € y 400 €.',
                         'Botox: el promedio es de $400 por tratamiento. Reserva ahora.',
                         'El precio medio de Botox es 240 € en distintas clínicas.']:
            procedure = 'filler' if 'labios' in sentence else 'botox'
            self.assertFalse(accepted('<p>'+sentence+'</p>', procedure))

    def test_redeemable_appointment_does_not_replace_treatment(self):
        rows = accepted('<p>Botox and fillers. Aesthetic Medicine Appointment '
                        '70€ (redeemable against any of the treatments)</p>'
                        '<h2>Hyaluronic acid dermal Fillers</h2>'
                        '<ul><li>Lip enhancement, definition and volume 300€ (1 vial)</li></ul>', 'filler')
        self.assertTrue(rows)
        self.assertEqual({v.price_min for v in rows}, {300})

    def test_long_heading_and_wrapped_price_beat_faq_average(self):
        body = ('<ul><li>Botox: el promedio es de $400 por tratamiento.</li></ul>'
                '<div><h2>Botox, el precio del tratamiento: ¿Cuanto cuesta un '
                'tratamiento con Toxina Botulínica tipo A?</h2></div>'
                '<div><h3>Desde 300 €</h3></div>')
        rows = accepted(body, url='https://aster.example/medicina-estetica/facial/botox/')
        self.assertTrue(rows)
        self.assertEqual({(v.price_min, v.currency, v.qualifier) for v in rows}, {(300, 'EUR', 'from')})

    def test_booksy_services_never_share_price_or_duration(self):
        body = ''.join('<div data-testid="services-list-item-root">'
                       '<h4 data-testid="service-name">'+name+'</h4>'
                       '<span data-testid="service-variant-price">'+price+'</span>'
                       '<span data-testid="service-variant-duration">30min</span></div>'
                       for name, price in [('Botox 3 zonas', '230,00 €+'), ('Aumento labial', '260,00 €+')])
        url = 'https://booksy.com/es-es/110260_aster-clinic_medicina-estetica_58087_valencia'
        for proc, amount in [('botox', 230), ('filler', 260)]:
            rows = accepted(body, proc, url)
            self.assertTrue(rows)
            self.assertEqual({(v.price_min, v.qualifier) for v in rows}, {(amount, 'from')})

    def test_couples_and_month_only_offer_need_confirmation(self):
        self.assertFalse(accepted('<p>Toxina botulínica en pareja: 200 € por persona</p>'))
        self.assertFalse(accepted('<h2>Promoción Botox febrero</h2>'
                                  '<ul><li>Toxina botulínica (3 zonas): 250 €</li></ul>'))
        self.assertTrue(accepted('<h2>Botox</h2><p>Botox 3 zonas 250€</p>'))

    def test_directory_brand_is_recognized_across_country_domains(self):
        for host in ['injectablesbooking.es', 'injectablesbooking.it', 'injectablesbooking.nl',
                     'www.injectablesbooking.com', 'es.injectablesbooking.com']:
            self.assertEqual(e.classify_source('https://'+host+'/botox/valencia'), 'directory')
        self.assertEqual(e.classify_source('https://injectablesbooking.example-clinic.com/'), 'official_clinic')

    def test_spanish_price_headlines_do_not_become_treatment_names(self):
        for title in ['Precio aumento de labios', 'Aumento de labios: precio desde',
                      'el precio promedio de un aumento de labios entre los']:
            shown = e.published_procedure_display_name('filler', title, title+' 250€', '250€')
            self.assertNotIn('precio', shown.lower())
            self.assertNotIn('promedio', shown.lower())

    def test_surgery_market_guide_and_implant_component_are_rejected(self):
        self.assertFalse(accepted('<h2>Precios orientativos</h2>'
            '<p>Rinoplastia parcial 1800–3500 €</p>', 'rhinoplasty'))
        self.assertFalse(accepted('<h3>Precio orientativo de una rinoplastia primaria: 4.500 € – 6.500 €</h3>'
            '<p>Rango habitual en clínicas privadas.</p>', 'rhinoplasty'))
        self.assertFalse(accepted('<p>En clínicas low cost, aumento de pecho desde 3000 €.</p>',
                                  'breast_augmentation'))
        self.assertFalse(accepted('<p>¿Cuánto cuestan los implantes mamarios? '
                                  'Precio por par de implantes 600–2000 €</p>', 'breast_augmentation'))

    def test_owned_mamoplasty_heading_binds_its_starting_fee(self):
        rows = accepted('<h2>¿Cuánto cuesta una operación de mamoplastia de aumento?</h2>'
                        '<h3>Desde 5300 €</h3>', 'breast_augmentation')
        self.assertEqual({(r.price_min, r.qualifier) for r in rows}, {(5300, 'from')})
        self.assertEqual(e.breast_augmentation_detail('Aumento de pecho con grasa propia 5500 €'),
                         'Fat transfer')

    def test_branch_price_and_spanish_range_are_kept_together(self):
        text = 'Precio del injerto capilar en Oviedo | Nuestro trasplante capilar en Oviedo tiene un precio de entre 3090€ u 3690€.'
        self.assertTrue(e.foreign_quoted_price_city(text, 'Valencia'))
        self.assertFalse(e.foreign_quoted_price_city(text.replace('Oviedo', 'Valencia'), 'Valencia'))
        match, _, currency = next(e.iter_exact_price_matches(text))
        self.assertEqual(e.find_attached_range(text, currency, match), (3090, 3690))
        self.assertIn('3690', e.priced_line_text(text, match=match))


if __name__ == '__main__':
    unittest.main()
