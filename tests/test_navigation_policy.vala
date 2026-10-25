int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/navigation/exact-engine-origin", () => {
        assert (NmapUI.NavigationPolicy.local_uri ("http://127.0.0.1:9000/#settings", "http://127.0.0.1:9000"));
        assert (!NmapUI.NavigationPolicy.local_uri ("http://127.0.0.1:9000.attacker.example/", "http://127.0.0.1:9000"));
        assert (!NmapUI.NavigationPolicy.local_uri ("http://127.0.0.1:90000/", "http://127.0.0.1:9000"));
    });
    Test.add_func ("/navigation/google-system-browser-handoff", () => {
        string auth = "https://accounts.google.com/o/oauth2/v2/auth?redirect_uri=http%3A%2F%2F127.0.0.1%3A9000%2Fapi%2Fsettings%2Fgoogle-drive%2Fcallback&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file&code_challenge_method=S256&state=private-state&code_challenge=private-challenge";
        assert (NmapUI.NavigationPolicy.google_auth_uri (auth, "http://127.0.0.1:9000"));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth.replace ("accounts.google.com/", "accounts.google.com.attacker.example/"), "http://127.0.0.1:9000"));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth.replace ("https://accounts", "http://accounts"), "http://127.0.0.1:9000"));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth, "http://127.0.0.1:9100"));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth.replace ("response_type=code", "response_type=token"), "http://127.0.0.1:9000"));
    });
    return Test.run ();
}
