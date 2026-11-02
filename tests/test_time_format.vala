using MSeries;

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/time/naive-engine-times-are-local", () => {
        // US Eastern in winter: a naive "08:55" is 13:55 UTC, five minutes before 09:00 local.
        var eastern = new TimeZone.offset (-5 * 3600);
        var now = new DateTime (eastern, 2026, 11, 2, 9, 0, 0);
        assert (TimeFormat.relative ("2026-11-02T08:55:00", now, eastern) == "5 minutes ago");
        assert (TimeFormat.relative ("2026-11-02T08:54:59.5", now, eastern) == "5 minutes ago");
        assert (TimeFormat.relative ("2026-11-02T06:00:00", now, eastern) == "3 hours ago");
    });
    Test.add_func ("/time/east-of-utc-is-not-just-now-for-hours", () => {
        var berlin = new TimeZone.offset (2 * 3600);
        var now = new DateTime (berlin, 2026, 11, 2, 9, 0, 0);
        assert (TimeFormat.relative ("2026-11-02T07:00:00", now, berlin) == "2 hours ago");
        assert (TimeFormat.relative ("2026-11-02T08:59:30", now, berlin) == "just now");
    });
    Test.add_func ("/time/explicit-zones-are-kept", () => {
        var eastern = new TimeZone.offset (-5 * 3600);
        var now = new DateTime (eastern, 2026, 11, 2, 9, 0, 0);
        assert (TimeFormat.relative ("2026-11-02T13:55:00Z", now, eastern) == "5 minutes ago");
        assert (TimeFormat.relative ("2026-11-02T14:55:00+01:00", now, eastern) == "5 minutes ago");
        assert (TimeFormat.relative ("2026-10-30T09:00:00", now, eastern) == "3 days ago");
    });
    Test.add_func ("/time/clock-for-next-run", () => {
        var eastern = new TimeZone.offset (-5 * 3600);
        var now = new DateTime (eastern, 2026, 11, 2, 9, 0, 0);
        assert (TimeFormat.clock ("2026-11-02T23:30:00", now, eastern) == "23:30");
        assert (TimeFormat.clock ("2026-11-03T01:00:00", now, eastern) == "Tue 01:00");
        assert (TimeFormat.clock ("01:00", now, eastern) == "01:00");
        assert (TimeFormat.relative ("soon", now, eastern) == "soon");
    });
    return Test.run ();
}
