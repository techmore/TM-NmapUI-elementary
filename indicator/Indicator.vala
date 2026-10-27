/* Network Scanner indicator for Pantheon's Wingpanel.
 * The panel shows one symbolic icon whose shape follows the scanner state; the popover is a plain
 * elementary menu: a header with the state, scan progress when scanning, any alerts, a short
 * summary and menu items. Data comes from ~/.local/bin/nmapui-summary (loopback scanner API only). */
using GLib;
using Gtk;
using Json;
using Wingpanel;

namespace MSeries {
    public class NmapUIIndicator : Wingpanel.Indicator {
        private const string APP_ID = "io.github.techmore.NmapUI";
        private const string ICON_IDLE = "mseries-nmapui-radar-idle-symbolic";
        private const string ICON_SCANNING = "mseries-nmapui-radar-symbolic";
        private const string ICON_ATTENTION = "mseries-nmapui-radar-attention-symbolic";
        // Poll slowly in the background and quickly only while someone is looking.
        private const uint POLL_CLOSED_SECONDS = 30;
        private const uint POLL_OPEN_SECONDS = 3;

        private Gtk.Image panel_icon;
        private Gtk.Box menu;
        private Granite.HeaderLabel header;
        private Gtk.ProgressBar progress;
        private Gtk.Label progress_detail;
        private Gtk.Box alert_box;
        private Gtk.Separator summary_separator;
        private Gtk.Label devices_label;
        private Gtk.Label network_label;
        private Gtk.Label last_scan_label;
        private Gtk.Button start_service_button;
        private string helper;
        private bool in_flight = false;
        private bool is_open = false;
        private uint poll_source = 0;
        private string last_json = "";
        private DBusConnection? bus = null;

        public NmapUIIndicator () {
            GLib.Object (code_name: "nmapui");
        }

        construct {
            helper = GLib.Path.build_filename (Environment.get_home_dir (), ".local", "bin", "nmapui-summary");

            panel_icon = new Gtk.Image.from_icon_name (ICON_IDLE);
            update_panel (ICON_IDLE, false, _("Network Scanner"), _("Loading…"));
            this.visible = true;

            menu = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_top = 3, margin_bottom = 3, width_request = 280 };

            header = new Granite.HeaderLabel (_("Network Scanner")) {
                secondary_text = _("Loading…"), size = Granite.HeaderLabel.Size.H4,
                margin_top = 3, margin_bottom = 3
            };
            menu.append (header);

            progress = new Gtk.ProgressBar () { margin_start = 12, margin_end = 12, margin_top = 3, visible = false };
            progress.update_property (Gtk.AccessibleProperty.LABEL, _("Scan progress"), -1);
            progress_detail = dim_label ();
            progress_detail.margin_top = 6;
            progress_detail.margin_bottom = 6;
            menu.append (progress);
            menu.append (progress_detail);

            alert_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { visible = false };
            menu.append (alert_box);

            summary_separator = separator ();
            menu.append (summary_separator);
            // Read-only facts are dimmed so the menu items below stay the obvious things to click.
            devices_label = info_label ();
            network_label = info_label ();
            last_scan_label = info_label ();
            foreach (var l in new Gtk.Label[] { devices_label, network_label, last_scan_label }) l.add_css_class (Granite.CssClass.DIM);
            menu.append (devices_label);
            menu.append (network_label);
            menu.append (last_scan_label);

            menu.append (separator ());
            start_service_button = menu_item (_("Start Scanner Service"));
            start_service_button.visible = false;
            start_service_button.clicked.connect (start_service);
            menu.append (start_service_button);
            var open_button = menu_item (_("Open Network Scanner"));
            open_button.clicked.connect (open_app);
            menu.append (open_button);

            try {
                bus = Bus.get_sync (BusType.SESSION);
            } catch (Error e) {
                bus = null;
            }
            refresh ();
            schedule_poll ();
        }

        ~NmapUIIndicator () {
            if (poll_source != 0) Source.remove (poll_source);
        }

        private static Gtk.Separator separator () {
            return new Gtk.Separator (Gtk.Orientation.HORIZONTAL) { margin_top = 3, margin_bottom = 3 };
        }

        /* Read-only line in the summary block, aligned with menu item text. */
        private static Gtk.Label info_label () {
            var label = new Gtk.Label ("") {
                xalign = 0, ellipsize = Pango.EllipsizeMode.END, visible = false,
                margin_start = 12, margin_end = 12, margin_top = 3, margin_bottom = 3, selectable = false
            };
            return label;
        }

        private static Gtk.Label dim_label () {
            var label = info_label ();
            label.add_css_class (Granite.CssClass.DIM);
            label.add_css_class (Granite.CssClass.SMALL);
            label.add_css_class (Granite.CssClass.NUMERIC);
            return label;
        }

        private static Gtk.Button menu_item (string text) {
            var button = new Gtk.Button () { child = new Gtk.Label (text) { xalign = 0 } };
            button.add_css_class ("menuitem");
            return button;
        }

