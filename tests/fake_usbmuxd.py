#!/usr/bin/env python3
# Minimal fake of usbmuxd's plist protocol for tests/smoke.sh.
#
# Modes:
#   fake_usbmuxd.py SOCK UDID RECORD_OUT              one stored ReadPairRecord, then exit
#   fake_usbmuxd.py SOCK UDID - --live-pair MODE      serve the live-pairing flow:
#                                                     ListDevices / ReadBUID / no stored
#                                                     record / Connect to a scripted
#                                                     lockdownd (MODE = ok | denied | locked)
import base64
import os
import plistlib
import socket
import struct
import subprocess
import sys
import tempfile

OSSL = "/usr/bin/openssl"


def recvn(sock, n):
    b = b""
    while len(b) < n:
        c = sock.recv(n - len(b))
        if not c:
            raise EOFError("closed")
        b += c
    return b


def read_message(sock):
    hdr = recvn(sock, 16)
    return plistlib.loads(recvn(sock, struct.unpack("<I", hdr[:4])[0] - 16))  # length includes the header


def send_message(sock, msg):
    payload = plistlib.dumps(msg, fmt=plistlib.FMT_XML)
    sock.sendall(struct.pack("<IIII", len(payload) + 16, 1, 8, 1) + payload)


def serve_one_shot(sock_path, expect_udid, record_out):
    record = plistlib.dumps({
        "DeviceCertificate": b"\x30\x03\x02\x01\x05",
        "HostCertificate": b"\x30\x03\x02\x01\x06",
        "HostID": "SIDEX-TEST-HOST",
        "SystemBUID": "SIDEX-TEST-BUID",
    }, fmt=plistlib.FMT_BINARY)
    srv = socket.socket(socket.AF_UNIX)
    srv.bind(sock_path)
    srv.listen(1)
    srv.settimeout(30)  # don't hang smoke.sh forever if sidex never connects
    conn, _ = srv.accept()
    req = read_message(conn)
    ok = req.get("MessageType") == "ReadPairRecord" and req.get("PairRecordID") == expect_udid
    resp = {"MessageType": "Result", "Number": 0 if ok else 5}
    if ok:
        resp["PairRecordData"] = record
    send_message(conn, resp)
    if ok and record_out != "-":
        with open(record_out, "wb") as f:
            f.write(record)
    conn.close()
    srv.close()


