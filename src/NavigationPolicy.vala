/* Keep application navigation on the exact engine origin. OAuth belongs in the
 * system browser, not a developer-controlled embedded user-agent. */
namespace NmapUI {
    internal class NavigationPolicy : Object {
        public static bool local_uri (string? uri, string origin) {
            if (uri == null) return false;
            // A slash/query/fragment boundary prevents origins such as
            // http://127.0.0.1:9000.attacker.example from matching the engine.
            return uri == origin || uri.has_prefix (origin + "/")
                || uri.has_prefix (origin + "?") || uri.has_prefix (origin + "#");
        }

        public static bool google_auth_uri (string? uri, string origin) {
            if (uri == null) return false;
            try {
                // Preserve query encoding until parse_params decodes each value.
                var parsed = Uri.parse (uri, UriFlags.ENCODED_QUERY);
                if (parsed.get_scheme () != "https" || parsed.get_host () != "accounts.google.com"
                    || (parsed.get_port () != -1 && parsed.get_port () != 443)
                    || parsed.get_userinfo () != null || parsed.get_fragment () != null
                    || parsed.get_path () != "/o/oauth2/v2/auth" || parsed.get_query () == null) {
                    return false;
                }
                var query = Uri.parse_params (parsed.get_query (), -1, "&", UriParamsFlags.NONE);
                return query.lookup ("redirect_uri") == origin + "/api/settings/google-drive/callback"
                    && query.lookup ("response_type") == "code"
                    && query.lookup ("scope") == "https://www.googleapis.com/auth/drive.file"
                    && query.lookup ("code_challenge_method") == "S256"
                    && query.lookup ("state") != null && query.lookup ("state") != ""
                    && query.lookup ("code_challenge") != null && query.lookup ("code_challenge") != "";
            } catch (Error error) {
                return false;
            }
        }
    }
}
