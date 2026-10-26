#!/usr/bin/env python3
"""Exercise the real scanner and CM discovery against synthetic sysfs topologies.

Requires a C compiler and json-c development files (JSON_C_CFLAGS/JSON_C_LIBS
can override the compiler/linker flags).
"""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class GenericMhi(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="qmg-")
        cls.root = Path(cls.tmp.name)
        cls.sys = cls.root / "sys"
        cls.dev = cls.root / "dev"
        cm = cls.root / "cm.c"
        cm.write_text('#include "mhi_generic.h"\nint main(int n,char **v) {\n'
                      'struct cm_mhi_endpoint e={0}; if(n!=4)return 2;\n'
                      'int r=cm_mhi_detect(v[1],v[2],v[3],&e);\n'
                      'printf("%d %s %s %d\\n",r,e.netdev,e.control,e.mbim);return 0;}\n')
        subprocess.run([os.getenv("CC", "cc"), "-Wall", "-Wextra", "-Werror",
                        "-I" + str(REPO / "application/quectel_CM_5G_M/src"),
                        str(cm), "-o", str(cls.root / "cm")], check=True)
        scanner = cls.root / "scanner.c"
        scanner.write_text('#define QMODEM_SYSFS_ROOT "' + str(cls.sys) + '"\n'
                           '#define main daemon_main\n#include "' +
                           str(REPO / "application/modem_scan/src/modem_scand.c") +
                           '"\n#undef main\nint main(int n,char **v) {\n'
                           'struct scan_result r={0};if(n!=2)return 2;scan_pcie_slot(v[1],&r);\n'
                           'for(size_t i=0;i<r.net_devices.len;i++)printf("net:%s\\n",r.net_devices.items[i]);\n'
                           'for(size_t i=0;i<r.at_ports.len;i++)printf("at:%s\\n",r.at_ports.items[i]);return 0;}\n')
        flags = shlex.split(os.getenv("JSON_C_CFLAGS", ""))
        libs = shlex.split(os.getenv("JSON_C_LIBS", "-ljson-c"))
        subprocess.run([os.getenv("CC", "cc"), "-D_GNU_SOURCE", "-std=c99", *flags,
                        str(scanner), "-o", str(cls.root / "scanner"), *libs, "-lpthread"], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        for p in (self.sys, self.dev):
            shutil.rmtree(p, ignore_errors=True)
            p.mkdir()
        self.slot = self.sys / "devices/pci/0002:01:00.0"
        self.controller = self.slot / "mhi4"
        self.controller.mkdir(parents=True)
        self.link(self.sys / "bus/pci/devices/0002:01:00.0", self.slot)

    def link(self, link, target):
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target)

    def driver(self, device, name):
        target = self.sys / "bus/mhi/drivers" / name
        target.mkdir(parents=True, exist_ok=True)
        self.link(device / "driver", target)

    def net(self, name="mhi_hwip7", channel="IP_HW0", driver="mhi_net"):
        node = self.controller / ("mhi4_" + channel)
        net = node / "net" / name
        net.mkdir(parents=True)
        self.link(net / "device", node)
        self.driver(node, driver)
        self.link(self.sys / "class/net" / name, net)
        return name

    def port(self, name="wwan9qmi2", kind="QMI", controller=None, present=True):
        port = (controller or self.controller) / "wwan/wwan9" / name
        port.mkdir(parents=True)
        (port / "type").write_text(kind + "\n")
        self.link(self.sys / "class/wwan" / name, port)
        if present:
            (self.dev / name).touch()

    def detect(self, name="mhi_hwip7"):
        return subprocess.check_output([str(self.root / "cm"), str(self.sys),
                                        str(self.dev), name], text=True).split()

    def scan(self):
        return set(subprocess.check_output([str(self.root / "scanner"),
                                            "0002:01:00.0"], text=True).splitlines())

    def test_qmi_hw_sw_and_control_types(self):
        self.net()
        self.net("mhi_swip7", "IP_SW0")
        self.port()
        self.port("wwan9mbim0", "MBIM")
        self.port("wwan9qcdm0", "QCDM")
        self.port("wwan9at0", "AT")
        self.assertEqual(self.detect(), ["1", "mhi_hwip7", str(self.dev / "wwan9qmi2"), "0"])
        self.assertEqual(self.scan(), {"net:mhi_hwip7", "at:/dev/wwan9at0"})
        self.assertEqual(self.detect("mhi_swip7")[0], "-1")

    def test_other_controller_is_not_a_fallback(self):
        self.net()
        other = self.sys / "devices/pci/0002:01:00.00/mhi8"
        self.port(controller=other)
        self.assertEqual(self.detect()[0], "-1")
        self.assertEqual(self.scan(), {"net:mhi_hwip7"})

    def test_missing_and_duplicate_control(self):
        self.net()
        self.assertEqual(self.detect()[0], "-1")
        self.port(present=False)
        self.assertEqual(self.detect()[0], "-1")
        (self.dev / "wwan9qmi2").touch()
        self.port("wwan9qmi3")
        self.assertEqual(self.detect()[0], "-1")

    def test_absent_extra_control_does_not_replace_selected_control(self):
        self.net()
        self.port()
        self.port("wwan9qmi3", present=False)
        self.assertEqual(self.detect()[2], str(self.dev / "wwan9qmi2"))

    def test_native_mbim_controller_parented_link(self):
        channel = self.controller / "mhi4_IP_HW0_MBIM"
        channel.mkdir()
        self.driver(channel, "mhi_wwan_mbim")
        net = self.controller / "net/wwan7"
        net.mkdir(parents=True)
        self.link(self.sys / "class/net/wwan7", net)
        self.port("wwan9mbim3", "MBIM")
        self.port()
        self.assertEqual(self.detect("wwan7"), ["1", "wwan7", str(self.dev / "wwan9mbim3"), "1"])
        self.assertEqual(self.scan(), {"net:wwan7"})
        (channel / "driver").unlink()
        self.assertEqual(self.detect("wwan7")[0], "-1")

    def test_unbound_data_driver_is_rejected(self):
        self.net(driver="other")
        self.port()
        self.assertEqual(self.detect()[0], "-1")

    def test_multiple_hw_endpoints_are_ambiguous(self):
        self.net()
        node = self.controller / "mhi4_IP_HW0/net/mhi_hwip8"
        node.mkdir()
        self.link(node / "device", self.controller / "mhi4_IP_HW0")
        self.link(self.sys / "class/net/mhi_hwip8", node)
        self.port()
        self.assertEqual(self.detect("")[0], "-1")
        self.assertEqual(self.detect()[0], "1")

    def test_hotplug_resolves_nested_pci_ancestor_and_ignores_sw(self):
        self.net()
        self.net("mhi_swip7", "IP_SW0")
        (self.slot / "vendor").write_text("0x17cb\n")
        mockbin = self.root / "bin"
        mockbin.mkdir(exist_ok=True)
        for name, body in {"uci": 'case "$*" in *block_auto_probe) exit 1;; *) echo 0;; esac', "logger": 'echo "$*"'}.items():
            script = mockbin / name
            script.write_text("#!/bin/sh\n" + body + "\n")
            script.chmod(0o755)
        env = dict(os.environ, PATH=str(mockbin) + ":" + os.environ["PATH"],
                   QMODEM_SYSFS_ROOT=str(self.sys), ACTION="test")
        hook = REPO / "application/qmodem/files/etc/hotplug.d/net/20-modem-net"
        for name, channel in (("mhi_hwip7", "IP_HW0"), ("mhi_swip7", "IP_SW0")):
            env.update(INTERFACE=name, DEVPATH="/" + str((self.controller /
                       ("mhi4_" + channel) / "net" / name).relative_to(self.sys)))
            output = subprocess.check_output(["sh", str(hook)], env=env, text=True)
            self.assertEqual("slot: 0002:01:00.0 action: test slot_type: pcie" in output,
                             channel == "IP_HW0")

    def test_legacy_vendor_net_and_dun(self):
        node = self.slot / "0308_02.01.00_IP_HW0"
        (node / "net/rmnet_mhi0").mkdir(parents=True)
        self.driver(node, "mhi_netdev")
        at = self.slot / "0308_02.01.00_DUN"
        (at / "mhi_uci_q/mhi_DUN").mkdir(parents=True)
        self.driver(at, "mhi_uci_q")
        self.assertEqual(self.scan(), {"net:rmnet_mhi0", "at:/dev/mhi_DUN"})
        self.assertEqual(self.detect("")[0], "0")


if __name__ == "__main__":
    unittest.main()
