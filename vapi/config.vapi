[CCode (cprefix = "", lower_case_cprefix = "", cheader_filename = "config.h")]
namespace NmapUI {
    [CCode (cname = "VERSION")]
    public const string VERSION;
    [CCode (cname = "GETTEXT_PACKAGE")]
    public const string GETTEXT_PACKAGE;
    /* Where meson installs programs, e.g. the nmapui-summary helper. */
    [CCode (cname = "BINDIR")]
    public const string BINDIR;
}
