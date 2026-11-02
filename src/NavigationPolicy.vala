/* Decides which URLs stay inside the app window. Only the engine's own origin renders here;
 * everything else either opens in the user's browser or is refused. URLs are parsed, never
 * prefix-matched: http://127.0.0.1:9000@attacker.example/ starts with the engine's origin but
 * its host is attacker.example. */
namespace NmapUI {
    public class NavigationPolicy : Object {
        public const string GOOGLE_AUTH_HOST = "accounts.google.com";
        public const string GOOGLE_AUTH_PATH = "/o/oauth2/v2/auth";
        public const string GOOGLE_DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.file";
        public const string GOOGLE_CALLBACK_PATH = "/api/settings/google-drive/callback";

        /** True when `uri` has exactly the scheme, host and port of `origin`, and no userinfo. */
        public static bool local_uri (string? uri, string origin) {
            if (uri == null || uri == "") {
                return false;
            }
            try {
                var target = Uri.parse (uri, UriFlags.NONE);
                var engine = Uri.parse (origin, UriFlags.NONE);
                var host = target.get_host ();
                var engine_host = engine.get_host ();
                return target.get_userinfo () == null
                    && host != null && host != "" && engine_host != null
                    && target.get_scheme ().ascii_down () == engine.get_scheme ().ascii_down ()
                    && host.ascii_down () == engine_host.ascii_down ()
                    && effective_port (target) == effective_port (engine);
            } catch (UriError e) {
                return false;
            }
        }

        /** True for an http(s) URL that may be handed to the user's browser. */
        public static bool web_uri (string? uri) {
            if (uri == null) {
                return false;
            }
            try {
                var parsed = Uri.parse (uri, UriFlags.NONE);
                var scheme = parsed.get_scheme ().ascii_down ();
                return (scheme == "http" || scheme == "https") && parsed.get_host () != null && parsed.get_host () != "";
            } catch (UriError e) {
                return false;
            }
        }

        /** True for the engine's Google Drive sign-in URL (PKCE, drive.file scope, callback on `origin`).
         * The engine keeps the OAuth state server side, so the sign-in can finish in the user's browser
         * instead of an embedded web view that Google refuses and the user can't inspect. */
        public static bool google_auth_uri (string? uri, string origin) {
            if (uri == null) {
                return false;
            }
            try {
                // Keep the query encoded until parse_params decodes each value.
                var parsed = Uri.parse (uri, UriFlags.ENCODED_QUERY);
                if (parsed.get_scheme () != "https" || parsed.get_host () != GOOGLE_AUTH_HOST
                    || (parsed.get_port () != -1 && parsed.get_port () != 443)
                    || parsed.get_userinfo () != null || parsed.get_fragment () != null
                    || parsed.get_path () != GOOGLE_AUTH_PATH || parsed.get_query () == null) {
                    return false;
                }
                var query = Uri.parse_params (parsed.get_query (), -1, "&", UriParamsFlags.NONE);
                return query.lookup ("redirect_uri") == origin + GOOGLE_CALLBACK_PATH
                    && query.lookup ("response_type") == "code"
                    && query.lookup ("scope") == GOOGLE_DRIVE_SCOPE
                    && query.lookup ("code_challenge_method") == "S256"
                    && (query.lookup ("state") ?? "") != ""
                    && (query.lookup ("code_challenge") ?? "") != "";
            } catch (Error e) {
                return false;
            }
        }

        private static int effective_port (Uri uri) {
            var port = uri.get_port ();
            if (port != -1) {
                return port;
            }
            switch (uri.get_scheme ().ascii_down ()) {
                case "http": return 80;
                case "https": return 443;
                default: return -1;
            }
        }
    }
}
