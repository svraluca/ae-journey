const functions = require("firebase-functions");
const {onCall} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

const {computeRegion} = require("./explore/infra");
const {
  openaiApiKey,
  googlePlacesApiKey,
  serpApiKey,
  serperApiKey,
  dataForSeoLogin,
  dataForSeoPassword,
  rendererToken,
  firecrawlApiKey,
  zyteApiKey,
  apifyApiToken,
  brightDataApiKey,
  brightDataSerpZone,
  brightDataUnlockerZone,
  brightDataGoogleMapsDatasetId,
} = require("./explore/secrets");
const {handleGetExploreProcedurePrices} = require("./explore/getExploreProcedurePrices");
const {
  handleRequestExploreMarketplaceImport,
} = require("./explore/marketplaces/requestImport");
const {
  handleRequestExploreCityDiscovery,
} = require("./explore/brightdata/cityDiscovery");
const {
  handleEnqueueExploreClinicCandidates,
} = require("./explore/enqueueClinicCandidates");
const {
  handleVerifyExploreCandidates,
  handleScheduledCandidateVerify,
} = require("./explore/verifyCandidateBatch");
const {useApifyFresha} = require("./explore/featureFlags");

admin.initializeApp();

/**
 * Send FCM to the user's stored token and mark the notification doc as sent.
 */
async function sendPushForNotification(notificationRef, data) {
  const recipientId = data.recipientId;
  if (!recipientId) {
    console.log("[FCM] missing recipientId", notificationRef.id);
    return;
  }

  const userSnap = await admin.firestore().collection("users").doc(recipientId).get();
  const token = userSnap.data()?.fcmToken;
  if (!token) {
    console.log("[FCM] no fcmToken for", recipientId);
    return;
  }

  const title = data.title || "ÆSTHETIC JOURNEY";
  const body = data.body || "You have a new notification";

  await admin.messaging().send({
    token,
    notification: {title, body},
    data: {
      type: String(data.type || "general"),
      notificationId: notificationRef.id,
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    apns: {
      payload: {
        aps: {
          sound: "default",
          badge: 1,
        },
      },
    },
    android: {
      priority: "high",
      notification: {
        channelId: "glowpass_notifications",
      },
    },
  });

  await notificationRef.update({
    pushSent: true,
    pushSentAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  console.log("[FCM] sent to", recipientId, notificationRef.id);
}

function deliverAtMillis(data) {
  const d = data.deliverAt;
  if (!d) return null;
  if (typeof d.toMillis === "function") return d.toMillis();
  if (d instanceof Date) return d.getTime();
  return null;
}

/** Immediate push when a notification doc is created (if due now or no schedule). */
exports.onNotificationCreated = functions.firestore
    .document("notifications/{notificationId}")
    .onCreate(async (snap) => {
      const data = snap.data();
      if (data.pushSent === true) return;

      const dueMs = deliverAtMillis(data);
      const now = Date.now();
      if (dueMs != null && dueMs > now + 60_000) {
        console.log("[FCM] scheduled for later", snap.id, new Date(dueMs).toISOString());
        return;
      }

      try {
        await sendPushForNotification(snap.ref, data);
      } catch (e) {
        console.error("[FCM] onCreate failed", snap.id, e);
      }
    });

/** Every 15 minutes: send pushes for due scheduled notifications. */
exports.deliverDueNotifications = functions.pubsub
    .schedule("every 15 minutes")
    .onRun(async () => {
      const now = admin.firestore.Timestamp.now();
      const due = await admin
          .firestore()
          .collection("notifications")
          .where("pushSent", "==", false)
          .where("deliverAt", "<=", now)
          .limit(40)
          .get();

      for (const doc of due.docs) {
        try {
          await sendPushForNotification(doc.ref, doc.data());
        } catch (e) {
          console.error("[FCM] scheduled send failed", doc.id, e);
        }
      }

      return null;
    });

/**
 * Explore clinic prices: Places identity + DataForSEO URL discovery +
 * deterministic HTML extraction. Never uses an LLM or a search snippet for
 * numeric prices.
 */
exports.getExploreProcedurePrices = onCall(
    {
      region: computeRegion,
      timeoutSeconds: 120,
      memory: "512MiB",
      secrets: [
        openaiApiKey,
        googlePlacesApiKey,
        serpApiKey,
        serperApiKey,
        dataForSeoLogin,
        dataForSeoPassword,
        rendererToken,
        firecrawlApiKey,
        zyteApiKey,
        brightDataApiKey,
        brightDataSerpZone,
        brightDataUnlockerZone,
      ],
    },
    handleGetExploreProcedurePrices,
);

/**
 * Background Bright Data city/procedure clinic discovery.
 * Flutter must not await this for Explore paint.
 */
exports.requestExploreCityDiscovery = onCall(
    {
      region: computeRegion,
      timeoutSeconds: 540,
      memory: "1GiB",
      secrets: [
        brightDataApiKey,
        brightDataGoogleMapsDatasetId,
        googlePlacesApiKey,
      ],
    },
    handleRequestExploreCityDiscovery,
);

/**
 * Persist client-discovered clinic identities (no fabricated prices).
 * Used when client Serp finds official sites while backend coverage is empty.
 */
exports.enqueueExploreClinicCandidates = onCall(
    {
      region: computeRegion,
      timeoutSeconds: 60,
      memory: "256MiB",
    },
    handleEnqueueExploreClinicCandidates,
);

/**
 * Background batch: verify stored clinic candidates (5–10 per call).
 * Flutter must not await this for Explore paint.
 */
const exploreVerifySecrets = [
  openaiApiKey,
  googlePlacesApiKey,
  serpApiKey,
  serperApiKey,
  dataForSeoLogin,
  dataForSeoPassword,
  rendererToken,
  firecrawlApiKey,
  zyteApiKey,
  brightDataApiKey,
  brightDataSerpZone,
  brightDataUnlockerZone,
];

// Region must stay us-central1 — Flutter ExploreBackendService.region is
// us-central1. A mismatch surfaces as callable not-found.
exports.verifyExploreCandidates = onCall(
    {
      region: computeRegion,
      timeoutSeconds: 120,
      memory: "512MiB",
      secrets: exploreVerifySecrets,
    },
    handleVerifyExploreCandidates,
);

exports.scheduledExploreCandidateVerify = onSchedule(
    {
      // Daily — every 15 minutes was the Places Details / Atmosphere bill.
      schedule: "every 24 hours",
      region: computeRegion,
      timeoutSeconds: 180,
      memory: "512MiB",
      secrets: exploreVerifySecrets,
    },
    handleScheduledCandidateVerify,
);

/**
 * Legacy Fresha marketplace import — disabled unless USE_APIFY_FRESHA=true.
 */
exports.requestExploreMarketplaceImport = onCall(
    {
      region: computeRegion,
      timeoutSeconds: 540,
      memory: "1GiB",
      secrets: [
        apifyApiToken,
        googlePlacesApiKey,
        serperApiKey,
        dataForSeoLogin,
        dataForSeoPassword,
        serpApiKey,
      ],
    },
    async (request) => {
      if (!useApifyFresha()) {
        console.log("[FRESHA IMPORT] disabled · USE_APIFY_FRESHA=false");
        return {
          ok: false,
          skipped: true,
          reason: "apify_fresha_disabled",
          status: "disabled",
          venues: 0,
          services: 0,
          clinics: 0,
          prices: 0,
        };
      }
      return handleRequestExploreMarketplaceImport(request);
    },
);
