/* The main window: native headerbar with linked tabs and a quiet activity button (only while
 * something is happening), a WebKit view of the scanner UI, and a Granite placeholder when the
 * service is down. */
namespace NmapUI {
    public class MainWindow : Gtk.ApplicationWindow {
        public const string[] TABS = { "dashboard", "history", "reports", "customers", "logs", "settings" };
        private const string[] TAB_LABELS = { N_("Dashboard"), N_("History"), N_("Reports"), N_("Customers"), N_("Logs"), N_("Settings") };

        private const string PAGE_CSS = """
            html #scanner-header { display: none !important; }
            html .mb-6.rounded-2xl.border.p-2 { display: none !important; }
            html body { padding-top: 16px !important; }
        """;

        // Only the thin page-load bar needs styling; everything else is stock Granite.
        private const string CHROME_CSS = """
            .nmapui-load { min-height: 2px; margin: 0; }
            .nmapui-load trough { min-height: 2px; background: transparent; border: none; }
            .nmapui-load progress { min-height: 2px; border: none; }
        """;

        private unowned Application app;
        private Backend backend;

        private WebKit.NetworkSession network_session;
        private WebKit.WebView web;
        private Gtk.Stack stack;
        private Gtk.Overlay overlay;
        private Gtk.ProgressBar load_bar;
        private Gtk.Box tabs;
        private Gtk.Button status_chip;
        private Gtk.Label status_label;
        private Gtk.Spinner status_spinner;
        private Gtk.Button reload_button;
        private Gtk.ToggleButton[] tab_buttons = {};
        private Granite.Placeholder offline_page;
        private Gtk.Button offline_start_button;
        private Gtk.Label starting_label;
        private Granite.Toast toast;
        private string? last_download_path = null;
        private bool syncing_tabs = false;
        private bool ever_loaded = false;
        private int unread_scan_results = 0;

        public MainWindow (Application app) {
            Object (application: app, title: _("Network Scanner"), icon_name: Application.ID);
            this.app = app;
            backend = app.backend;
            install_chrome_css ();
            restore_geometry ();

            build_web_view ();
            build_header ();
            build_pages ();
            install_actions ();

            backend.changed.connect (on_backend_changed);
            backend.came_online.connect (on_backend_online);
            backend.scan_finished.connect (on_scan_finished);
            close_request.connect (() => {
                save_geometry ();
                return false;
            });
            notify["is-active"].connect (() => {
                if (is_active) {
                    unread_scan_results = 0;
                    application.withdraw_notification ("scan-finished");
                }
            });

            on_backend_changed ();
            web.load_uri (((Application) application).origin + "/");
        }

        // --- Construction -------------------------------------------------------------------

