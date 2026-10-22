#!/usr/bin/env python3
"""Send one command to the local development build's existing debug bridge."""
import argparse
import socket
import sys
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--port', type=int, default=8775)
p.add_argument('--timeout', type=float, default=15)
p.add_argument('command', nargs='+')
a = p.parse_args()
try:
    with socket.create_connection(('127.0.0.1', a.port), timeout=a.timeout) as s:
        s.sendall((' '.join(a.command) + '\n').encode())
        s.shutdown(socket.SHUT_WR)
        result = bytearray()
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            result.extend(chunk)
except OSError as error:
    sys.exit(f'Bridge unavailable: {error}')
reply = result.decode('utf-8', errors='replace')
print(reply, end='')
if reply.startswith('ERR '):
    sys.exit(1)
