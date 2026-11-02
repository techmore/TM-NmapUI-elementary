/* Watches the local scanner service over loopback HTTP and drives its systemd user unit.
 * Nothing here talks to the internet: the only peer is http://127.0.0.1:<port>. */
namespace NmapUI {
    public enum ServiceState {
        OFFLINE,
        STARTING,
        /* The service answers, but its activity can't be read (refused or malformed status). */
        UNAVAILABLE,
        IDLE,
        SCANNING,
        PAUSING,
        PAUSED,
        STOPPING;

        public string label () {
            switch (this) {
                case STARTING: return _("Starting…");
                case UNAVAILABLE: return _("Status unavailable");
                case IDLE: return _("Ready");
                case SCANNING: return _("Scanning");
                case PAUSING: return _("Pausing scan…");
                case PAUSED: return _("Scan paused");
                case STOPPING: return _("Stopping scan");
                default: return _("Not running");
            }
        }

        public string css () {
            switch (this) {
                case STARTING: return "starting";
                case UNAVAILABLE: return "unavailable";
                case IDLE: return "idle";
                case SCANNING: return "scanning";
                case PAUSING: return "scanning";
                case PAUSED: return "scanning";
                case STOPPING: return "scanning";
                default: return "offline";
            }
        }

        /** A scan is running, paused or winding down. */
        public bool has_scan () {
            return this == SCANNING || this == PAUSING || this == PAUSED || this == STOPPING;
        }
    }

    public class Backend : Object {
        public const uint POLL_SECONDS = 4;
        private const size_t MAX_BODY_BYTES = 2 * 1024 * 1024;

        public string origin { get; construct; }
        public string unit { get; construct; }

        public ServiceState state { get; private set; default = ServiceState.OFFLINE; }
        public string version { get; private set; default = ""; }
        /** Human progress line from the engine while scanning, e.g. "Service scan 2/30: 10.0.0.8". */
        public string message { get; private set; default = ""; }
        /** 0-100 while scanning, -1 when unknown. */
        public int progress { get; private set; default = -1; }
        /** Hosts in the running scan, -1 when unknown. */
        public int hosts { get; private set; default = -1; }
        public string target { get; private set; default = ""; }
        /** Why the scanner's activity can't be read, while the state is UNAVAILABLE. */
        public string reason { get; private set; default = ""; }

        public signal void changed ();
        public signal void came_online ();
        public signal void scan_finished (int hosts, string target);

        private Soup.Session session;
        private uint poll_source = 0;
        private bool in_flight = false;
        private bool start_requested = false;
        private int last_scan_hosts = -1;
        private string last_scan_target = "";

        public Backend (string origin, string unit) {
            Object (origin: origin, unit: unit);
        }

        construct {
            session = new Soup.Session () { timeout = 3 };
            poll_source = Timeout.add_seconds (POLL_SECONDS, () => {
                poll.begin ();
                return Source.CONTINUE;
            });
            poll.begin ();
        }

        ~Backend () {
            if (poll_source != 0) {
                Source.remove (poll_source);
            }
        }

        public async void poll () {
            if (in_flight) {
                return;
            }
            in_flight = true;
            var previous = state;
            uint status;
            var health = yield fetch ("/api/health", out status);
            if (health == null) {
                apply_offline ();
            } else {
                start_requested = false;
                version = RuntimeSchema.text (health, "app_version");
                var runtime = yield fetch ("/api/runtime/status", out status);
                if (RuntimeSchema.valid (runtime)) {
                    apply_runtime (runtime);
                } else {
                    apply_unavailable (status);
                }
            }
            in_flight = false;
            changed ();
            bool was_down = previous == ServiceState.OFFLINE || previous == ServiceState.STARTING;
            bool is_up = state != ServiceState.OFFLINE && state != ServiceState.STARTING;
            if (was_down && is_up) {
                came_online ();
            }
            // Only a readable idle snapshot after a scan means it ended; an unreadable one proves nothing.
            if (previous.has_scan () && state == ServiceState.IDLE) {
                scan_finished (last_scan_hosts, last_scan_target);
            }
        }

        public void start_service () {
            run_systemctl ("start");
        }

        public void restart_service () {
            run_systemctl ("restart");
        }

        /** True when the user unit file exists for this account. */
        public bool unit_installed () {
            try {
                var process = new Subprocess (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE,
                                              "systemctl", "--user", "cat", unit);
                process.wait (null);
                return process.get_successful ();
            } catch (Error e) {
                return false;
            }
        }

