#!/usr/bin/env python3
"""Exercise the CLI/rpcd cache wrappers with concurrent real shell processes."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PKG = Path(__file__).resolve().parents[1]
HELPER = PKG / 'files/usr/share/qmodem/cache.sh'
STUB = PKG / 'tests/lib/jshn_stub.sh'


def wrapper(path):
    text = path.read_text()
    start = text.index('try_cache() {')
    return text[start:text.index('\n}\n', start) + 3]


class CacheTests(unittest.TestCase):
    def test_mixed_callers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / 'cache_cell_info_test'
            calls = root / 'queries'
            cli = wrapper(PKG / 'files/usr/share/qmodem/modem_ctrl.sh')
            rpc = wrapper(PKG / 'files/usr/libexec/rpcd/qmodem')
            common = f'''
. '{HELPER}'
. '{STUB}'
qmodem_testcase_collect_enabled() {{ return 1; }}
query() {{
 echo query >> '{calls}'
 sleep 0.15
 json_add_object ''
 json_add_string key RSRP
 json_add_string value -74
 json_close_object
}}
json_init
'''

            def run(which):
                script = common + (cli if which % 2 else rpc)
                script += f'\ntry_cache 10 "{cache}" query\n'
                return subprocess.run(['sh', '-c', script], capture_output=True, text=True, timeout=10)

            def wave(expected):
                with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                    results = list(pool.map(run, range(8)))
                for result in results:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout)['modem_info'][0]['value'], '-74')
                self.assertEqual(len(calls.read_text().splitlines()), expected)

            wave(1)  # Cold cache: all callers wait for the single AT reader.
            before = cache.stat().st_mtime_ns
            wave(1)  # Fresh cache: no query and no timestamp extension.
            self.assertEqual(cache.stat().st_mtime_ns, before)
            os.utime(cache, (1, 1))
            wave(2)  # Expired cache: exactly one new query across both APIs.
            cache.write_text('')
            wave(3)  # Previously truncated cache is repaired, never returned.
            cache.write_text('{broken')
            wave(4)

            # A broken generated response must not replace the previous cache.
            os.utime(cache, (1, 1))
            old = cache.read_bytes()
            script = common + '''
json_dump() { printf '%s' '{broken'; }
''' + f'\nqmodem_cached_query 10 "{cache}" query\n'
            result = subprocess.run(['sh', '-c', script], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(cache.read_bytes(), old)
            self.assertEqual(cache.stat().st_mtime, 1)
            self.assertEqual(list(root.glob(cache.name + '.??????')), [])
            wave(6)  # Error released the lock; a following caller recovers.


if __name__ == '__main__':
    unittest.main()
