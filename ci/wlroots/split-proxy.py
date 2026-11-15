#!/usr/bin/env python3
"""Relay real Sway traffic, delivering server events one message/read at a time.

Ancillary descriptors are forwarded and closed, never decoded. Tests use fixture
content only. The send-queue barrier is the same as the scripted ext regression:
an event is read by the client before the next event is sent.
"""
import array
import fcntl
import os
import socket
import struct
import sys
import threading
import time

upstream, endpoint, logpath = sys.argv[1:]
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(endpoint)
listener.listen()
lock = threading.Lock()


def note(message):
    with lock, open(logpath, "a", encoding="utf-8") as log:
        log.write(message + "\n")


def relay(source, target, split, objects):
    buffered = b""
    descriptors = []
    try:
        while True:
            data, ancillary, flags, _ = source.recvmsg(65536, socket.CMSG_SPACE(256))
            if not data:
                break
            if flags & socket.MSG_CTRUNC:
                raise RuntimeError("truncated ancillary descriptors")
            for level, kind, payload in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    received = array.array("i")
                    received.frombytes(payload[:len(payload) - len(payload) % received.itemsize])
                    descriptors.extend(received)
            buffered += data
            while len(buffered) >= 8:
                object_id, header = struct.unpack_from("=II", buffered)
                size, opcode = header >> 16, header & 65535
                if size < 8:
                    raise RuntimeError("invalid Wayland frame")
                if len(buffered) < size:
                    break
                frame, buffered = buffered[:size], buffered[size:]
                interface = objects.get(object_id)
                if not split:
                    if interface == "wl_display" and opcode == 1:
                        objects[struct.unpack_from("=I", frame, 8)[0]] = "wl_registry"
                    elif interface == "wl_registry" and opcode == 0:
                        length = struct.unpack_from("=I", frame, 12)[0]
                        objects[struct.unpack_from("=I", frame, size - 4)[0]] = frame[16:16 + length - 1].decode()
                    elif interface == "zwlr_data_control_manager_v1" and opcode == 1:
                        objects[struct.unpack_from("=I", frame, 8)[0]] = "zwlr_data_control_device_v1"
                elif interface == "zwlr_data_control_device_v1" and opcode == 0:
                    objects[struct.unpack_from("=I", frame, 8)[0]] = "zwlr_data_control_offer_v1"
                    note("split data_offer")
                elif interface == "zwlr_data_control_offer_v1" and opcode == 0:
                    note("split MIME offer")
                elif interface == "zwlr_data_control_device_v1" and opcode == 1:
                    note("split selection")
                control = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", descriptors))] if descriptors else []
                sent = target.sendmsg([frame], control)
                for descriptor in descriptors:
                    os.close(descriptor)
                descriptors.clear()
                target.sendall(frame[sent:])
                if split:
                    # SIOCOUTQ is zero once the peer read the message. Keep a scheduling
                    # boundary too, as in the ext fixture's separate timer dispatches.
                    deadline = time.monotonic() + 15
                    while struct.unpack("i", fcntl.ioctl(target, 0x5411, struct.pack("i", 0)))[0]:
                        if time.monotonic() > deadline:
                            raise TimeoutError("client did not consume split event")
                        time.sleep(0.001)
                    time.sleep(0.005)
    except (BrokenPipeError, ConnectionResetError):
        pass  # A test client closed its owned connection during teardown.
    except Exception as error:
        note("PROXY_ERROR " + repr(error))
        raise
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
        for peer in (source, target):
            try:
                peer.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass  # The other direction may already have shut down this pair.


while True:
    client, _ = listener.accept()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.connect(upstream)
    objects = {1: "wl_display"}
    threading.Thread(target=relay, args=(client, server, False, objects), daemon=True).start()
    threading.Thread(target=relay, args=(server, client, True, objects), daemon=True).start()