        private void schedule_poll () {
            if (poll_source != 0) Source.remove (poll_source);
            poll_source = Timeout.add_seconds (is_open ? POLL_OPEN_SECONDS : POLL_CLOSED_SECONDS, () => {
                refresh ();
                return Source.CONTINUE;
            });
        }

        private void update_panel (string icon, bool dim, string title, string detail) {
            panel_icon.icon_name = icon;
            if (dim) panel_icon.add_css_class (Granite.CssClass.DIM); else panel_icon.remove_css_class (Granite.CssClass.DIM);
            panel_icon.tooltip_markup = "%s\n%s".printf (Markup.escape_text (title),
                Granite.TOOLTIP_SECONDARY_TEXT_MARKUP.printf (Markup.escape_text (detail)));
            panel_icon.update_property (Gtk.AccessibleProperty.LABEL, "%s: %s".printf (title, detail), -1);
        }

        /* Dock badge and progress through the Unity LauncherEntry protocol the elementary dock reads. */
        private void update_launcher (bool scanning, double fraction, int64 alerts) {
            if (bus == null) return;
            var props = new VariantBuilder (new VariantType ("a{sv}"));
            props.add ("{sv}", "progress-visible", new Variant.boolean (scanning));
            props.add ("{sv}", "progress", new Variant.double (fraction));
            props.add ("{sv}", "count-visible", new Variant.boolean (!scanning && alerts > 0));
            props.add ("{sv}", "count", new Variant.int64 (alerts));
            try {
                bus.emit_signal (null, "/com/canonical/unity/launcherentry/nmapui", "com.canonical.Unity.LauncherEntry",
                                 "Update", new Variant ("(sa{sv})", "application://" + APP_ID + ".desktop", props));
            } catch (Error e) {
                warning ("Could not update the dock entry: %s", e.message);
            }
        }

        private void open_app () {
            close ();
            var info = new DesktopAppInfo (APP_ID + ".desktop");
            try {
                if (info != null) {
                    info.launch (null, menu.get_display ().get_app_launch_context ());
                } else {
                    Process.spawn_command_line_async (APP_ID);
                }
            } catch (Error e) {
                warning ("Could not open Network Scanner: %s", e.message);
            }
        }

        private void start_service () {
            start_service_button.sensitive = false;
            header.secondary_text = _("Starting…");
            try {
                var process = new Subprocess (SubprocessFlags.NONE, "systemctl", "--user", "start", "nmapui.service");
                process.wait_async.begin (null, () => {
                    start_service_button.sensitive = true;
                    last_json = "";
                    refresh ();
                });
            } catch (Error e) {
                start_service_button.sensitive = true;
                warning ("Could not start the scanner service: %s", e.message);
            }
        }

        private void refresh () {
            if (in_flight) return;
            in_flight = true;
            try {
                var process = new Subprocess (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE, helper);
                process.communicate_utf8_async.begin (null, null, (obj, res) => {
                    in_flight = false;
                    try {
                        string? out_text;
                        process.communicate_utf8_async.end (res, out out_text, null);
                        apply (out_text ?? "");
                    } catch (Error e) {
                        apply ("");
                    }
                });
            } catch (Error e) {
                in_flight = false;
                apply ("");
            }
        }

        private static string relative (string iso) {
            var then = new DateTime.from_iso8601 (iso, new TimeZone.utc ());
            if (then == null) return iso;
            var seconds = new DateTime.now_utc ().difference (then) / TimeSpan.SECOND;
            if (seconds < 90) return _("just now");
            if (seconds < 5400) return ngettext ("%d minute ago", "%d minutes ago", (ulong) (seconds / 60)).printf ((int) (seconds / 60));
            if (seconds < 129600) return ngettext ("%d hour ago", "%d hours ago", (ulong) (seconds / 3600)).printf ((int) (seconds / 3600));
            return ngettext ("%d day ago", "%d days ago", (ulong) (seconds / 86400)).printf ((int) (seconds / 86400));
        }

        private static string duration (int64 sec) {
            if (sec < 60) return _("under a minute");
            if (sec < 3600) return ngettext ("%d minute", "%d minutes", (ulong) (sec / 60)).printf ((int) (sec / 60));
            return _("%d h %d min").printf ((int) (sec / 3600), (int) ((sec % 3600) / 60));
        }

        private static string str (Json.Object o, string key) {
            return o.has_member (key) && !o.get_null_member (key) ? o.get_string_member (key) : "";
        }

        private static bool has (Json.Object o, string key) {
            return o.has_member (key) && !o.get_null_member (key);
        }

        private void set_info (Gtk.Label label, string text) {
            label.label = text;
            label.visible = text != "";
        }

        private void apply (string text) {
            if (text == last_json && text != "") return;
            last_json = text;
            Json.Object? data = null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (text);
                var root = parser.get_root ();
                if (root != null && root.get_node_type () == Json.NodeType.OBJECT) data = root.get_object ();
            } catch (Error e) {}

