"""A saturated local media backlog must not stop the SIP event loop."""
from pathlib import Path
import socket
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'libubox').mkdir()
    (tmp / 'libubox/uloop.h').write_text('#pragma once\nstruct uloop_fd { int fd; };\n')
    library = tmp / 'client.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(tmp), '-I' + str(root.parent / 'voipd/src'),
                    str(root / 'src/media_socket_client.c'), '-o', str(library)], check=True)
    path = str(tmp / 'media.sock')
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    listener.bind(path)
    listener.listen(0)
    queued = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    queued.connect(path)
    # Run in a child with a hard deadline: the old blocking connect hangs here.
    program = '''import ctypes,sys
lib=ctypes.CDLL(sys.argv[1]); client=ctypes.create_string_buffer(512)
assert lib.qmodem_voip_media_socket_client_attach(client,sys.argv[2].encode(),ctypes.c_uint64(1),b'test-session') == -1
'''
    subprocess.run([sys.executable, '-c', program, str(library), path], check=True, timeout=2)
    queued.close()
    listener.close()
print('PASS: full media backlog cannot block SIP consumer')