        private static void install_chrome_css () {
            var provider = new Gtk.CssProvider ();
            provider.load_from_string (CHROME_CSS);
            Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider,
                                                       Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private void build_web_view () {
            var data_dir = Path.build_filename (Environment.get_user_data_dir (), "nmapui-elementary");
            var cache_dir = Path.build_filename (Environment.get_user_cache_dir (), "nmapui-elementary");
            DirUtils.create_with_parents (data_dir, 0700);
            DirUtils.create_with_parents (cache_dir, 0700);
            network_session = new WebKit.NetworkSession (data_dir, cache_dir);
            network_session.get_cookie_manager ().set_persistent_storage (
                Path.build_filename (data_dir, "cookies.sqlite"), WebKit.CookiePersistentStorage.SQLITE);
            network_session.download_started.connect (on_download_started);

            web = (WebKit.WebView) Object.new (typeof (WebKit.WebView), "network-session", network_session);
            var settings = web.get_settings ();
            settings.enable_developer_extras = Environment.get_variable ("NMAPUI_DEVTOOLS") != null;
            settings.enable_back_forward_navigation_gestures = false;
            web.get_user_content_manager ().add_style_sheet (new WebKit.UserStyleSheet (
                PAGE_CSS, WebKit.UserContentInjectedFrames.TOP_FRAME, WebKit.UserStyleLevel.USER, null, null));
            web.hexpand = true;
            web.vexpand = true;

            web.load_failed.connect (on_load_failed);
            web.load_changed.connect (on_load_changed);
            web.notify["estimated-load-progress"].connect (() => {
                load_bar.fraction = web.estimated_load_progress;
                load_bar.visible = web.estimated_load_progress < 1.0;
            });
            web.notify["uri"].connect (sync_tabs_from_uri);
            web.create.connect (on_create_popup);
            web.decide_policy.connect (on_decide_policy);
        }

        private void build_header () {
            var header = new Gtk.HeaderBar ();

            reload_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic") {
                tooltip_markup = Granite.markup_accel_tooltip ({ "<Control>r" }, _("Reload")),
                action_name = "win.reload"
            };
            header.pack_start (reload_button);

            tabs = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { valign = Gtk.Align.CENTER };
            tabs.add_css_class ("linked");
            Gtk.ToggleButton? first = null;
            for (int i = 0; i < TABS.length; i++) {
                var button = new Gtk.ToggleButton.with_label (_(TAB_LABELS[i])) {
                    tooltip_markup = Granite.markup_accel_tooltip ({ "<Control>%d".printf (i + 1) }, _(TAB_LABELS[i]))
                };
                if (first == null) {
                    first = button;
                } else {
                    button.set_group (first);
                }
                var name = TABS[i];
                button.toggled.connect (() => {
                    if (button.active && !syncing_tabs) {
                        show_tab (name);
                    }
                });
                tabs.append (button);
                tab_buttons += button;
            }
            tab_buttons[0].active = true;
            header.title_widget = tabs;

            var menu = new Menu ();
            var service_section = new Menu ();
            service_section.append (_("Start Scanner Service"), "app.start-service");
            service_section.append (_("Restart Scanner Service"), "app.restart-service");
            menu.append_section (null, service_section);
            var view_section = new Menu ();
            view_section.append (_("Zoom In"), "win.zoom-in");
            view_section.append (_("Zoom Out"), "win.zoom-out");
            view_section.append (_("Actual Size"), "win.zoom-reset");
            menu.append_section (null, view_section);
            var open_section = new Menu ();
            open_section.append (_("Open in Browser"), "win.open-browser");
            open_section.append (_("Open Downloads Folder"), "win.open-downloads");
            open_section.append (_("Open Scanner Data Folder"), "win.open-data");
            menu.append_section (null, open_section);
            var about_section = new Menu ();
            about_section.append (_("About Network Scanner"), "app.about");
            about_section.append (_("Quit"), "app.quit");
            menu.append_section (null, about_section);

            var menu_button = new Gtk.MenuButton () {
                icon_name = "open-menu",
                tooltip_text = _("Menu"),
                menu_model = menu,
                primary = true
            };
            header.pack_end (menu_button);

            // Activity: a flat button that appears only while a scan runs or the service starts.
            var chip_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            status_spinner = new Gtk.Spinner ();
            status_label = new Gtk.Label ("");
            status_label.add_css_class (Granite.CssClass.NUMERIC);
            chip_box.append (status_spinner);
            chip_box.append (status_label);
            status_chip = new Gtk.Button () { child = chip_box, valign = Gtk.Align.CENTER, visible = false };
            status_chip.add_css_class ("flat");
            status_chip.clicked.connect (() => tab_buttons[0].active = true);
            header.pack_end (status_chip);

            set_titlebar (header);
        }

