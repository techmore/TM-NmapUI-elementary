/* Watches the local scanner service over loopback HTTP and drives its systemd user unit.
 * Nothing here talks to the internet: the only peer is http://127.0.0.1:<port>. */
namespace NmapUI {
    public enum ServiceState {
        OFFLINE,
        UNAVAILABLE,
        STARTING,
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
                case IDLE: return "idle";
                case SCANNING: return "scanning";
                case PAUSING: return "starting";
                case PAUSED: return "starting";
                case STOPPING: return "scanning";
                default: return "offline";
            }
        }
    }

    public class Backend : Object {
        public const uint POLL_SECONDS = 4;

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
            var health = yield fetch ("/api/health");
            if (health == null) {
                apply_offline ();
            } else {
                start_requested = false;
                version = RuntimeSchema.text (health, "app_version");
                apply_runtime (yield fetch ("/api/runtime/status"));
            }
            in_flight = false;
            changed ();
            bool was_down = previous == ServiceState.OFFLINE || previous == ServiceState.STARTING;
            bool is_up = state != ServiceState.OFFLINE && state != ServiceState.STARTING;
            if (was_down && is_up) {
                came_online ();
            }
            bool was_scanning = previous == ServiceState.SCANNING || previous == ServiceState.STOPPING
                || previous == ServiceState.PAUSED || previous == ServiceState.PAUSING;
            if (was_scanning && state == ServiceState.IDLE) {
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
            message = "";
            progress = -1;
            hosts = -1;
            target = "";
        }

        private void apply_runtime (Json.Object? runtime) {
            // Health is public, runtime status may fail authentication or become
            // unreadable. Neither case establishes that the scanner is idle.
            if (!RuntimeSchema.valid (runtime)) {
                state = ServiceState.UNAVAILABLE;
                message = _("Cannot read scanner activity; open the scanner to check access and status.");
                progress = -1;
                hosts = -1;
                target = "";
                return;
            }
            Json.Object? scan = null;
            if (runtime != null && runtime.has_member ("active_jobs")) {
                var jobs = runtime.get_array_member ("active_jobs");
                for (uint i = 0; i < jobs.get_length (); i++) {
                    var job = jobs.get_object_element (i);
                    if (job.get_string_member_with_default ("job_type", "") == "scan") {
                        scan = job;
                        break;
                    }
                }
            }
            if (scan == null) {
                state = ServiceState.IDLE;
                message = "";
                progress = -1;
                hosts = -1;
                target = "";
                return;
            }
            state = scan.get_string_member_with_default ("status", "") == "cancelling"
                ? ServiceState.STOPPING : ServiceState.SCANNING;
            if (state != ServiceState.STOPPING && scan.get_boolean_member_with_default ("paused", false)) {
                state = ServiceState.PAUSED;
            } else if (state != ServiceState.STOPPING && scan.get_boolean_member_with_default ("pause_requested", false)) {
                state = ServiceState.PAUSING;
            }
            var details = scan.has_member ("details") && !scan.get_null_member ("details")
                ? scan.get_object_member ("details") : new Json.Object ();
            message = RuntimeSchema.text (details, "message");
            target = RuntimeSchema.text (details, "target");
            progress = details.has_member ("progress") && !details.get_null_member ("progress")
                ? (int) int64.min (100, int64.max (-1, details.get_int_member ("progress"))) : -1;
            progress = int.min (100, int.max (-1, progress));
            hosts = details.has_member ("host_count") && !details.get_null_member ("host_count")
                ? (int) details.get_int_member ("host_count") : -1;
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

        private async Json.Object? fetch (string path) {
            try {
                var request = new Soup.Message ("GET", origin + path);
                request.set_flags (Soup.MessageFlags.NO_REDIRECT);
                var stream = yield session.send_async (request, Priority.DEFAULT, null);
                if (request.status_code != 200) {
                    stream.close (null);
                    return null;
                }
                var body = new ByteArray ();
                while (true) {
                    var chunk = yield stream.read_bytes_async (65536, Priority.DEFAULT, null);
                    if (chunk.get_size () == 0) break;
                    if (body.len + chunk.get_size () > 2 * 1024 * 1024) {
                        stream.close (null);
                        return null;
                    }
                    body.append (chunk.get_data ());
                }
                stream.close (null);
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