def device_public_key():
    """PKCS#1 PEM pubkey + the key path (the TLS fake needs the matching private key)."""
    tmp = tempfile.mkdtemp(prefix="fake-usbmuxd-")
    key = os.path.join(tmp, "device.key")
    subprocess.run([OSSL, "genrsa", "-out", key, "2048"], check=True, stderr=subprocess.DEVNULL)
    pub = subprocess.run([OSSL, "rsa", "-in", key, "-pubout", "-RSAPublicKey_out"], check=True,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
    return pub, key


def pem_wrap(der):
    body = base64.encodebytes(der).decode().replace("\n", "")  # 64-char lines
    body = "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
    return "-----BEGIN CERTIFICATE-----\n" + body + "\n-----END CERTIFICATE-----\n"


def serve_lockdown_tls(conn, device_key, record, present_bad):
    """Serve lockdownd over TLS after StartSession, like a real iPhone.

    With a record in hand the server presents exactly the certificate chain from
    that record (the helper pins on it); without one -- or with present_bad --
    a throwaway self-signed certificate that must not survive the pin check.
    """
    import ssl
    tmp = tempfile.mkdtemp(prefix="fake-usbmuxd-tls-")
    crt = os.path.join(tmp, "chain.pem")
    certs = [] if present_bad or not isinstance(record, dict) else \
        [d for d in (record.get("DeviceCertificate"), record.get("RootCertificate")) if isinstance(d, bytes)]
    if certs:
        with open(crt, "wb") as f:
            for der in certs:
                f.write(pem_wrap(der).encode())
    else:
        key, crt2 = os.path.join(tmp, "s.key"), os.path.join(tmp, "s.crt")
        subprocess.run([OSSL, "genrsa", "-out", key, "2048"], check=True, stderr=subprocess.DEVNULL)
        subprocess.run([OSSL, "req", "-x509", "-new", "-key", key, "-subj", "/CN=sidex-fake",
                        "-days", "2", "-out", crt2], check=True, stderr=subprocess.DEVNULL)
        crt, device_key = crt2, key  # bad presentation: random cert + its own key
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(crt, device_key)
    tls = context.wrap_socket(conn, server_side=True)  # detaches conn; client certs are not requested
    try:
        while True:
            try:
                n = struct.unpack(">I", recvn(tls, 4))[0]
                req = plistlib.loads(recvn(tls, n))
            except (EOFError, ConnectionResetError, OSError, ssl.SSLError):
                return
            resp = {"Value": "1.2.3-fake"} if req.get("Request") == "GetValue" \
                else {"Error": "InvalidRequest"}
            data = plistlib.dumps(resp, fmt=plistlib.FMT_XML)
            tls.sendall(struct.pack(">I", len(data)) + data)
    finally:
        try:
            tls.close()
        except OSError:
            pass


def serve_lockdown(conn, mode, device_pub, device_key):
    """lockdownd as the sidex helper sees it: 4-byte big-endian length + plist."""
    pairs = 0
    record = None
    while True:
        try:
            n = struct.unpack(">I", recvn(conn, 4))[0]
            req = plistlib.loads(recvn(conn, n))
        except (EOFError, ConnectionResetError, OSError):
            return
        name = req.get("Request")
        if name == "GetValue" and req.get("Key") == "DevicePublicKey":
            resp = {"Error": "GetProhibited"} if mode == "locked" else {"Value": device_pub}
        elif name == "GetValue" and req.get("Key") == "WiFiAddress":
            resp = {"Value": "aa:bb:cc:dd:ee:ff"}
        elif name == "Pair":
            pairs += 1
            record = req.get("PairRecord")
            if mode == "denied":
                resp = {"Error": "UserDeniedPairing"}
            elif pairs == 1:
                resp = {"Error": "PairingDialogResponsePending"}  # the trust dialog is up
            else:
                resp = {"EscrowBag": b"\x00" * 32}
        elif name == "StartSession":
            if mode in ("tls", "tls-bad"):
                data = plistlib.dumps({"SessionID": "FAKE-TLS", "EnableSessionSSL": True},
                                      fmt=plistlib.FMT_XML)
                conn.sendall(struct.pack(">I", len(data)) + data)
                serve_lockdown_tls(conn, device_key, record, present_bad=mode == "tls-bad")
                return
            resp = {"SessionID": "FAKE-SESSION", "EnableSessionSSL": False}
        else:
            resp = {"Error": "InvalidRequest"}
        data = plistlib.dumps(resp, fmt=plistlib.FMT_XML)
        conn.sendall(struct.pack(">I", len(data)) + data)


def serve_live_pair(sock_path, udid, mode):
    device_pub = None
    srv = socket.socket(socket.AF_UNIX)
    srv.bind(sock_path)
    srv.listen(1)
    srv.settimeout(30)
    device_pub = None
    device_key = None
    while True:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            sys.exit(1)  # sidex never showed up
        try:
            req = read_message(conn)
            mt = req.get("MessageType")
            if mt == "Connect":
                send_message(conn, {"MessageType": "Result", "Number": 0})
                if device_pub is None:
                    device_pub, device_key = device_public_key()
                serve_lockdown(conn, mode, device_pub, device_key)
                sys.exit(0)  # the lockdownd session ends the test
            elif mt == "ListDevices":
                send_message(conn, {"MessageType": "Result", "Number": 0,
                                    "DeviceList": [{"DeviceID": 7,
                                                    "Properties": {"SerialNumber": udid}}]})
            elif mt == "ReadBUID":
                send_message(conn, {"MessageType": "Result", "Number": 0, "BUID": "SIDEX-TEST-BUID"})
            elif mt == "ReadPairRecord":
                send_message(conn, {"MessageType": "Result", "Number": 5})  # no stored record
            else:
                send_message(conn, {"MessageType": "Result", "Number": 1})
        finally:
            conn.close()


def main():
    if len(sys.argv) == 4:
        serve_one_shot(sys.argv[1], sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 6 and sys.argv[3] == "-" and sys.argv[4] == "--live-pair":
        serve_live_pair(sys.argv[1], sys.argv[2], sys.argv[5])
    else:
        sys.exit("usage: fake_usbmuxd.py SOCK UDID RECORD_OUT | SOCK UDID - --live-pair ok|denied|locked|tls|tls-bad")


if __name__ == "__main__":
    main()