        private void build_pages () {
            stack = new Gtk.Stack () {
                transition_type = Gtk.StackTransitionType.CROSSFADE,
                hexpand = true,
                vexpand = true
            };

            load_bar = new Gtk.ProgressBar () { valign = Gtk.Align.START, visible = false };
            load_bar.add_css_class ("nmapui-load");
            load_bar.add_css_class ("osd");
            var web_overlay = new Gtk.Overlay () { child = web };
            web_overlay.add_overlay (load_bar);
            stack.add_named (web_overlay, "web");

            offline_page = new Granite.Placeholder (_("Scanner Service Isn’t Running")) {
                description = _("Network Scanner uses a private scanner that runs on this computer for your account only. Start it to continue."),
                icon = new ThemedIcon ("network-offline"),
                halign = Gtk.Align.CENTER,
                valign = Gtk.Align.CENTER
            };
            offline_start_button = offline_page.append_button (new ThemedIcon ("media-playback-start"),
                _("Start Scanner Service"), _("Starts now and keeps running while you’re logged in"));
            offline_start_button.clicked.connect (() => backend.start_service ());
            var setup_button = offline_page.append_button (new ThemedIcon ("help-contents"),
                _("Set Up the Scanner"), _("Opens the install guide in your web browser"));
            setup_button.clicked.connect (() => {
                new Gtk.UriLauncher ("https://github.com/techmore/TM-NmapUI-elementary#install").launch.begin (this, null);
            });
            stack.add_named (offline_page, "offline");

            var starting_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
                halign = Gtk.Align.CENTER,
                valign = Gtk.Align.CENTER
            };
            var starting_spinner = new Gtk.Spinner () { spinning = true, width_request = 32, height_request = 32 };
            starting_label = new Gtk.Label (_("Starting the scanner service…"));
            starting_label.add_css_class (Granite.HeaderLabel.Size.H3.to_string ());
            var starting_hint = new Gtk.Label (_("This usually takes a few seconds."));
            starting_hint.add_css_class (Granite.CssClass.DIM);
            starting_box.append (starting_spinner);
            starting_box.append (starting_label);
            starting_box.append (starting_hint);
            stack.add_named (starting_box, "starting");

            toast = new Granite.Toast ("");
            toast.set_default_action (_("Open"));
            toast.default_action.connect (() => {
                if (last_download_path != null) {
                    new Gtk.FileLauncher (File.new_for_path (last_download_path)).launch.begin (this, null);
                }
            });
            overlay = new Gtk.Overlay () { child = stack };
            overlay.add_overlay (toast);
            child = overlay;
        }

        private void install_actions () {
            add_simple_action ("reload", () => {
                if (stack.visible_child_name == "web") {
                    web.reload ();
                } else {
                    backend.poll.begin ();
                }
            });
            add_simple_action ("open-browser", () => {
                new Gtk.UriLauncher (((Application) application).origin + "/").launch.begin (this, null);
            });
            add_simple_action ("open-downloads", () => {
                new Gtk.FileLauncher (File.new_for_path (downloads_dir ())).launch.begin (this, null);
            });
            add_simple_action ("open-data", () => {
                var dir = Path.build_filename (Environment.get_user_data_dir (), "nmapui");
                new Gtk.FileLauncher (File.new_for_path (dir)).launch.begin (this, null);
            });
            add_simple_action ("zoom-in", () => web.zoom_level = double.min (3.0, web.zoom_level + 0.1));
            add_simple_action ("zoom-out", () => web.zoom_level = double.max (0.5, web.zoom_level - 0.1));
            add_simple_action ("zoom-reset", () => web.zoom_level = 1.0);
            add_simple_action ("find", () => {
                // The scanner UI has its own filters; hand Ctrl+F to the page's log/host search when present.
                web.evaluate_javascript.begin ("(document.querySelector('input[type=search]')||document.querySelector('#log-search'))?.focus()", -1, null, null, null);
            });
            var tab = new SimpleAction ("tab", VariantType.STRING);
            tab.activate.connect ((parameter) => {
                var name = parameter.get_string ();
                for (int i = 0; i < TABS.length; i++) {
                    if (TABS[i] == name) {
                        tab_buttons[i].active = true;
                    }
                }
            });
            add_action (tab);
        }

        private delegate void ActionCallback ();

        private void add_simple_action (string name, owned ActionCallback callback) {
            var action = new SimpleAction (name, null);
            action.activate.connect (() => callback ());
            add_action (action);
        }

        // --- Tabs -------------------------------------------------------------------------

