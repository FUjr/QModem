#!/usr/bin/env python3
"""Exercise the real Quectel setters with a fake AT transport (no modem needed)."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOME = ROOT / "application/qmodem/files/usr/share/qmodem"


class QuectelBandLock(unittest.TestCase):
    def run_setter(self, payload, response="OK\r\n", rc=0, platform="qualcomm", envelope=False):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / "generic.sh").write_text("")
            (home / "cmds").symlink_to(HOME / "cmds", target_is_directory=True)
            calls = home / "calls"
            env = dict(os.environ, QMODEM_HOME=tmp, VENDOR=str(HOME / "vendor/quectel.sh"),
                       PAYLOAD=payload if isinstance(payload, str) else json.dumps(payload),
                       RESPONSE=response, AT_RC=str(rc), PLATFORM=platform,
                       ENVELOPE="1" if envelope else "0", CALLS=str(calls))
            script = r'''
source "$VENDOR"
m_debug() { :; }
# Emit JSON events instead of requiring libubox/jshn on the host.
json_select() { [ "$ENVELOPE" = 1 ]; }
json_add_object() { printf 'object:%s\n' "$1"; }
json_close_object() { :; }
json_add_string() { jq -cn --arg k "$1" --arg v "$2" '{($k):$v}'; }
json_add_boolean() { jq -cn --arg k "$1" --argjson v "$2" '{($k):($v == 1)}'; }
at() { printf '%s\n' "$2" >> "$CALLS"; printf '%s' "$RESPONSE"; return "$AT_RC"; }
convert2hex() { printf '%s\n' 5; }
at_port=/mock/AT
platform=$PLATFORM
set_lockband "$PAYLOAD"
'''
            result = subprocess.run(["bash", "-eu", "-c", script], env=env,
                                    capture_output=True, text=True, check=True)
            data = {}
            for line in result.stdout.splitlines():
                if line.startswith("{"):
                    data.update(json.loads(line))
            sent = calls.read_text().splitlines() if calls.exists() else []
            return data, sent, result.stdout

    def test_invalid_input_never_reaches_modem(self):
        cases = ["not json", "null", "[]", {}, {"band_class": "NR", "lock_band": []},
                 {"band_class": "INVALID", "lock_band": "78"}]
        for bands in ["", " ", "0", "01", "-1", "78,", ",78", "78,,79", "78:79", "78;reboot", "78\n79", "78\n", "78\r"]:
            cases.append({"band_class": "NR", "lock_band": bands})
        for payload in cases:
            with self.subTest(payload=payload):
                data, sent, _ = self.run_setter(payload)
                self.assertFalse(data["success"])
                self.assertIn("error", data)
                self.assertEqual(sent, [])

    def test_each_rat_preserves_command_format(self):
        for rat, name in [("UMTS", "gw_band"), ("LTE", "lte_band"),
                          ("NR_NSA", "nsa_nr5g_band"), ("NR", "nr5g_band")]:
            with self.subTest(rat=rat):
                data, sent, _ = self.run_setter({"band_class": rat, "lock_band": "3,78"})
                self.assertTrue(data["success"])
                self.assertNotIn("error", data)
                self.assertEqual(sent, [f'AT+QNWPREFCFG="{name}",3:78'])

    def test_rejected_and_missing_acknowledgement(self):
        for response, rc in [("ERROR\r\n", 0), ("+CME ERROR: 4\r\n", 0),
                             ("+CMS ERROR: 500\r\n", 0), ("", 0),
                             ("OK\r\n", 1), ("ERROR\r\nOK\r\n", 0)]:
            with self.subTest(response=response, rc=rc):
                data, sent, _ = self.run_setter({"band_class": "NR", "lock_band": "78"}, response, rc)
                self.assertFalse(data["success"])
                self.assertEqual(data["set_lockband"], response.rstrip("\n"))
                self.assertEqual(len(sent), 1)

    def test_legacy_lte_and_result_envelopes(self):
        data, sent, _ = self.run_setter({"band_class": "NR", "lock_band": "78"}, platform="lte")
        self.assertFalse(data["success"])
        self.assertEqual(sent, [])
        # Preserve acknowledgement/error output from the legacy hex-mask setter.
        for response, ok in [("OK\r\n", True), ("ERROR\r\n", False)]:
            data, sent, _ = self.run_setter({"band_class": "LTE", "lock_band": "1,3"}, response, platform="lte")
            self.assertEqual(data["success"], ok)
            self.assertEqual(sent, ['AT+QCFG="band",0,5,0'])
        data, sent, _ = self.run_setter({"band_class": "Lte", "lock_band": "1,3"}, platform="lte")
        self.assertTrue(data["success"])
        self.assertEqual(sent, ['AT+QCFG="band",0,5,0'])
        for envelope in (False, True):
            data, _, output = self.run_setter({"band_class": "NR", "lock_band": "78"}, envelope=envelope)
            self.assertTrue(data["success"])
            self.assertEqual("object:result" in output, not envelope)


if __name__ == "__main__":
    unittest.main()
