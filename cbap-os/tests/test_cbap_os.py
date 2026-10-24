#!/usr/bin/env python3
"""Host-level tests for the CBAP OS selector.

No root, no systemd, no real bind mounts. The same CLI is exercised through a
temporary CBAP_OS_ROOT and symlink slots.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
CLI = HERE / "bin/cbap-os"


class CBAPOS(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "root"
        for kind, names in {
            "cbap": ["v1.0.0", "v1.4.0"],
            "python": ["3.12", "3.13"],
        }.items():
            for name in names:
                d = self.root / "opt/cbap-os/versions" / kind / name
                if kind == "cbap":
                    (d / "kernel").mkdir(parents=True)
                    (d / "kernel" / "__init__.py").write_text("")
                else:
                    (d / "bin").mkdir(parents=True)
                    (d / "bin" / "python3").symlink_to(sys.executable)
                (d / "manifest.json").write_text(json.dumps({"source": "test"}))
        (self.root / "etc/cbap-os").mkdir(parents=True)
        (self.root / "opt/cbap-os/current").mkdir(parents=True)
        (self.root / "var/lib/cbap-os").mkdir(parents=True)
        self.env = dict(os.environ)
        self.env.update({
            "CBAP_OS_ROOT": str(self.root),
            "CBAP_OS_NO_SYSTEMD": "1",
            "CBAP_OS_MOUNT_MODE": "symlink",
        })

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args, check=True):
        p = subprocess.run([sys.executable, str(CLI), *args], env=self.env,
                           text=True, capture_output=True)
        if check and p.returncode != 0:
            self.fail(f"cmd failed: {args}\nstdout={p.stdout}\nstderr={p.stderr}")
        return p

    def selection(self):
        return json.loads((self.root / "etc/cbap-os/selection.json").read_text())

    def test_list_json(self):
        p = self.run_cli("list", "--json")
        data = json.loads(p.stdout)
        self.assertEqual([x["version"] for x in data["cbap"]], ["v1.0.0", "v1.4.0"])
        self.assertEqual([x["version"] for x in data["python"]], ["3.12", "3.13"])

    def test_use_swaps_both_slots(self):
        self.run_cli("use", "--cbap", "v1.0.0", "--python", "3.12")
        self.assertEqual(self.selection()["cbap"], "v1.0.0")
        self.assertEqual(self.selection()["python"], "3.12")
        self.assertEqual(
            (self.root / "opt/cbap-os/current/cbap").resolve().name, "v1.0.0")
        self.assertEqual(
            (self.root / "opt/cbap-os/current/python").resolve().name, "3.12")

    def test_partial_use_keeps_other_slot(self):
        self.run_cli("use", "--cbap", "v1.0.0", "--python", "3.12")
        self.run_cli("use", "--cbap", "v1.4.0")
        self.assertEqual(self.selection()["cbap"], "v1.4.0")
        self.assertEqual(self.selection()["python"], "3.12")

    def test_ambiguous_and_missing_versions_fail(self):
        p = self.run_cli("use", "--cbap", "v1", check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("ambiguous", p.stderr)
        p = self.run_cli("use", "--cbap", "v9.9.9", check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("not installed", p.stderr)

    def test_dry_run_does_not_write(self):
        p = self.run_cli("use", "--cbap", "v1.0.0", "--python", "3.12", "--dry-run")
        self.assertIn("dry-run", p.stdout)
        self.assertFalse((self.root / "etc/cbap-os/selection.json").exists())
        self.assertFalse((self.root / "opt/cbap-os/current/cbap").exists())

    def test_boot_mounts_even_when_selection_is_unchanged(self):
        self.run_cli("use", "--cbap", "v1.0.0", "--python", "3.12")
        cur = self.root / "opt/cbap-os/current"
        for name in ("cbap", "python"):
            (cur / name).unlink()
        self.run_cli("boot", "--mount-only")
        self.assertTrue((cur / "cbap").is_symlink())
        self.assertTrue((cur / "python").is_symlink())
        self.assertEqual((cur / "cbap").resolve().name, "v1.0.0")

    def test_rollback(self):
        self.run_cli("use", "--cbap", "v1.0.0", "--python", "3.12")
        self.run_cli("use", "--cbap", "v1.4.0", "--python", "3.13")
        self.run_cli("rollback")
        self.assertEqual(self.selection()["cbap"], "v1.0.0")
        self.assertEqual(self.selection()["python"], "3.12")

    def test_boot_menu_noninteractive_uses_selection(self):
        self.run_cli("use", "--cbap", "v1.0.0", "--python", "3.12")
        p = self.run_cli("boot-menu", "--noninteractive")
        self.assertIn("selected cbap=v1.0.0", p.stdout)

    def test_doctor_ok(self):
        p = self.run_cli("doctor")
        self.assertIn("doctor: ok", p.stdout)

    def test_installer_creates_slots_and_selection(self):
        src = Path(self.tmp.name) / "src"
        (src / "kernel").mkdir(parents=True)
        (src / "drivers/mc").mkdir(parents=True)
        (src / "kernel/__init__.py").write_text("")
        (src / "drivers/mc/device.json").write_text("{}")
        install = HERE / "install.sh"
        p = subprocess.run([
            "bash", str(install), "--root", str(self.root),
            "--cbap-src", str(src), "--cbap-version", "vTEST",
            "--no-systemd", "--no-users",
        ], env=self.env, text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        sel = self.selection()
        self.assertEqual(sel["cbap"], "vTEST")
        self.assertTrue((self.root / "opt/cbap-os/versions/cbap/vTEST/kernel").is_dir())
        self.assertTrue((self.root / "usr/local/bin/cbap-os").exists())

    def test_hand_present(self):
        sock = self.root / "run/cyberdyne/cyberdyne.sock"
        sock.parent.mkdir(parents=True)
        sock.write_text("")
        self.env["CBAP_HAND_SOCKET"] = str(sock)
        self.assertEqual(self.run_cli("hand-present", check=False).returncode, 0)
        sock.unlink()
        self.assertEqual(self.run_cli("hand-present", check=False).returncode, 1)


if __name__ == "__main__":
    unittest.main()
