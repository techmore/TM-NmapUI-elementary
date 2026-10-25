import importlib.machinery
import importlib.util
import io
import json
import threading
from pathlib import Path

import pytest

path = Path(__file__).resolve().parents[1] / "helper/nmapui-summary"
loader = importlib.machinery.SourceFileLoader("nmapui_summary", str(path))
spec = importlib.util.spec_from_loader("nmapui_summary", loader)
summary = importlib.util.module_from_spec(spec)
loader.exec_module(summary)

HEALTH = {"app_version": "v1", "tool_versions": {"nmap": "7.94"}}


def test_unreachable_service_is_offline_and_unknown():
    out = summary.summarize(None, None, None, None)
    assert out["state"] == "offline" and out["hosts"] is None and out["alerts"] == []


def test_active_scan_reports_progress_and_hosts():
    runtime = {"active_jobs": [{"job_type": "scan", "status": "running",
                                "details": {"progress": 40, "message": "Service scan 2/5", "host_count": 5}}]}
    out = summary.summarize(HEALTH, runtime, {"history": []}, None)
    assert (out["state"], out["progress"], out["hosts"]) == ("scanning", 40, 5)


def test_cancelling_scan_is_stopping():
    runtime = {"active_jobs": [{"job_type": "scan", "status": "cancelling", "details": {}}]}
    assert summary.summarize(HEALTH, runtime, None, None)["state"] == "stopping"


def test_changes_and_critical_cves_raise_attention():
    history = {"history": [{"timestamp": "2026-10-19T10:00:00Z", "customer_name": "Penn", "host_count": 24,
                            "critical_cves": 2, "diff_summary": {"has_changes": True}}]}
    out = summary.summarize(HEALTH, {"active_jobs": []}, history, {"enabled": True, "next_run": "01:00"})
    assert out["state"] == "attention" and out["hosts"] == 24 and out["critical"] == 2
    assert out["monitor"] == "01:00" and len(out["alerts"]) == 2


def test_missing_nmap_is_flagged_not_hidden():
    out = summary.summarize({"tool_versions": {"nmap": "Not installed"}}, {"active_jobs": []}, {"history": []}, None)
    assert out["tools_missing"] == ["nmap"] and out["state"] == "attention"


def test_clean_idle_has_no_alerts_and_unknown_counts_stay_none():
    out = summary.summarize(HEALTH, {"active_jobs": []}, {"history": []}, None)
    assert out["state"] == "idle" and out["hosts"] is None and out["critical"] is None


def test_scan_details_parse_step_total_and_elapsed(monkeypatch):
    monkeypatch.setattr(summary, "network_info", lambda iface: {"interface": iface})
    runtime = {"active_jobs": [{"job_type": "scan", "status": "running", "started_at": "2026-10-19T21:34:17",
                                "details": {"target": "10.0.0.0/24", "phase": "service_scan", "progress": 60,
                                            "message": "Service scan 2/30: 10.0.0.8"}}]}
    out = summary.summarize({"default_interface": "wld0", "tool_versions": {"nmap": "7"}}, runtime, None, None)
    assert out["hosts"] == 30 and out["network"] == {"interface": "wld0"}
    assert out["scan"]["index"] == 2 and out["scan"]["total"] == 30 and out["scan"]["current"] == "10.0.0.8"
    assert out["scan"]["target"] == "10.0.0.0/24" and out["scan"]["elapsed_seconds"] >= 0


def test_network_info_without_interface_is_all_unknown(monkeypatch):
    monkeypatch.setattr(summary, "run_json", lambda command: None)
    assert summary.network_info(None)["address"] is None


def test_devices_are_sorted_numerically_and_fill_host_count():
    live = {"hosts": [{"ip": "10.0.0.20", "hostname": "b", "vendor": "V", "open_ports": 1},
                      {"ip": "10.0.0.3", "hostname": "", "vendor": "W", "open_ports": None}, {"hostname": "no-ip"}]}
    out = summary.summarize(HEALTH, {"active_jobs": []}, {"history": []}, None, live)
    assert [d["ip"] for d in out["devices"]] == ["10.0.0.3", "10.0.0.20"]
    assert out["hosts"] == 2 and out["devices"][1]["open_ports"] == 1


@pytest.mark.parametrize("runtime", [None, [], {}, {"active_jobs": None}, {"active_jobs": {}}])
def test_unreadable_runtime_does_not_claim_idle(runtime, monkeypatch):
    monkeypatch.setattr(summary, "network_info", lambda iface: {})
    out = summary.summarize(HEALTH, runtime, {"history": []}, None)
    assert out["state"] == "unknown"
    assert "unavailable" in out["label"].lower()
    assert out["alerts"] and out["progress"] is None


