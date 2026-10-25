/* Validate before JSON-GLib's typed accessors, which emit criticals on wrong types. */
namespace NmapUI {
    public class RuntimeSchema : Object {
        public static bool value_type (Json.Object object, string key, Type expected, bool nullable = false) {
            if (!object.has_member (key)) return true;
            var node = object.get_member (key);
            return (nullable && node.get_node_type () == Json.NodeType.NULL)
                || (node.get_node_type () == Json.NodeType.VALUE && node.get_value_type () == expected);
        }

        public static string text (Json.Object object, string key) {
            if (!object.has_member (key) || !value_type (object, key, typeof (string))) return "";
            return object.get_string_member (key);
        }

        public static bool valid (Json.Object? runtime) {
            if (runtime == null || !runtime.has_member ("active_jobs")
                || runtime.get_member ("active_jobs").get_node_type () != Json.NodeType.ARRAY) return false;
            var jobs = runtime.get_array_member ("active_jobs");
            for (uint i = 0; i < jobs.get_length (); i++) {
                var node = jobs.get_element (i);
                if (node.get_node_type () != Json.NodeType.OBJECT) return false;
                var job = node.get_object ();
                if (text (job, "job_type") == "" || (text (job, "status") != "running" && text (job, "status") != "cancelling")) return false;
                if (text (job, "job_type") != "scan") continue;
                if (!value_type (job, "paused", typeof (bool)) || !value_type (job, "pause_requested", typeof (bool))) return false;
                if (!job.has_member ("details") || job.get_null_member ("details")) continue;
                if (job.get_member ("details").get_node_type () != Json.NodeType.OBJECT) return false;
                var details = job.get_object_member ("details");
                foreach (var key in new string[] {"message", "target"}) {
                    if (!value_type (details, key, typeof (string), true)) return false;
                }
                foreach (var key in new string[] {"progress", "host_count"}) {
                    if (!value_type (details, key, typeof (int64), true)) return false;
                }
                if (details.has_member ("host_count") && !details.get_null_member ("host_count")
                    && (details.get_int_member ("host_count") < 0 || details.get_int_member ("host_count") > int.MAX)) return false;
            }
            return true;
        }
    }
}
