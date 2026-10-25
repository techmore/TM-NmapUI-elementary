bool valid (string text) {
    try {
        var parser = new Json.Parser ();
        parser.load_from_data (text);
        return NmapUI.RuntimeSchema.valid (parser.get_root ().get_object ());
    } catch (Error e) { assert_not_reached (); }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/runtime/valid-active-and-idle", () => {
        assert (valid ("{\"active_jobs\":[]}"));
        assert (valid ("{\"active_jobs\":[{\"job_type\":\"scan\",\"status\":\"running\",\"paused\":true,\"details\":{\"progress\":9223372036854775807,\"message\":null}}]}"));
        assert (valid ("{\"active_jobs\":[{\"job_type\":\"report\",\"status\":\"running\"}]}"));
    });
    Test.add_func ("/runtime/malformed-snapshot-is-unavailable", () => {
        foreach (var jobs in new string[] {"null", "{}", "[null]", "[[]]", "[7]", "[{}]",
            "[{\"job_type\":\"scan\",\"status\":\"completed\"}]",
            "[{\"job_type\":\"scan\",\"status\":\"running\",\"paused\":\"false\"}]",
            "[{\"job_type\":\"scan\",\"status\":\"running\",\"details\":[]}]",
            "[{\"job_type\":\"scan\",\"status\":\"running\",\"details\":{\"progress\":\"50\"}}]",
            "[{\"job_type\":\"scan\",\"status\":\"running\",\"details\":{\"host_count\":9223372036854775807}}]"}) {
            assert (!valid ("{\"active_jobs\":" + jobs + "}"));
        }
    });
    return Test.run ();
}
