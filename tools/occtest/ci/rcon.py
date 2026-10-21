#!/usr/bin/env python3
"""One Source RCON command.

Usage: rcon.py HOST PORT PASSWORD COMMAND [timeout_seconds]
Prints the reply on stdout. Auth and transport errors go to stderr and exit 1.
"""
import socket
import struct
import sys


def send(sock, req_id, kind, body):
    payload = struct.pack("<ii", req_id, kind) + body.encode("utf-8", "replace") + b"\x00\x00"
    sock.sendall(struct.pack("<i", len(payload)) + payload)


def recvn(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("rcon connection closed")
        buf += chunk
    return buf


def recv(sock):
    (size,) = struct.unpack("<i", recvn(sock, 4))
    if size < 10 or size > 8_000_000:
        raise RuntimeError("bad rcon packet size %d" % size)
    data = recvn(sock, size)
    rid, kind = struct.unpack_from("<ii", data)
    return rid, kind, data[8:-2].decode("utf-8", "replace")


def main():
    if len(sys.argv) < 5:
        sys.stderr.write("usage: rcon.py HOST PORT PASSWORD COMMAND [timeout]\n")
        return 2
    host, port, password, command = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    timeout = float(sys.argv[5]) if len(sys.argv) > 5 else 20.0
    sock = socket.create_connection((host, port), timeout=timeout)
    try:
        sock.settimeout(timeout)
        send(sock, 1, 3, password)
        authed = False
        for _ in range(4):
            rid, kind, _ = recv(sock)
            if kind == 2:
                if rid == -1:
                    sys.stderr.write("rcon auth rejected\n")
                    return 1
                authed = True
                break
        if not authed:
            sys.stderr.write("no rcon auth response\n")
            return 1
        send(sock, 2, 2, command)
        send(sock, 3, 0, "")
        parts = []
        while True:
            rid, _, body = recv(sock)
            if rid == 3:
                break
            if rid == 2:
                parts.append(body)
    finally:
        sock.close()
    text = "".join(parts)
    sys.stdout.write(text)
    if text and not text.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        sys.stderr.write("rcon error: %s\n" % exc)
        sys.exit(1)
