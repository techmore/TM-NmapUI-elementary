Json.Object parse (string text) {
    try {
        var parser = new Json.Parser ();
        parser.load_from_data (text);
        return parser.get_root ().get_object ();
    } catch (Error e) {
        assert_not_reached ();
    }
}

bool valid (string text) {
    return NmapUI.RuntimeSchema.valid (parse (text));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/runtime/idle-and-active-snapshots-are-valid", () => {
        assert (valid ("{\"active_jobs\":[]}"));
        assert (valid ("{\"active_jobs\":[{\"job_type\":\"scan\",\"status\":\"running\",\"paused\":true,\"pause_requested\":false,"
                       + "\"details\":{\"progress\":60,\"message\":null,\"target\":\"10.0.0.0/24\",\"host_count\":30}}]}"));
        assert (valid ("{\"active_jobs\":[{\"job_type\":\"scan\",\"status\":\"cancelling\",\"details\":null}]}"));
        assert (valid ("{\"active_jobs\":[{\"job_type\":\"scan\",\"status\":\"running\",\"details\":{\"progress\":42.5}}]}"));
        assert (valid ("{\"active_jobs\":[{\"job_type\":\"report\",\"status\":\"running\"}]}"));
    });
    Test.add_func ("/runtime/unreadable-snapshots-are-not-idle", () => {
        assert (!NmapUI.RuntimeSchema.valid (null));
        assert (!valid ("{\"error\":\"Unauthorized\"}"));
        foreach (var jobs in new string[] { "null", "{}", "[null]", "[[]]", "[7]", "[{}]",
            "[{\"job_type\":\"scan\",\"status\":\"completed\"}]",
            "[{\"job_type\":\"scan\",\"status\":\"running\",\"paused\":\"false\"}]",
            "[{\"job_type\":\"scan\",\"status\":\"running\",\"details\":[]}]",
            "[{\"job_type\":\"scan\",\"status\":\"running\",\"details\":{\"progress\":\"50\"}}]",
            "[{\"job_type\":\"scan\",\"status\":\"running\",\"details\":{\"message\":7}}]",
            "[{\"job_type\":\"scan\",\"status\":\"running\",\"details\":{\"host_count\":-1}}]",
            "[{\"job_type\":\"scan\",\"status\":\"running\",\"details\":{\"host_count\":9223372036854775807}}]" }) {
            assert (!valid ("{\"active_jobs\":" + jobs + "}"));
        }
    });
    Test.add_func ("/runtime/readers-tolerate-wrong-types", () => {
        var details = parse ("{\"message\":7,\"target\":\"lan\",\"progress\":61.9,\"host_count\":null,\"paused\":true}");
        assert (NmapUI.RuntimeSchema.text (details, "message") == "");
        assert (NmapUI.RuntimeSchema.text (details, "target") == "lan");
        assert (NmapUI.RuntimeSchema.integer (details, "progress", -1) == 61);
        assert (NmapUI.RuntimeSchema.integer (details, "host_count", -1) == -1);
        assert (NmapUI.RuntimeSchema.integer (details, "missing", -1) == -1);
        assert (NmapUI.RuntimeSchema.flag (details, "paused"));
        assert (!NmapUI.RuntimeSchema.flag (details, "message"));
    });
    return Test.run ();
}