        private void show_tab (string name) {
            if (stack == null || stack.visible_child_name != "web") {
                return;
            }
            var script = "if (window.location.hash !== '#%s') { window.location.hash = '#%s'; }".printf (name, name);
            web.evaluate_javascript.begin (script, -1, null, null, null);
        }

        private void sync_tabs_from_uri () {
            var uri = web.uri ?? "";
            var hash = uri.index_of_char ('#');
            var fragment = hash >= 0 ? uri.substring (hash + 1) : "dashboard";
            for (int i = 0; i < TABS.length; i++) {
                if (TABS[i] == fragment && !tab_buttons[i].active) {
                    syncing_tabs = true;
                    tab_buttons[i].active = true;
                    syncing_tabs = false;
                }
            }
        }

        // --- Backend state --------------------------------------------------------------------

        private void on_backend_changed () {
            bool busy = backend.state == ServiceState.SCANNING
                || backend.state == ServiceState.STOPPING || backend.state == ServiceState.STARTING;
            status_chip.visible = busy;
            status_spinner.spinning = busy;

            string text = backend.state.label ();
            string tooltip = text;
            switch (backend.state) {
                case ServiceState.SCANNING:
                case ServiceState.STOPPING:
                    if (backend.progress >= 0) {
                        text = "%s · %d%%".printf (text, backend.progress);
                    }
                    tooltip = backend.message != "" ? backend.message : text;
                    if (backend.target != "") {
                        tooltip = "%s\n%s".printf (tooltip, backend.target);
                    }
                    break;
                case ServiceState.IDLE:
                    tooltip = backend.version != ""
                        ? _("Scanner service %s is running on %s").printf (backend.version, ((Application) application).origin)
                        : text;
                    break;
                default:
                    break;
            }
            status_label.label = text;
            status_chip.tooltip_text = tooltip;
            status_chip.update_property (Gtk.AccessibleProperty.LABEL, text, -1);

            if (backend.state == ServiceState.STARTING) {
                stack.visible_child_name = "starting";
            } else if (backend.state == ServiceState.OFFLINE) {
                offline_start_button.sensitive = backend.unit_installed ();
                offline_start_button.tooltip_text = offline_start_button.sensitive ? ""
                    : _("No %s user unit is installed; run scripts/install-backend.sh first").printf (backend.unit);
                stack.visible_child_name = "offline";
            } else if (stack.visible_child_name != "web" && ever_loaded) {
                stack.visible_child_name = "web";
            }
            reload_button.sensitive = backend.state != ServiceState.STARTING;
            // Tabs only mean something while the scanner page is showing.
            tabs.sensitive = stack.visible_child_name == "web";
        }

        private void on_backend_online () {
            if (!ever_loaded || stack.visible_child_name != "web") {
                web.load_uri (((Application) application).origin + "/");
            }
        }

        private void on_scan_finished (int hosts, string target) {
            if (is_active) {
                return;
            }
            unread_scan_results++;
            var notification = new Notification (_("Scan finished"));
            string body = target != "" ? _("Target %s").printf (target) : _("Network scan");
            if (hosts >= 0) {
                body = ngettext ("%s · %d host", "%s · %d hosts", hosts).printf (body, hosts);
            }
            notification.set_body (body);
            notification.set_icon (new ThemedIcon (Application.ID));
            notification.set_default_action ("app.activate");
            application.send_notification ("scan-finished", notification);
        }

        // --- WebKit -----------------------------------------------------------------------------

        private void on_load_changed (WebKit.LoadEvent event) {
            if (event == WebKit.LoadEvent.FINISHED) {
                ever_loaded = true;
                if (backend.state != ServiceState.OFFLINE && backend.state != ServiceState.STARTING) {
                    stack.visible_child_name = "web";
                }
                sync_tabs_from_uri ();
            }
        }

        private bool on_load_failed (WebKit.LoadEvent event, string uri, Error error) {
            if (error.matches (WebKit.NetworkError.quark (), WebKit.NetworkError.CANCELLED)) {
                return false;
            }
            backend.poll.begin ();
            if (backend.state == ServiceState.OFFLINE || !ever_loaded) {
                stack.visible_child_name = backend.state == ServiceState.STARTING ? "starting" : "offline";
            }
            return true;
        }

