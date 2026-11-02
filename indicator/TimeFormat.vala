/* Times from the scanner engine, for display in the indicator. The engine writes naive local
 * times (Python's datetime.now ().isoformat ()), so a timestamp without an offset is in the
 * computer's own time zone, not UTC. Timestamps with "Z" or an offset keep their zone. */
namespace MSeries.TimeFormat {
    public DateTime? parse (string iso, TimeZone local) {
        if (iso == "") {
            return null;
        }
        return new DateTime.from_iso8601 (iso, local);
    }

    /** "just now", "5 minutes ago", …; text that isn't a timestamp comes back unchanged. */
    public string relative (string iso, DateTime now, TimeZone local) {
        var then = parse (iso, local);
        if (then == null) {
            return iso;
        }
        var seconds = now.difference (then) / TimeSpan.SECOND;
        if (seconds < 90) return _("just now");
        if (seconds < 5400) return ngettext ("%d minute ago", "%d minutes ago", (ulong) (seconds / 60)).printf ((int) (seconds / 60));
        if (seconds < 129600) return ngettext ("%d hour ago", "%d hours ago", (ulong) (seconds / 3600)).printf ((int) (seconds / 3600));
        return ngettext ("%d day ago", "%d days ago", (ulong) (seconds / 86400)).printf ((int) (seconds / 86400));
    }

    /** A future time as "01:00" today or "Tue 01:00" later; text that isn't a timestamp comes back unchanged. */
    public string clock (string iso, DateTime now, TimeZone local) {
        var then = parse (iso, local);
        if (then == null) {
            return iso;
        }
        then = then.to_timezone (local);
        var today = now.to_timezone (local);
        bool same_day = then.get_year () == today.get_year () && then.get_day_of_year () == today.get_day_of_year ();
        return then.format (same_day ? "%H:%M" : "%a %H:%M");
    }
}
