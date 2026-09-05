//! Main-webview navigation lock.
//!
//! WKWebView routes **every** frame's navigation — the main document and any
//! `<iframe>`, including a sandboxed app that sets `location.href` on itself
//! — through the same policy hook. The sandbox CSP and the iframe `sandbox`
//! attribute cannot stop a frame from navigating *itself* to an external URL
//! (and shipping data in that URL), so this is the third layer: only the
//! app's own origins and the app-content protocol path may ever be navigated
//! to. Everything else is cancelled; external links still open through the
//! opener plugin, which is not a navigation.

/// Decide whether a navigation to `url` is allowed anywhere in the main
/// webview. `dev_url` is the Vite dev server origin in debug builds.
pub(crate) fn navigation_allowed(url: &url::Url, dev_url: Option<&url::Url>) -> bool {
    match url.scheme() {
        // The app shell itself (macOS / Windows+Linux origins).
        "tauri" => url.host_str() == Some("localhost"),
        "http" | "https" => {
            if url.scheme() == "http" && url.host_str() == Some("tauri.localhost") {
                return true;
            }
            match dev_url {
                Some(dev) => {
                    url.scheme() == dev.scheme()
                        && url.host_str() == dev.host_str()
                        && url.port_or_known_default() == dev.port_or_known_default()
                }
                None => false,
            }
        }
        // Only the app-content branch of the custom protocol is a document
        // destination; `/media/*` is for `<img>`/`<video>` subresources.
        "buzz-media" => {
            url.host_str() == Some("localhost")
                && crate::app_content::parse_app_path(url.path()).is_some()
        }
        "about" => url.as_str() == "about:blank" || url.as_str() == "about:srcdoc",
        "blob" | "data" => true,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> url::Url {
        url::Url::parse(s).unwrap()
    }

    #[test]
    fn allows_app_shell_and_app_content_only() {
        assert!(navigation_allowed(&u("tauri://localhost/"), None));
        assert!(navigation_allowed(
            &u("tauri://localhost/index.html#/c/x"),
            None
        ));
        assert!(navigation_allowed(&u("http://tauri.localhost/"), None));
        assert!(navigation_allowed(&u("about:blank"), None));
        assert!(navigation_allowed(&u("about:srcdoc"), None));
        let sha = "a".repeat(64);
        assert!(navigation_allowed(
            &u(&format!("buzz-media://localhost/app/{sha}.html")),
            None
        ));
        // Media subresources are not navigation targets.
        assert!(!navigation_allowed(
            &u(&format!("buzz-media://localhost/media/{sha}.png")),
            None
        ));
        assert!(!navigation_allowed(&u("https://example.com/"), None));
        assert!(!navigation_allowed(
            &u("http://192.168.1.99:3001/app/x.html"),
            None
        ));
        assert!(!navigation_allowed(
            &u("http://127.0.0.1:54321/media/x.png"),
            None
        ));
        assert!(!navigation_allowed(&u("javascript:alert(1)"), None));
        assert!(!navigation_allowed(&u("file:///etc/passwd"), None));
    }

    #[test]
    fn dev_server_origin_is_allowed_only_when_configured() {
        let dev = u("http://localhost:1420");
        assert!(navigation_allowed(
            &u("http://localhost:1420/#/x"),
            Some(&dev)
        ));
        assert!(!navigation_allowed(
            &u("http://localhost:1421/"),
            Some(&dev)
        ));
        assert!(!navigation_allowed(&u("http://localhost:1420/"), None));
    }
}
