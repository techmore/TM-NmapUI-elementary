/* Network Scanner for elementary OS: a Granite/GTK 4 shell around the local TM-NmapUI service. */
namespace NmapUI {
    public class Application : Gtk.Application {
        public const string ID = "io.github.techmore.NmapUI";
        public const string DEFAULT_ORIGIN = "http://127.0.0.1:9000";
        public const string DEFAULT_UNIT = "nmapui.service";

        public string origin { get; private set; }
        public string unit { get; private set; }
        public Backend backend { get; private set; }

        private MainWindow? window = null;

        public Application () {
            Object (application_id: ID, flags: ApplicationFlags.DEFAULT_FLAGS);
        }

        protected override void startup () {
            base.startup ();
            Granite.init ();

            origin = Environment.get_variable ("NMAPUI_URL") ?? DEFAULT_ORIGIN;
            if (origin.has_suffix ("/")) {
                origin = origin.substring (0, origin.length - 1);
            }
            unit = Environment.get_variable ("NMAPUI_SERVICE") ?? DEFAULT_UNIT;
            backend = new Backend (origin, unit);

            follow_system_color_scheme ();
            install_actions ();
        }

        protected override void activate () {
            if (window == null) {
                window = new MainWindow (this);
                window.close_request.connect (() => {
                    window = null;
                    return false;
                });
            }
            window.present ();
            maybe_schedule_snapshot ();
        }

        /* Debug aid: NMAPUI_SNAPSHOT=/path.png renders the window to a PNG after
         * NMAPUI_SNAPSHOT_DELAY ms (default 4000) and quits. Used by scripts/snapshot.sh. */
        private void maybe_schedule_snapshot () {
            var path = Environment.get_variable ("NMAPUI_SNAPSHOT");
            if (path == null || window == null) {
                return;
            }
            var delay = int.parse (Environment.get_variable ("NMAPUI_SNAPSHOT_DELAY") ?? "4000");
            Timeout.add (delay, () => {
                var target = window;
                var paintable = new Gtk.WidgetPaintable (target);
                var snapshot = new Gtk.Snapshot ();
                paintable.snapshot (snapshot, target.get_width (), target.get_height ());
                var node = snapshot.to_node ();
                var renderer = target.get_native ().get_renderer ();
                if (node == null || renderer == null) {
                    warning ("Nothing to render for the snapshot");
                } else {
                    renderer.render_texture (node, null).save_to_png (path);
                    message ("Snapshot written to %s", path);
                }
                quit ();
                return Source.REMOVE;
            });
        }

        private void follow_system_color_scheme () {
            var granite_settings = Granite.Settings.get_default ();
            var gtk_settings = Gtk.Settings.get_default ();
            var forced = Environment.get_variable ("NMAPUI_FORCE_DARK");
            if (forced != null) {
                gtk_settings.gtk_application_prefer_dark_theme = forced == "1";
                return;
            }
            gtk_settings.gtk_application_prefer_dark_theme =
                granite_settings.prefers_color_scheme == Granite.Settings.ColorScheme.DARK;
            granite_settings.notify["prefers-color-scheme"].connect (() => {
                gtk_settings.gtk_application_prefer_dark_theme =
                    granite_settings.prefers_color_scheme == Granite.Settings.ColorScheme.DARK;
            });
        }

        private void install_actions () {
            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (this.quit);
            add_action (quit);
            set_accels_for_action ("app.quit", { "<Control>q" });

            var start = new SimpleAction ("start-service", null);
            start.activate.connect (() => backend.start_service ());
            add_action (start);

            var restart = new SimpleAction ("restart-service", null);
            restart.activate.connect (() => backend.restart_service ());
            add_action (restart);

            var about = new SimpleAction ("about", null);
            about.activate.connect (show_about);
            add_action (about);

            // Window-scoped actions get their accelerators here so they show in menus.
            set_accels_for_action ("win.reload", { "<Control>r", "F5" });
            set_accels_for_action ("win.open-browser", { "<Control><Shift>o" });
            set_accels_for_action ("win.zoom-in", { "<Control>plus", "<Control>equal" });
            set_accels_for_action ("win.zoom-out", { "<Control>minus" });
            set_accels_for_action ("win.zoom-reset", { "<Control>0" });
            set_accels_for_action ("win.find", { "<Control>f" });
            for (int i = 0; i < MainWindow.TABS.length; i++) {
                set_accels_for_action ("win.tab::" + MainWindow.TABS[i], { "<Control>%d".printf (i + 1) });
            }
        }

        private void show_about () {
            var dialog = new Gtk.AboutDialog () {
                transient_for = window,
                modal = true,
                program_name = _("Network Scanner"),
                logo_icon_name = ID,
                version = backend.version != "" ? backend.version : VERSION,
                comments = _("Scan and monitor your networks with Nmap. The scanner engine is TM-NmapUI, running as a per-user loopback service."),
                website = "https://github.com/techmore/TM-NmapUI-elementary",
                website_label = _("Source on GitHub"),
                copyright = "© Techmore"
            };
            dialog.present ();
        }

        public static int main (string[] args) {
            Intl.setlocale (LocaleCategory.ALL, "");
            return new Application ().run (args);
        }
    }
}
