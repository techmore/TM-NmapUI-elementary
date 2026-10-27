/* Headless render probe: loads the real NmapUI indicator and writes the panel item + popover to a PNG.
 * Usage: render-probe OUT.png [delay-ms]   (run under Xvfb with a fake HOME; see run-probe.sh) */
bool render_failed = false;

int main (string[] args) {
    if (args.length < 2) {
        stderr.printf ("usage: render-probe OUT.png [delay-ms]\n");
        return 2;
    }
    Gtk.init ();
    Granite.init ();
    var delay = args.length > 2 ? int.parse (args[2]) : 1500;
    var icons = Environment.get_variable ("NMAPUI_ICONS");
    if (icons != null) Gtk.IconTheme.get_for_display (Gdk.Display.get_default ()).add_search_path (icons);
    var dark = Environment.get_variable ("NMAPUI_PROBE_DARK") == "1";
    Gtk.Settings.get_default ().gtk_application_prefer_dark_theme = dark;
    var indicator = new MSeries.NmapUIIndicator ();
    // Panel strip, then the indicator body inside a real popover so the stylesheet's popover rules apply.
    var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { height_request = 28, margin_start = 8, margin_end = 8 };
    bar.add_css_class ("background");
    bar.append (indicator.get_display_widget ());
    var popover = new Gtk.Popover () { child = indicator.get_widget (), autohide = false, has_arrow = true };
    var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { width_request = 320, height_request = 520 };
    root.add_css_class (dark ? "background" : "background");
    root.append (bar);
    popover.set_parent (bar.get_first_child ());
    var window = new Gtk.Window () { child = root, decorated = false };
    window.present ();
    popover.popup ();

    var loop = new MainLoop ();
    Timeout.add (delay, () => {
        int min, nat;
        popover.measure (Gtk.Orientation.VERTICAL, 320, out min, out nat, null, null);
        root.height_request = nat + 40;
        Timeout.add (900, () => {
            // Panel strip on top, popover body below it, cropped to content.
            var snapshot = new Gtk.Snapshot ();
            int bar_h = bar.get_height ();
            int w = int.max (bar.get_width (), popover.get_width ());
            int h = bar_h + popover.get_height ();
            snapshot.append_color ({ 0.5f, 0.5f, 0.5f, 1f }, { { 0, 0 }, { w, h } });
            new Gtk.WidgetPaintable (bar).snapshot (snapshot, bar.get_width (), bar_h);
            snapshot.translate ({ 0, bar_h });
            new Gtk.WidgetPaintable (popover).snapshot (snapshot, popover.get_width (), popover.get_height ());
            var node = snapshot.to_node ();
            var renderer = window.get_native ().get_renderer ();
            if (node == null || renderer == null) {
                stderr.printf ("nothing to render\n");
                render_failed = true;
            } else {
                renderer.render_texture (node, null).save_to_png (args[1]);
            }
            loop.quit ();
            return Source.REMOVE;
        });
        return Source.REMOVE;
    });
    loop.run ();
    return render_failed ? 1 : 0;
}
