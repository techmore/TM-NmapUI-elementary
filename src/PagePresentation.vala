/* Keep service availability, page loading and pending navigation independent. */
namespace NmapUI {
    public class PagePresentation : Object {
        public bool loading { get; private set; default = false; }
        public bool failed { get; private set; default = false; }
        public bool ever_loaded { get; private set; default = false; }
        public string? pending_tab { get; private set; default = null; }

        public void started () { loading = true; failed = false; }
        public void load_failed () { loading = false; failed = true; }
        public bool finished () {
            loading = false;
            if (failed) return false;
            ever_loaded = true;
            return true;
        }
        public bool needs_online_load () { return !loading && (!ever_loaded || failed); }
        public bool can_navigate () { return ever_loaded && !loading && !failed; }
        public void request_tab (string tab) { pending_tab = tab; }
        public string? take_tab () {
            var tab = pending_tab;
            pending_tab = null;
            return tab;
        }
        public string visible_page (bool offline, bool starting) {
            if (starting) return "starting";
            if (offline) return "offline";
            if (failed) return "page-error";
            return ever_loaded ? "web" : "starting";
        }
    }
}
