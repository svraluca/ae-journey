/// Google Maps JSON style aligned with [ProcedureSelectionTheme] /
/// procedure-form warm glass — soft pearl land, muted water, quiet labels.
abstract final class GlowMapStyle {
  /// Light, desaturated map that sits behind VisionOS-style glass chrome.
  static const json = '''
[
  {
    "elementType": "geometry",
    "stylers": [{ "color": "#F2F2F2" }]
  },
  {
    "elementType": "labels.icon",
    "stylers": [{ "visibility": "off" }]
  },
  {
    "elementType": "labels.text.fill",
    "stylers": [{ "color": "#8A8A93" }]
  },
  {
    "elementType": "labels.text.stroke",
    "stylers": [{ "color": "#F8F8FA" }, { "weight": 3 }]
  },
  {
    "featureType": "administrative",
    "elementType": "geometry.stroke",
    "stylers": [{ "color": "#D8D8DE" }, { "weight": 0.6 }]
  },
  {
    "featureType": "administrative.land_parcel",
    "stylers": [{ "visibility": "off" }]
  },
  {
    "featureType": "administrative.neighborhood",
    "elementType": "labels",
    "stylers": [{ "visibility": "simplified" }]
  },
  {
    "featureType": "landscape.man_made",
    "elementType": "geometry.fill",
    "stylers": [{ "color": "#EEEEF1" }]
  },
  {
    "featureType": "landscape.natural",
    "elementType": "geometry.fill",
    "stylers": [{ "color": "#EDEDED" }]
  },
  {
    "featureType": "poi",
    "stylers": [{ "visibility": "off" }]
  },
  {
    "featureType": "poi.park",
    "elementType": "geometry.fill",
    "stylers": [{ "visibility": "on" }, { "color": "#E4E8E3" }]
  },
  {
    "featureType": "poi.park",
    "elementType": "labels",
    "stylers": [{ "visibility": "off" }]
  },
  {
    "featureType": "road",
    "elementType": "geometry.fill",
    "stylers": [{ "color": "#FFFFFF" }]
  },
  {
    "featureType": "road",
    "elementType": "geometry.stroke",
    "stylers": [{ "color": "#E4E4EA" }, { "weight": 0.8 }]
  },
  {
    "featureType": "road",
    "elementType": "labels.icon",
    "stylers": [{ "visibility": "off" }]
  },
  {
    "featureType": "road.arterial",
    "elementType": "geometry.fill",
    "stylers": [{ "color": "#F8F8FA" }]
  },
  {
    "featureType": "road.highway",
    "elementType": "geometry.fill",
    "stylers": [{ "color": "#EAE6E5" }]
  },
  {
    "featureType": "road.highway",
    "elementType": "geometry.stroke",
    "stylers": [{ "color": "#D8D4D3" }, { "weight": 0.8 }]
  },
  {
    "featureType": "road.highway",
    "elementType": "labels",
    "stylers": [{ "visibility": "off" }]
  },
  {
    "featureType": "road.local",
    "elementType": "labels",
    "stylers": [{ "visibility": "simplified" }]
  },
  {
    "featureType": "transit",
    "stylers": [{ "visibility": "off" }]
  },
  {
    "featureType": "water",
    "elementType": "geometry.fill",
    "stylers": [{ "color": "#D5DCE6" }]
  },
  {
    "featureType": "water",
    "elementType": "labels.text.fill",
    "stylers": [{ "color": "#9AA3B0" }]
  },
  {
    "featureType": "water",
    "elementType": "labels.text.stroke",
    "stylers": [{ "color": "#EEF2F6" }]
  }
]
''';
}
