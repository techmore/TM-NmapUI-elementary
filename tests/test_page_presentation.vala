int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/page/first-load", () => {
        var page = new NmapUI.PagePresentation ();
        assert (page.visible_page (true, false) == "offline");
        assert (page.visible_page (false, true) == "starting");
        page.started ();
        assert (page.loading);
        assert (page.visible_page (false, false) == "starting");
        assert (page.finished ());
        assert (page.visible_page (false, false) == "web");
        assert (page.visible_page (true, false) == "offline");
    });
    Test.add_func ("/page/failed-load-with-a-running-service-is-not-offline", () => {
        var page = new NmapUI.PagePresentation ();
        page.started ();
        page.load_failed ();
        assert (!page.finished ());
        assert (!page.ever_loaded);
        assert (!page.loading);
        assert (page.visible_page (false, false) == "page-error");
        assert (page.visible_page (true, false) == "offline");
        page.started ();
        assert (page.finished ());
        assert (page.visible_page (false, false) == "web");
    });
    Test.add_func ("/page/tab-requested-during-startup-survives-a-retry", () => {
        var page = new NmapUI.PagePresentation ();
        page.started ();
        page.request_tab ("reports");
        assert (!page.can_navigate ());
        page.load_failed ();
        assert (!page.finished ());
        assert (page.pending_tab == "reports");
        page.started ();
        assert (page.finished ());
        assert (page.can_navigate ());
        assert (page.take_tab () == "reports");
        assert (page.pending_tab == null);
    });
    return Test.run ();
}