        private Gtk.Widget on_create_popup (WebKit.NavigationAction action) {
            // Google Drive sign-in opens a popup; give it a plain window of its own.
            var view = (WebKit.WebView) Object.new (typeof (WebKit.WebView), "related-view", web);
            var popup = new Gtk.Window () {
                title = _("Sign In"),
                transient_for = this,
                default_width = 720,
                default_height = 760,
                child = view
            };
            view.close.connect (popup.destroy);
            view.ready_to_show.connect (popup.present);
            return view;
        }

        private bool on_decide_policy (WebKit.PolicyDecision decision, WebKit.PolicyDecisionType type) {
            if (type != WebKit.PolicyDecisionType.NAVIGATION_ACTION) {
                return false;
            }
            var navigation = (WebKit.NavigationPolicyDecision) decision;
            var request = navigation.get_navigation_action ().get_request ();
            var uri = request.get_uri ();
            // Keep the scanner inside the window; anything else (GitHub, docs) goes to the user's browser.
            if (uri.has_prefix (((Application) application).origin) || uri.has_prefix ("about:") || uri.has_prefix ("data:")) {
                return false;
            }
            if (navigation.get_navigation_action ().get_navigation_type () == WebKit.NavigationType.LINK_CLICKED) {
                decision.ignore ();
                new Gtk.UriLauncher (uri).launch.begin (this, null);
                return true;
            }
            return false;
        }

        private void on_download_started (WebKit.Download download) {
            download.decide_destination.connect ((suggested) => {
                var dir = downloads_dir ();
                DirUtils.create_with_parents (dir, 0755);
                var name = Path.get_basename (suggested != "" ? suggested : "nmapui-report");
                var path = Path.build_filename (dir, name);
                int counter = 1;
                while (FileUtils.test (path, FileTest.EXISTS)) {
                    var dot = name.last_index_of_char ('.');
                    var stem = dot > 0 ? name.substring (0, dot) : name;
                    var ext = dot > 0 ? name.substring (dot) : "";
                    path = Path.build_filename (dir, "%s (%d)%s".printf (stem, counter++, ext));
                }
                download.set_destination (path);
                return true;
            });
            download.finished.connect (() => {
                last_download_path = download.destination;
                toast.title = _("Saved %s to Downloads").printf (Path.get_basename (download.destination ?? ""));
                toast.send_notification ();
            });
            download.failed.connect ((error) => {
                toast.title = _("Download failed: %s").printf (error.message);
                toast.send_notification ();
            });
        }

        private static string downloads_dir () {
            return Environment.get_user_special_dir (UserDirectory.DOWNLOAD)
                ?? Path.build_filename (Environment.get_home_dir (), "Downloads");
        }

        // --- Window geometry --------------------------------------------------------------------

        private static string state_path () {
            var dir = Path.build_filename (Environment.get_user_config_dir (), "nmapui-elementary");
            DirUtils.create_with_parents (dir, 0700);
            return Path.build_filename (dir, "state.ini");
        }

        private void restore_geometry () {
            int width = 1280, height = 860;
            bool maximized = false;
            var keyfile = new KeyFile ();
            try {
                keyfile.load_from_file (state_path (), KeyFileFlags.NONE);
                width = keyfile.get_integer ("window", "width");
                height = keyfile.get_integer ("window", "height");
                maximized = keyfile.get_boolean ("window", "maximized");
            } catch (Error e) {
            }
            set_default_size (int.max (640, width), int.max (480, height));
            if (maximized) {
                maximize ();
            }
        }

        private void save_geometry () {
            var keyfile = new KeyFile ();
            int width, height;
            get_default_size (out width, out height);
            keyfile.set_integer ("window", "width", width);
            keyfile.set_integer ("window", "height", height);
            keyfile.set_boolean ("window", "maximized", maximized);
            try {
                keyfile.save_to_file (state_path ());
            } catch (Error e) {
                warning ("Could not save window state: %s", e.message);
            }
        }
    }
}
