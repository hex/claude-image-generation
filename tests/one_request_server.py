# ABOUTME: Serves one HTTP request on a free local port: saves the whole raw request, then
# ABOUTME: answers 200 with a canned JSON body. Lets a bats test read exactly what curl sent.
import os
import re
import socket
import sys

port_file, request_file, body_file = sys.argv[1:4]
with open(body_file, "rb") as f:
    body = f.read()

server = socket.socket()
server.settimeout(10)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.getsockname()[1]))
os.rename(port_file + ".tmp", port_file)

conn, _ = server.accept()
conn.settimeout(10)
data = b""
while b"\r\n\r\n" not in data:
    chunk = conn.recv(65536)
    if not chunk:
        sys.exit("connection closed before the request headers ended")
    data += chunk
head, _, rest = data.partition(b"\r\n\r\n")
if re.search(rb"(?im)^expect:\s*100-continue", head):
    conn.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
match = re.search(rb"(?im)^content-length:\s*(\d+)", head)
length = int(match.group(1)) if match else 0
while len(rest) < length:
    chunk = conn.recv(65536)
    if not chunk:
        sys.exit("connection closed after %d of %d body bytes" % (len(rest), length))
    rest += chunk

with open(request_file, "wb") as f:
    f.write(head + b"\r\n\r\n" + rest)
conn.sendall(
    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n"
    b"Connection: close\r\n\r\n" % len(body) + body
)
conn.close()
