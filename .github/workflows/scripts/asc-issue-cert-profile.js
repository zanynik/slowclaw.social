// App Store Connect cert + provisioning-profile issuance.
//
// Extracted verbatim from .github/workflows/pub-testflight-ios.yml so both
// the Tauri pipeline and the Zig pipeline share the same signing dance.
// Environment variables are the contract (see the workflow's "Prepare Apple
// distribution signing assets" step):
//
//   ASC_KEY_PATH       — path to AuthKey_<KEY_ID>.p8
//   ASC_ISSUER_ID      — App Store Connect issuer ID
//   ASC_KEY_ID         — App Store Connect key ID
//   APP_BUNDLE_ID      — bundle identifier (com.slowclaw.app)
//   CERT_CSR_PATH      — input CSR (openssl-generated)
//   CERT_OUT_PATH      — output: distribution.cer (base64-decoded)
//   PROFILE_OUT_PATH   — output: profile.mobileprovision (base64-decoded)
//   PROFILE_ID_OUT_PATH   — output: profile UUID
//   PROFILE_NAME_OUT_PATH — output: profile name
//   PROFILE_NAME       — desired profile name

const crypto = require("crypto");
const fs = require("fs");
const https = require("https");

function base64Url(input) {
  return Buffer.from(input).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function jwt() {
  const header = { alg: "ES256", kid: process.env.ASC_KEY_ID, typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: process.env.ASC_ISSUER_ID,
    iat: now,
    exp: now + 900,
    aud: "appstoreconnect-v1"
  };
  const body = `${base64Url(JSON.stringify(header))}.${base64Url(JSON.stringify(payload))}`;
  const privateKey = fs.readFileSync(process.env.ASC_KEY_PATH, "utf8");
  const signature = crypto.sign("sha256", Buffer.from(body), {
    key: privateKey,
    dsaEncoding: "ieee-p1363"
  });
  return `${body}.${base64Url(signature)}`;
}

async function request(token, method, path, body) {
  const payload = body ? JSON.stringify(body) : undefined;
  const response = await new Promise((resolve, reject) => {
    const req = https.request({
      hostname: "api.appstoreconnect.apple.com",
      method,
      path,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "Content-Type": "application/json",
        ...(payload ? { "Content-Length": Buffer.byteLength(payload) } : {})
      }
    }, (res) => {
      let raw = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => raw += chunk);
      res.on("end", () => resolve({ status: res.statusCode, raw }));
    });
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
  let parsed = {};
  if (response.raw.trim()) {
    parsed = JSON.parse(response.raw);
  }
  if (response.status < 200 || response.status >= 300) {
    const detail = parsed?.errors?.[0]?.detail || parsed?.errors?.[0]?.title || `HTTP ${response.status}`;
    // Include the operation, never tokens, request bodies, or resource IDs.
    const resource = path.split("?")[0].replace(/\/([A-Z0-9]{8,})(?=\/|$)/g, "/<id>");
    throw new Error(`${method} ${resource} (HTTP ${response.status}): ${detail}`);
  }
  return parsed;
}

(async () => {
  const token = jwt();
  const bundleId = process.env.APP_BUNDLE_ID;
  const bundle = await request(token, "GET", `/v1/bundleIds?filter[identifier]=${encodeURIComponent(bundleId)}`);
  const bundleRecord = bundle.data?.[0];
  if (!bundleRecord?.id) {
    throw new Error(`Bundle ID ${bundleId} was not found in App Store Connect.`);
  }

  // Revoke stale SlowClaw CI profiles + their associated distribution certs
  // before issuing fresh ones (Apple limits both).
  const staleProfiles = await request(token, "GET", "/v1/profiles?filter[profileType]=IOS_APP_STORE&limit=200");
  for (const staleProfile of staleProfiles.data || []) {
    if (!String(staleProfile.attributes?.name || "").startsWith("SlowClaw CI App Store ")) {
      continue;
    }
    const relatedCerts = await request(token, "GET", `/v1/profiles/${staleProfile.id}/certificates?fields[certificates]=certificateType&limit=20`);
    for (const relatedCert of relatedCerts.data || []) {
      if (relatedCert.attributes?.certificateType === "IOS_DISTRIBUTION") {
        await request(token, "DELETE", `/v1/certificates/${relatedCert.id}`);
      }
    }
    // Keep the ownership link until certificate cleanup succeeds. Otherwise
    // a transient delete failure leaves a certificate we cannot find next run.
    await request(token, "DELETE", `/v1/profiles/${staleProfile.id}`);
  }

  const csrContent = fs.readFileSync(process.env.CERT_CSR_PATH, "utf8");
  let cert;
  try {
    cert = await request(token, "POST", "/v1/certificates", {
      data: {
        type: "certificates",
        attributes: {
          certificateType: "IOS_DISTRIBUTION",
          csrContent
        }
      }
    });
  } catch (error) {
    try {
      const certificates = await request(token, "GET", "/v1/certificates?filter[certificateType]=IOS_DISTRIBUTION&limit=200");
      let ciSubjectCount = 0;
      for (const record of certificates.data || []) {
        try {
          const x509 = new crypto.X509Certificate(Buffer.from(record.attributes.certificateContent, "base64"));
          if (x509.subject.split("\n").includes("CN=SlowClaw CI")) ciSubjectCount++;
        } catch { /* Diagnostic only; never delete based on a subject match. */ }
      }
      console.error(`Signing diagnostic: ${(certificates.data || []).length} iOS distribution certificate(s); ${ciSubjectCount} with the SlowClaw CI subject. No certificates were deleted by this diagnostic.`);
    } catch (diagnosticError) {
      console.error(`Certificate inventory unavailable: ${diagnosticError.message}`);
    }
    throw new Error(`Certificate issuance failed. Existing team certificates were left unchanged by recovery. Apple said: ${error.message}`);
  }
  const certRecord = cert.data;
  fs.writeFileSync(process.env.CERT_OUT_PATH, Buffer.from(certRecord.attributes.certificateContent, "base64"));

  let profile;
  try {
    profile = await request(token, "POST", "/v1/profiles", {
    data: {
      type: "profiles",
      attributes: {
        name: process.env.PROFILE_NAME,
        profileType: "IOS_APP_STORE"
      },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundleRecord.id } },
        certificates: { data: [{ type: "certificates", id: certRecord.id }] }
      }
    }
  });
  } catch (error) {
    // Only this attempt's newly issued certificate is ours to revoke. Never
    // delete arbitrary team certificates to make room under Apple's quota.
    try {
      await request(token, "DELETE", `/v1/certificates/${certRecord.id}`);
    } catch {
      console.error("Could not clean up this run's newly issued certificate; review Apple Developer Certificates before retrying.");
    }
    throw error;
  }
  const profileRecord = profile.data;
  fs.writeFileSync(process.env.PROFILE_OUT_PATH, Buffer.from(profileRecord.attributes.profileContent, "base64"));
  fs.writeFileSync(process.env.PROFILE_NAME_OUT_PATH, profileRecord.attributes.name);
  fs.writeFileSync(process.env.PROFILE_ID_OUT_PATH, profileRecord.attributes.uuid);
  fs.appendFileSync(process.env.GITHUB_ENV, `APPLE_PROVISIONING_PROFILE_NAME=${profileRecord.attributes.name}\n`);
  fs.appendFileSync(process.env.GITHUB_ENV, `APPLE_PROVISIONING_PROFILE_ID=${profileRecord.attributes.uuid}\n`);
})().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
