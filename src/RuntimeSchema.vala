/* Checks the engine's /api/runtime/status body before the app trusts it. A body we cannot read
 * must never look like an idle scanner, and JSON-GLib's typed accessors log criticals when a
 * member has an unexpected type, so every member is checked before it is read. */
namespace NmapUI {
    public class RuntimeSchema : Object {
        /** True when `key` is absent, or holds a value of `expected` type (or null when `nullable`). */
        public static bool value_type (Json.Object object, string key, Type expected, bool nullable = false) {
            if (!object.has_member (key)) {
                return true;
            }
            var node = object.get_member (key);
            if (node.get_node_type () == Json.NodeType.NULL) {
                return nullable;
            }
            return node.get_node_type () == Json.NodeType.VALUE && node.get_value_type () == expected;
        }

        /** True when `key` is absent, null, or a number (integer or float). */
        public static bool number_or_null (Json.Object object, string key) {
            return value_type (object, key, typeof (int64), true) || value_type (object, key, typeof (double), true);
        }

        /** The string at `key`, or "" when it is missing or not a string. */
        public static string text (Json.Object object, string key) {
            if (!object.has_member (key) || object.get_member (key).get_node_type () != Json.NodeType.VALUE
                || !value_type (object, key, typeof (string))) {
                return "";
            }
            return object.get_string_member (key);
        }

        /** The number at `key` truncated to an integer, or `fallback` when missing, null or not a number. */
        public static int64 integer (Json.Object object, string key, int64 fallback) {
            if (!object.has_member (key) || object.get_member (key).get_node_type () != Json.NodeType.VALUE) {
                return fallback;
            }
            if (value_type (object, key, typeof (int64))) {
                return object.get_int_member (key);
            }
            if (value_type (object, key, typeof (double))) {
                var value = object.get_double_member (key);
                return value.is_nan () ? fallback : (int64) value.clamp (-1e15, 1e15);
            }
            return fallback;
        }

        public static bool flag (Json.Object object, string key) {
            return object.has_member (key) && value_type (object, key, typeof (bool))
                && object.get_member (key).get_node_type () == Json.NodeType.VALUE
                && object.get_boolean_member (key);
        }

        /** True when `runtime` is a status snapshot the app can read without guessing. */
        public static bool valid (Json.Object? runtime) {
            if (runtime == null || !runtime.has_member ("active_jobs")
                || runtime.get_member ("active_jobs").get_node_type () != Json.NodeType.ARRAY) {
                return false;
            }
            var jobs = runtime.get_array_member ("active_jobs");
            for (uint i = 0; i < jobs.get_length (); i++) {
                var node = jobs.get_element (i);
                if (node.get_node_type () != Json.NodeType.OBJECT) {
                    return false;
                }
                var job = node.get_object ();
                var status = text (job, "status");
                if (text (job, "job_type") == "" || (status != "running" && status != "cancelling")) {
                    return false;
                }
                if (text (job, "job_type") != "scan") {
                    continue;
                }
                if (!value_type (job, "paused", typeof (bool)) || !value_type (job, "pause_requested", typeof (bool))) {
                    return false;
                }
                if (!job.has_member ("details") || job.get_null_member ("details")) {
                    continue;
                }
                if (job.get_member ("details").get_node_type () != Json.NodeType.OBJECT) {
                    return false;
                }
                var details = job.get_object_member ("details");
                foreach (var key in new string[] { "message", "target" }) {
                    if (!value_type (details, key, typeof (string), true)) {
                        return false;
                    }
                }
                foreach (var key in new string[] { "progress", "host_count" }) {
                    if (!number_or_null (details, key)) {
                        return false;
                    }
                }
                var host_count = integer (details, "host_count", 0);
                if (host_count < 0 || host_count > int.MAX) {
                    return false;
                }
            }
            return true;
        }
    }
}
