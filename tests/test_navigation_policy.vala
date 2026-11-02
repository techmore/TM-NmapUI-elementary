const string ORIGIN = "http://127.0.0.1:9000";

void local (string uri) {
    if (!NmapUI.NavigationPolicy.local_uri (uri, ORIGIN)) {
        error ("expected local: %s", uri);
    }
}

void foreign (string uri) {
    if (NmapUI.NavigationPolicy.local_uri (uri, ORIGIN)) {
        error ("expected foreign: %s", uri);
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/navigation/engine-origin-is-local", () => {
        local ("http://127.0.0.1:9000");
        local ("http://127.0.0.1:9000/");
        local ("http://127.0.0.1:9000/#settings");
        local ("http://127.0.0.1:9000/api/reports/x.pdf?download=1");
        local ("HTTP://127.0.0.1:9000/login");
        assert (NmapUI.NavigationPolicy.local_uri ("http://localhost/", "http://LOCALHOST:80"));
    });
    Test.add_func ("/navigation/lookalikes-are-foreign", () => {
        foreign ("http://127.0.0.1:9000@attacker.example/");
        foreign ("http://127.0.0.1:9000@attacker.example:9000/");
        foreign ("http://user@127.0.0.1:9000/");
        foreign ("http://127.0.0.1:9000.attacker.example/");
        foreign ("http://127.0.0.1:90000/");
        foreign ("http://127.0.0.1:9001/");
        foreign ("http://127.0.0.1/");
        foreign ("https://127.0.0.1:9000/");
        foreign ("http://localhost:9000/");
        foreign ("about:blank");
        foreign ("data:text/html,hi");
        foreign ("javascript:alert(1)");
        foreign ("not a uri");
        foreign ("");
        assert (!NmapUI.NavigationPolicy.local_uri (null, ORIGIN));
    });
    Test.add_func ("/navigation/web-uris", () => {
        assert (NmapUI.NavigationPolicy.web_uri ("https://github.com/techmore/TM-NmapUI"));
        assert (NmapUI.NavigationPolicy.web_uri ("http://example.com/"));
        assert (!NmapUI.NavigationPolicy.web_uri ("file:///etc/passwd"));
        assert (!NmapUI.NavigationPolicy.web_uri ("javascript:alert(1)"));
        assert (!NmapUI.NavigationPolicy.web_uri ("mailto:a@example.com"));
    });
    Test.add_func ("/navigation/google-sign-in-goes-to-the-system-browser", () => {
        string auth = "https://accounts.google.com/o/oauth2/v2/auth?client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A9000%2Fapi%2Fsettings%2Fgoogle-drive%2Fcallback&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file&access_type=offline&state=private-state&code_challenge=private-challenge&code_challenge_method=S256";
        assert (NmapUI.NavigationPolicy.google_auth_uri (auth, ORIGIN));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth.replace ("accounts.google.com/", "accounts.google.com.attacker.example/"), ORIGIN));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth.replace ("https://accounts", "http://accounts"), ORIGIN));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth.replace ("https://", "https://evil@"), ORIGIN));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth, "http://127.0.0.1:9100"));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth.replace ("response_type=code", "response_type=token"), ORIGIN));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth.replace ("S256", "plain"), ORIGIN));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth.replace ("drive.file", "drive"), ORIGIN));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth.replace ("state=private-state&", ""), ORIGIN));
        assert (!NmapUI.NavigationPolicy.google_auth_uri (auth + "#frag", ORIGIN));
    });
    return Test.run ();
}