        private void run_systemctl (string verb) {
            start_requested = true;
            state = ServiceState.STARTING;
            changed ();
            try {
                var process = new Subprocess (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE,
                                              "systemctl", "--user", verb, unit);
                process.communicate_utf8_async.begin (null, null, (obj, res) => {
                    string? stderr_text = null;
                    try {
                        process.communicate_utf8_async.end (res, null, out stderr_text);
                    } catch (Error e) {
                        stderr_text = e.message;
                    }
                    if (!process.get_successful ()) {
                        warning ("systemctl --user %s %s failed: %s", verb, unit, (stderr_text ?? "").strip ());
                        start_requested = false;
                    }
                    poll.begin ();
                });
            } catch (Error e) {
                warning ("Could not run systemctl: %s", e.message);
                start_requested = false;
                poll.begin ();
            }
        }

        private void apply_offline () {
            state = start_requested ? ServiceState.STARTING : ServiceState.OFFLINE;
            clear_scan ();
        }

        private void clear_scan () {
            message = "";
            progress = -1;
            hosts = -1;
            target = "";
            reason = "";
        }

        /* The service is up but /api/runtime/status was refused or unreadable. Saying "Ready" here
         * would hide a running scan, so say why the status is missing instead. */
        private void apply_unavailable (uint status) {
            state = ServiceState.UNAVAILABLE;
            clear_scan ();
            if (status == 401 || status == 403 || (status >= 300 && status < 400)) {
                reason = _("The scanner refused this app’s status request (HTTP %u). Sign in to the scanner, or allow local access in its settings.").printf (status);
            } else if (status == 503) {
                reason = _("The scanner refuses status requests until its sign-in is set up securely (HTTP 503). Finish setting up sign-in in the scanner.");
            } else if (status != 200 && status != 0) {
                reason = _("The scanner answered the status request with HTTP %u.").printf (status);
            } else {
                reason = _("The scanner’s status reply couldn’t be read.");
            }
        }

        /* `runtime` has passed RuntimeSchema.valid (). */
        private void apply_runtime (Json.Object runtime) {
            Json.Object? scan = null;
            var jobs = runtime.get_array_member ("active_jobs");
            for (uint i = 0; i < jobs.get_length (); i++) {
                var job = jobs.get_object_element (i);
                if (RuntimeSchema.text (job, "job_type") == "scan") {
                    scan = job;
                    break;
                }
            }
            if (scan == null) {
                state = ServiceState.IDLE;
                clear_scan ();
                return;
            }
            reason = "";
            if (RuntimeSchema.text (scan, "status") == "cancelling") {
                state = ServiceState.STOPPING;
            } else if (RuntimeSchema.flag (scan, "paused")) {
                state = ServiceState.PAUSED;
            } else if (RuntimeSchema.flag (scan, "pause_requested")) {
                state = ServiceState.PAUSING;
            } else {
                state = ServiceState.SCANNING;
            }
            var details = scan.has_member ("details") && !scan.get_null_member ("details")
                ? scan.get_object_member ("details") : new Json.Object ();
            message = RuntimeSchema.text (details, "message");
            target = RuntimeSchema.text (details, "target");
            progress = (int) RuntimeSchema.integer (details, "progress", -1).clamp (-1, 100);
            hosts = (int) RuntimeSchema.integer (details, "host_count", -1);
            if (hosts < 0) {
                // "Service scan 2/30: 10.0.0.8" carries the host total.
                try {
                    var re = new Regex ("(\\d+)/(\\d+)");
                    MatchInfo info;
                    if (re.match (message, 0, out info)) {
                        hosts = int.parse (info.fetch (2));
                    }
                } catch (RegexError e) {
                }
            }
            if (hosts >= 0) {
                last_scan_hosts = hosts;
            }
            if (target != "") {
                last_scan_target = target;
            }
        }

        /* GET a JSON object from the engine. `status` is the HTTP status, or 0 when nothing answered.
         * Redirects are not followed (a login redirect is a refusal) and bodies over 2 MiB are dropped. */
        private async Json.Object? fetch (string path, out uint status) {
            status = 0;
            try {
                var request = new Soup.Message ("GET", origin + path);
                request.set_flags (Soup.MessageFlags.NO_REDIRECT);
                request.request_headers.replace ("Accept", "application/json");
                var stream = yield session.send_async (request, Priority.DEFAULT, null);
                status = request.status_code;
                if (status != 200) {
                    yield stream.close_async (Priority.DEFAULT, null);
                    return null;
                }
                var body = new ByteArray ();
                while (true) {
                    var chunk = yield stream.read_bytes_async (65536, Priority.DEFAULT, null);
                    if (chunk.get_size () == 0) {
                        break;
                    }
                    if (body.len + chunk.get_size () > MAX_BODY_BYTES) {
                        yield stream.close_async (Priority.DEFAULT, null);
                        return null;
                    }
                    body.append (chunk.get_data ());
                }
                yield stream.close_async (Priority.DEFAULT, null);
                var parser = new Json.Parser ();
                parser.load_from_data ((string) body.data, (ssize_t) body.len);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                    return null;
                }
                return root.get_object ();
            } catch (Error e) {
                return null;
            }
        }
    }
}
