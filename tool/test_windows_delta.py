"""Exercise the Windows update process with isolated versioned ZIP fixtures."""

import ctypes
import hashlib
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from zipfile import ZipFile

from build_windows_delta import build

SYSTEM = Path(r"C:\Windows")
POWERSHELL = SYSTEM / "System32/WindowsPowerShell/v1.0/powershell.exe"
CSC = SYSTEM / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
SCRIPT = Path(__file__).with_name("apply_windows_delta.ps1")
OLD, NEW = "v1.2.0.1", "v1.2.0.2"
FIXTURE = """using System;
using System.IO;
using System.Threading;
class Fixture {
    static void Main(string[] args) {
        if (args.Length == 1 && args[0] == "wait") Thread.Sleep(60000);
        else File.WriteAllText("restart.txt", String.Join(" ", args));
    }
}
"""


def wait_for(*files):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        for file in files:
            if file.exists():
                return file
        time.sleep(0.1)
    raise AssertionError(f"Timed out waiting for {files}")


class DeltaTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="MisaTV delta 测试 ")
        self.addCleanup(temp.cleanup)
        work = self.work = Path(temp.name)
        self.root = work / "installed"
        self.root.mkdir()
        self.session = work / "session"
        self.session.mkdir()
        source = work / "Fixture.cs"
        source.write_text(FIXTURE)
        exe = self.root / "MisaTV.exe"
        self.exe = exe
        subprocess.run([CSC, "/nologo", f"/out:{exe}", source], check=True)
        self.original = {
            "data/app.so": b"app old",
            "data/removed.txt": b"obsolete",
            "data/z-locked.dll": b"old dll",
            "runtimes/ready.json": b"manifest",
            "runtimes/mpv-yaozhi/mpv.exe": b"same runtime",
        }
        self.updated = {
            **self.original,
            "data/app.so": b"app new",
            "data/new.txt": b"new file",
            "data/z-locked.dll": b"new dll",
        }
        del self.updated["data/removed.txt"]
        for path, value in {**self.original, "userdata/keep": b"user data"}.items():
            output = self.root / path
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(value)

    def create_delta(self):
        archives = [self.work / "old.zip", self.work / "new.zip"]
        for archive, files in zip(archives, [self.original, self.updated]):
            with ZipFile(archive, "w") as zip_file:
                zip_file.write(self.exe, "MisaTV.exe")
                for path, data in files.items():
                    zip_file.writestr(path, data)
        path = build(*archives, self.work, OLD, NEW)
        with ZipFile(path) as zip_file:
            self.assertNotIn("files/runtimes/mpv-yaozhi/mpv.exe", zip_file.namelist())
        return path.rename(self.session / "delta.zip")

    def create_full(self, variant="full"):
        archive = self.session / "full.zip"
        with ZipFile(archive, "w") as zip_file:
            zip_file.write(self.exe, "MisaTV.exe")
            for path, data in self.updated.items():
                if variant == "full" or not path.startswith("runtimes/"):
                    zip_file.writestr(path, data)
        return archive

    def start_worker(self, archive, variant="full"):
        parent = subprocess.Popen([self.exe, "wait"], cwd=self.root)
        self.addCleanup(parent.wait, 10)
        self.addCleanup(parent.terminate)
        worker = subprocess.Popen([
            POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", SCRIPT, "-Session", self.session, "-Root", self.root,
            "-ExeName", self.exe.name, "-ParentPid", str(parent.pid),
            "-From", OLD, "-To", NEW, "-Variant", variant,
            "-Digest", hashlib.sha256(archive.read_bytes()).hexdigest(),
            *(["-FullPackage"] if archive.name == "full.zip" else []),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW)
        self.addCleanup(worker.wait, 10)
        self.addCleanup(worker.terminate)
        return parent, worker

    def assert_contents(self, expected):
        for path, data in expected.items():
            self.assertEqual((self.root / path).read_bytes(), data)
        self.assertEqual((self.root / "userdata/keep").read_bytes(), b"user data")

    def test_replace_add_delete_and_restart(self):
        parent, worker = self.start_worker(self.create_delta())
        self.assertEqual(wait_for(self.session / "ready", self.session / "failed").name, "ready")
        self.assert_contents(self.original)
        (self.session / "commit").touch()
        parent.terminate()
        worker.wait(20)
        self.assertEqual(wait_for(self.root / "restart.txt").read_text(), "")
        self.assert_contents(self.updated)
        self.assertFalse((self.root / "data/removed.txt").exists())

    def test_restore_if_a_later_replacement_is_locked(self):
        parent, worker = self.start_worker(self.create_delta())
        self.assertEqual(wait_for(self.session / "ready", self.session / "failed").name, "ready")
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        create = kernel.CreateFileW
        create.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                           ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        create.restype = ctypes.c_void_p
        lock = create(str(self.root / "data/z-locked.dll"), 0x80000000, 1, None, 3, 0, None)
        self.assertNotEqual(lock, ctypes.c_void_p(-1).value)
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        self.addCleanup(kernel.CloseHandle, lock)
        (self.session / "commit").touch()
        parent.terminate()
        worker.wait(20)
        self.assertEqual(wait_for(self.root / "restart.txt").read_text(), f"--misatv-full-update={NEW}")
        self.assert_contents(self.original)
        self.assertFalse((self.root / "data/new.txt").exists())

    def test_different_baseline_never_exits_or_modifies_files(self):
        archive = self.create_delta()
        (self.root / "data/app.so").write_bytes(b"custom app")
        parent, worker = self.start_worker(archive)
        failed = wait_for(self.session / "failed")
        self.assertIn("base release", failed.read_text())
        worker.wait(20)
        self.assertIsNone(parent.poll())
        self.assertEqual((self.root / "data/app.so").read_bytes(), b"custom app")
        self.assertEqual((self.root / "userdata/keep").read_bytes(), b"user data")

    def test_full_package_overwrites_modified_base_and_restarts(self):
        (self.root / "data/app.so").write_bytes(b"custom app")
        parent, worker = self.start_worker(self.create_full())
        self.assertEqual(wait_for(self.session / "ready", self.session / "failed").name, "ready")
        self.assertEqual((self.root / "data/app.so").read_bytes(), b"custom app")
        (self.session / "commit").touch()
        parent.terminate()
        worker.wait(20)
        self.assertEqual(wait_for(self.root / "restart.txt").read_text(), "")
        self.assert_contents(self.updated)

    def test_full_package_rejects_other_variant_before_exiting(self):
        parent, worker = self.start_worker(self.create_full("lite"))
        self.assertIn("package layout or type", wait_for(self.session / "failed").read_text())
        worker.wait(20)
        self.assertIsNone(parent.poll())
        self.assert_contents(self.original)

    def test_full_package_rolls_back_and_reports_failure(self):
        parent, worker = self.start_worker(self.create_full())
        self.assertEqual(wait_for(self.session / "ready", self.session / "failed").name, "ready")
        # 模拟准备完成后，目标路径被其他进程占用为目录。
        (self.root / "data/new.txt").mkdir()
        (self.session / "commit").touch()
        parent.terminate()
        worker.wait(20)
        self.assertEqual(wait_for(self.root / "restart.txt").read_text(), f"--misatv-update-failed={NEW}")
        self.assert_contents(self.original)


if __name__ == "__main__":
    unittest.main()
