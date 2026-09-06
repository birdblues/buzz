//! `buzz community` — the profile the relay advertises for this community.
//!
//! Upstream stores a per-community icon (set by the desktop through the
//! kind:9033 workspace-profile command) and serves it as the NIP-11 `icon`.
//! The fork adds a `name` the same way: `set-name` publishes a 9033 carrying
//! only a `name` tag, the relay stores it and serves it as the NIP-11
//! `name`, and every client shows it instead of a host-derived label. The
//! relay leaves the icon untouched for a name-only command, so this never
//! needs to know the current icon. Relay admin/owner only (the relay
//! enforces it; see `handlers/relay_admin.rs`).

use crate::{
    client::{normalize_write_response, BuzzClient},
    error::CliError,
};
use buzz_core::kind::RELAY_ADMIN_SET_WORKSPACE_PROFILE;
use nostr::{EventBuilder, Kind, Tag};

/// Mirrors the relay's limit so a too-long name fails here, not with a
/// relay error after signing.
const MAX_NAME_CHARS: usize = 64;

/// Validate a name the way the relay will: trimmed, non-empty unless
/// clearing, one line, at most [`MAX_NAME_CHARS`] characters. Returns the
/// tag value to send (empty string clears).
pub fn name_tag_value(name: Option<&str>, clear: bool) -> Result<String, CliError> {
    if clear {
        return Ok(String::new());
    }
    let name = name.unwrap_or_default().trim();
    if name.is_empty() {
        return Err(CliError::Usage(
            "community name must not be empty (use --clear to remove it)".to_string(),
        ));
    }
    if name.chars().any(char::is_control) {
        return Err(CliError::Usage(
            "community name must be a single line without control characters".to_string(),
        ));
    }
    let len = name.chars().count();
    if len > MAX_NAME_CHARS {
        return Err(CliError::Usage(format!(
            "community name is {len} characters; the relay accepts at most {MAX_NAME_CHARS}"
        )));
    }
    Ok(name.to_string())
}

/// Build the kind:9033 event that sets (or, with an empty value, clears) the
/// community name and nothing else.
pub fn build_set_name(value: &str) -> Result<EventBuilder, CliError> {
    let tag =
        Tag::parse(["name", value]).map_err(|e| CliError::Other(format!("tag error: {e}")))?;
    Ok(EventBuilder::new(Kind::Custom(RELAY_ADMIN_SET_WORKSPACE_PROFILE as u16), "").tags([tag]))
}

pub async fn cmd_set_name(
    client: &BuzzClient,
    name: Option<&str>,
    clear: bool,
) -> Result<(), CliError> {
    let value = name_tag_value(name, clear)?;
    let event = client.sign_event(build_set_name(&value)?)?;
    let resp = client.submit_event(event).await?;
    println!("{}", normalize_write_response(&resp));
    Ok(())
}

/// The relay's NIP-11 document reduced to the community profile fields.
pub fn profile_from_relay_info(document: &str) -> Result<serde_json::Value, CliError> {
    let info: serde_json::Value = serde_json::from_str(document)
        .map_err(|e| CliError::Other(format!("relay information document is not JSON: {e}")))?;
    Ok(serde_json::json!({
        "name": info.get("name").cloned().unwrap_or(serde_json::Value::Null),
        "icon": info.get("icon").cloned().unwrap_or(serde_json::Value::Null),
    }))
}

pub async fn cmd_profile(client: &BuzzClient) -> Result<(), CliError> {
    let document = client.get_public("/").await?;
    println!("{}", profile_from_relay_info(&document)?);
    Ok(())
}

pub async fn dispatch(cmd: crate::CommunityCmd, client: &BuzzClient) -> Result<(), CliError> {
    use crate::CommunityCmd;
    match cmd {
        CommunityCmd::Profile => cmd_profile(client).await,
        CommunityCmd::SetName { name, clear } => cmd_set_name(client, name.as_deref(), clear).await,
    }
}

#[cfg(test)]
mod tests {
    use super::{build_set_name, name_tag_value, profile_from_relay_info};
    use buzz_core::kind::RELAY_ADMIN_SET_WORKSPACE_PROFILE;
    use nostr::Keys;

    #[test]
    fn name_is_trimmed_and_bounded() {
        assert_eq!(
            name_tag_value(Some("  슈퍼지구 "), false).unwrap(),
            "슈퍼지구"
        );
        assert_eq!(name_tag_value(Some("x"), true).unwrap(), "");
        assert_eq!(name_tag_value(None, true).unwrap(), "");
        assert!(name_tag_value(Some("   "), false).is_err());
        assert!(name_tag_value(None, false).is_err());
        assert!(name_tag_value(Some("two\nlines"), false).is_err());
        assert!(name_tag_value(Some(&"가".repeat(64)), false).is_ok());
        assert!(name_tag_value(Some(&"가".repeat(65)), false).is_err());
    }

    #[test]
    fn set_name_event_carries_only_a_name_tag_on_kind_9033() {
        let keys = Keys::generate();
        let event = build_set_name("슈퍼지구")
            .unwrap()
            .sign_with_keys(&keys)
            .unwrap();
        assert_eq!(
            event.kind,
            nostr::Kind::Custom(RELAY_ADMIN_SET_WORKSPACE_PROFILE as u16)
        );
        assert_eq!(event.content, "");
        let tags: Vec<Vec<String>> = event.tags.iter().map(|t| t.as_slice().to_vec()).collect();
        assert_eq!(tags, vec![vec!["name".to_string(), "슈퍼지구".to_string()]]);
    }

    #[test]
    fn profile_reduces_the_relay_document() {
        let doc = r#"{"name":"슈퍼지구","icon":"data:image/webp;base64,UklGRg==","software":"x"}"#;
        let profile = profile_from_relay_info(doc).unwrap();
        assert_eq!(profile["name"], "슈퍼지구");
        assert_eq!(profile["icon"], "data:image/webp;base64,UklGRg==");
        let bare = profile_from_relay_info(r#"{"name":"Buzz Relay"}"#).unwrap();
        assert_eq!(bare["name"], "Buzz Relay");
        assert!(bare["icon"].is_null());
        assert!(profile_from_relay_info("not json").is_err());
    }
}