            string state = data != null ? (str (data, "state") != "" ? str (data, "state") : "offline") : "offline";
            bool scanning = state == "scanning" || state == "stopping";
            bool offline = data == null || state == "offline";

            // Header: one calm sentence about where things stand.
            string status;
            if (data == null) status = _("Status unavailable");
            else if (offline) status = _("Scanner service is not running");
            else if (state == "stopping") status = _("Stopping scan…");
            else if (scanning) status = _("Scanning…");
            else if (state == "attention") status = _("Needs attention");
            else status = _("Up to date");
            header.secondary_text = status;
            start_service_button.visible = data != null && offline;

            // Scan progress.
            progress.visible = scanning && has (data, "progress");
            if (progress.visible) progress.fraction = (double) data.get_int_member ("progress") / 100.0;
            string detail = "";
            if (scanning && has (data, "scan")) {
                var scan = data.get_object_member ("scan");
                var parts = new string[] {};
                if (str (scan, "target") != "") parts += str (scan, "target");
                if (has (scan, "index") && has (scan, "total"))
                    parts += _("host %d of %d").printf ((int) scan.get_int_member ("index"), (int) scan.get_int_member ("total"));
                if (has (scan, "elapsed_seconds")) parts += duration (scan.get_int_member ("elapsed_seconds"));
                detail = string.joinv (" · ", parts);
            }
            set_info (progress_detail, detail);

            // Alerts: plain rows with a symbolic icon, no tinted boxes.
            Gtk.Widget? child;
            while ((child = alert_box.get_first_child ()) != null) alert_box.remove (child);
            int64 alert_count = 0;
            if (data != null && has (data, "alerts")) {
                var alerts = data.get_array_member ("alerts");
                alert_count = alerts.get_length ();
                for (uint i = 0; i < alerts.get_length (); i++) {
                    string text_i = alerts.get_string_element (i);
                    bool critical = text_i.down ().contains ("critical");
                    var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
                        margin_start = 12, margin_end = 12, margin_top = 3, margin_bottom = 3
                    };
                    var icon = new Gtk.Image.from_icon_name (critical ? "dialog-warning-symbolic" : "dialog-information-symbolic") {
                        valign = Gtk.Align.START
                    };
                    icon.add_css_class (critical ? Granite.CssClass.WARNING : Granite.CssClass.DIM);
                    row.append (icon);
                    row.append (new Gtk.Label (text_i) { xalign = 0, wrap = true, hexpand = true });
                    alert_box.append (row);
                }
            }
            alert_box.visible = alert_count > 0;

            // Summary: devices, network and last scan, as plain sentences.
            string devices = "";
            string network = "";
            string last = "";
            if (data != null && !offline) {
                if (has (data, "hosts")) {
                    int64 hosts = data.get_int_member ("hosts");
                    devices = ngettext ("%d device", "%d devices", (ulong) hosts).printf ((int) hosts);
                    if (has (data, "changes") && data.get_int_member ("changes") > 0) {
                        int64 changes = data.get_int_member ("changes");
                        devices += " · " + ngettext ("%d change", "%d changes", (ulong) changes).printf ((int) changes);
                    }
                }
                if (has (data, "network")) {
                    var net = data.get_object_member ("network");
                    string where = str (net, "ssid") != "" ? str (net, "ssid") : str (net, "interface");
                    string addr = str (net, "address");
                    network = where == "" ? _("Not connected") : (addr != "" ? "%s · %s".printf (where, addr) : where);
                }
                if (!scanning) {
                    string when = str (data, "last_scan");
                    string customer = str (data, "last_customer");
                    if (when == "") last = _("No scans yet");
                    else if (customer != "") last = _("Last scan %s · %s").printf (relative (when), customer);
                    else last = _("Last scan %s").printf (relative (when));
                    if (str (data, "monitor") != "") last += " · " + _("next at %s").printf (str (data, "monitor"));
                }
            }
            set_info (devices_label, devices);
            set_info (network_label, network);
            set_info (last_scan_label, last);
            network_label.add_css_class (Granite.CssClass.NUMERIC);
            summary_separator.visible = devices != "" || network != "" || last != "";

            // Panel icon: shape carries the state; the dock carries progress and the alert count.
            string icon = scanning ? ICON_SCANNING : (state == "attention" ? ICON_ATTENTION : ICON_IDLE);
            update_panel (icon, offline, _("Network Scanner"), status);
            update_launcher (scanning, progress.visible ? progress.fraction : 0.0, alert_count);
        }

        public override Gtk.Widget get_display_widget () {
            return panel_icon;
        }

        public override Gtk.Widget? get_widget () {
            return menu;
        }

        public override void opened () {
            is_open = true;
            refresh ();
            schedule_poll ();
        }

        public override void closed () {
            is_open = false;
            schedule_poll ();
        }
    }
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.ServerType server_type) {
    if (server_type != Wingpanel.ServerType.SESSION) return null;
    return new MSeries.NmapUIIndicator ();
}