@pytest.mark.parametrize("flags,state", [({"paused": True}, "paused"), ({"pause_requested": True}, "pausing")])
def test_paused_scan_state_is_preserved(flags, state, monkeypatch):
    monkeypatch.setattr(summary, "network_info", lambda iface: {})
    runtime = {"active_jobs": [{"job_type": "scan", "status": "running", **flags, "details": {"progress": 130}}]}
    out = summary.summarize(HEALTH, runtime, None, None)
    assert out["state"] == state and out["progress"] == 100


def test_timezone_aware_scan_start_does_not_break_summary(monkeypatch):
    monkeypatch.setattr(summary, "network_info", lambda iface: {})
    runtime = {"active_jobs": [{"job_type": "scan", "status": "running",
                                "started_at": "2026-01-01T01:00:00+03:00", "details": {}}]}
    out = summary.summarize(HEALTH, runtime, None, None)
    assert out["scan"]["elapsed_seconds"] >= 0


def test_malformed_optional_rows_stay_unknown(monkeypatch):
    monkeypatch.setattr(summary, "network_info", lambda iface: {})
    out = summary.summarize({"tool_versions": []}, {"active_jobs": [None, [], "bad"]},
                            {"history": [None, {"diff_summary": "bad"}]}, None, {"hosts": {"ip": "bad"}})
    assert out["state"] == "unknown" and out["devices"] == [] and out["hosts"] is None


@pytest.mark.parametrize("job", [None, [], 7, {},
    {"job_type": "scan", "status": "completed"},
    {"job_type": "scan", "status": "running", "paused": "false"},
    {"job_type": "scan", "status": "running", "details": []},
    {"job_type": "scan", "status": "running", "details": {"message": {}}},
    {"job_type": "scan", "status": "running", "details": {"progress": True}},
    {"job_type": "scan", "status": "running", "details": {"host_count": 2**63}},
])
def test_invalid_active_job_cannot_establish_idle_or_scan_state(job, monkeypatch):
    monkeypatch.setattr(summary, "network_info", lambda iface: {})
    out = summary.summarize(HEALTH, {"active_jobs": [job]}, None, None)
    assert out["state"] == "unknown" and out["scan"] is None
    assert out["alerts"] and out["progress"] is None


def test_optional_api_text_cannot_emit_objects_into_indicator_schema(monkeypatch):
    monkeypatch.setattr(summary, "network_info", lambda iface: {})
    out = summary.summarize({"app_version": {}}, {"active_jobs": []},
        {"history": [{"timestamp": [], "customer_name": {}, "critical_cves": 2**70}]},
        {"enabled": True, "next_run": {}}, {"hosts": [{"ip": {}}, {"ip": "127.0.0.1", "hostname": []}]})
    assert out["version"] is out["last_scan"] is out["last_customer"] is out["critical"] is None
    assert out["monitor"] == "Enabled" and out["devices"] == [{"ip": "127.0.0.1", "name": "", "vendor": "", "open_ports": None}]


def test_oversized_api_response_is_rejected(monkeypatch):
    class Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            self.close()

    monkeypatch.setattr(summary, "MAX_RESPONSE_BYTES", 16)
    monkeypatch.setattr(summary.urllib.request, "urlopen", lambda *_args, **_kwargs: Response(b" " * 17))
    assert summary.get("/api/runtime/status") is None


def test_wifi_status_does_not_trigger_rescan(monkeypatch):
    calls = []
    monkeypatch.setattr(summary, "run_json", lambda command: [{"dev": "wlan0", "gateway": "192.0.2.1"}] if "route" in command else [])

    def run(command, **_kwargs):
        calls.append(command)
        return type("Result", (), {"stdout": "yes:Office WiFi\n"})()

    monkeypatch.setattr(summary.subprocess, "run", run)
    assert summary.network_info("wlan0")["ssid"] == "Office WiFi"
    assert calls == [["nmcli", "-t", "-f", "active,ssid", "dev", "wifi", "list", "ifname", "wlan0", "--rescan", "no"]]


def test_offline_main_avoids_followup_requests(monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(summary, "get", lambda path: calls.append(path))
    assert summary.main() == 0
    assert calls == ["/api/health"]
    assert json.loads(capsys.readouterr().out)["state"] == "offline"


def test_main_reads_independent_api_summaries_concurrently(monkeypatch, capsys):
    barrier = threading.Barrier(4)

    def get(path):
        if path == "/api/health":
            return HEALTH
        barrier.wait(timeout=2)
        return {"active_jobs": []} if path == "/api/runtime/status" else {}

    monkeypatch.setattr(summary, "get", get)
    monkeypatch.setattr(summary, "network_info", lambda iface: {})
    assert summary.main() == 0
    assert json.loads(capsys.readouterr().out)["state"] == "idle"
