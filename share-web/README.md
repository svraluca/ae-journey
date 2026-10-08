# ÆSTHETIC JOURNEY web

Public marketing homepage + share teaser pages.

## Live URL

https://ae-journey.com  
Share links: `https://ae-journey.com/share/<shareId>`

Legacy Hosting URL: https://ae-glowup.web.app

`/` serves the Coming soon homepage (`index.html`).  
`/preview` serves the full marketing page (`home.html`).  
`/share/...` serves the share teaser (`share.html`).

Deploy:

```bash
firebase deploy --only hosting
```

Connect the custom domain in Firebase Console → Hosting → Custom domains → add `ae-journey.com` (and optionally `www.ae-journey.com`).

## Local preview

```bash
python3 share-web/server.py
```

- Home: http://localhost:1111/
- Share: http://localhost:1111/share/<shareId>

Then run the app with local links:

```bash
flutter run --dart-define=SHARE_LOCAL=true
```
