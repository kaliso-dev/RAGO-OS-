#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — agent de la console série du test VM M3.
#
# Se branche sur la console série de la VM (socket unix de qemu) et surveille
# les demandes de passphrase de systemd-cryptsetup (« passphrase for disk ») :
#   type    tape la passphrase de secours, comme le joueur au clavier
#           (démarrage où le TPM doit refuser : Secure Boot changé) ;
#   forbid  une demande = ÉCHEC (le TPM devait déverrouiller tout seul) :
#           code 10, la VM est arrêtée par run_m3_vm_test.sh.
#
# Usage : m3_serial_agent.py <socket> <type|forbid> <fichier passphrase> <délai s> <fichier résultat>
import re
import socket
import sys
import time

sock_path, mode, pass_file, timeout, result_file = sys.argv[1:6]
deadline = time.time() + float(timeout)
PROMPT = re.compile(rb"(?i)passphrase for (disk )?")


def result(text, code):
    with open(result_file, "w", encoding="utf-8") as f:
        f.write(text + "\n")
    sys.exit(code)


with open(pass_file, "rb") as f:
    secret = f.read().rstrip(b"\r\n")

conn = None
connect_deadline = min(deadline, time.time() + 120)
while time.time() < connect_deadline:
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.connect(sock_path)
        break
    except OSError:
        conn.close()
        conn = None
        time.sleep(0.2)
if conn is None:
    result("no-connect", 2)

conn.settimeout(1.0)
tail = b""
prompts = 0
typed = 0
while time.time() < deadline:
    try:
        data = conn.recv(65536)
    except socket.timeout:
        continue
    except OSError:
        break
    if not data:
        break  # qemu s'est arrêté
    tail += data
    while True:
        m = PROMPT.search(tail)
        if not m:
            break
        tail = tail[m.end():]
        prompts += 1
        if mode == "forbid":
            result(f"prompt-forbidden prompts={prompts}", 10)
        if typed < 4:
            time.sleep(1.5)  # laisser l'invite prête à lire
            conn.sendall(secret + b"\r")
            typed += 1
    tail = tail[-256:]  # une invite coupée entre deux lectures

result(f"prompts={prompts} typed={typed}", 0)
