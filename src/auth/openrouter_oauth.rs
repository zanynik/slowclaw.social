//! OpenRouter OAuth2 PKCE flow.
//!
//! OpenRouter supports a simple OAuth2 PKCE flow with no app registration.
//! The user is redirected to OpenRouter to log in (or sign up via Google/GitHub),
//! then redirected back with an authorization code that is exchanged for an API key.

use crate::auth::oauth_common::PkceState;
use anyhow::{Context, Result};
use reqwest::Client;

pub const OPENROUTER_AUTH_URL: &str = "https://openrouter.ai/auth";
pub const OPENROUTER_KEY_EXCHANGE_URL: &str = "https://openrouter.ai/api/v1/auth/keys";
pub const OPENROUTER_DEFAULT_FREE_MODEL: &str = "google/gemini-2.5-flash:free";

/// Build the OpenRouter authorization URL for PKCE flow.
///
/// OpenRouter docs show callback_url passed as a raw URL (not percent-encoded).
/// The code_challenge is base64url and already URL-safe. We avoid encoding them
/// to match the documented examples (`http://localhost:3000` as callback).
pub fn build_authorize_url(pkce: &PkceState, callback_url: &str) -> String {
    format!(
        "{OPENROUTER_AUTH_URL}?callback_url={}&code_challenge={}&code_challenge_method=S256",
        callback_url, pkce.code_challenge
    )
}

/// Exchange the authorization code for an API key.
///
/// Returns the API key string on success.
pub async fn exchange_code_for_key(
    client: &Client,
    code: &str,
    pkce: &PkceState,
) -> Result<String> {
    let body = serde_json::json!({
        "code": code,
        "code_verifier": pkce.code_verifier,
        "code_challenge_method": "S256",
    });

    let response = client
        .post(OPENROUTER_KEY_EXCHANGE_URL)
        .json(&body)
        .send()
        .await
        .context("Failed to exchange OpenRouter authorization code")?;

    let status = response.status();
    let text = response
        .text()
        .await
        .context("Failed to read OpenRouter key exchange response")?;

    if !status.is_success() {
        anyhow::bail!("OpenRouter key exchange failed ({status}): {text}");
    }

    let parsed: serde_json::Value =
        serde_json::from_str(&text).context("Failed to parse OpenRouter key exchange response")?;

    let key = parsed
        .get("key")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("OpenRouter key exchange response missing 'key' field"))?;

    Ok(key.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::oauth_common::generate_pkce_state;

    #[test]
    fn authorize_url_is_well_formed() {
        let pkce = generate_pkce_state();
        let url = build_authorize_url(&pkce, "http://localhost:42617/api/auth/openrouter/callback");
        assert!(url.starts_with(OPENROUTER_AUTH_URL));
        // callback_url should be raw (not percent-encoded) per OpenRouter docs
        assert!(url.contains("callback_url=http://localhost:42617/api/auth/openrouter/callback"));
        assert!(url.contains(&format!("code_challenge={}", pkce.code_challenge)));
        assert!(url.contains("code_challenge_method=S256"));
    }
}
