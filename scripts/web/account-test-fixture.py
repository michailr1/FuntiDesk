# Только локальная проверка браузера: SMTP capture, реестр ключей и proxy.
import email
import email.policy
import http.client
import http.server
import json
import re
import socketserver
import sys
import sqlite3
import threading
from pathlib import Path

backend_port=int(sys.argv[1])
socket_path=sys.argv[2]
database_path=sys.argv[3]
messages=[]
keys={}

class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        self.wfile.write(b'220 localhost ESMTP\r\n')
        while True:
            line=self.rfile.readline()
            if not line: return
            command=line.split(b' ',1)[0].strip().upper()
            if command==b'EHLO':
                self.wfile.write(b'250-localhost\r\n250 8BITMIME\r\n')
            elif command==b'DATA':
                self.wfile.write(b'354 End data\r\n')
                payload=b''
                while True:
                    part=self.rfile.readline()
                    if part==b'.\r\n': break
                    if not part: return
                    payload+=part
                message=email.message_from_bytes(payload,policy=email.policy.default)
                text=message.get_body(preferencelist=('plain',)).get_content() if message.is_multipart() else message.get_content()
                match=re.search(r'\b[0-9]{6}\b',text)
                if match: messages.append({'to':str(message['To']),'code':match.group()})
                self.wfile.write(b'250 accepted\r\n')
            elif command==b'QUIT':
                self.wfile.write(b'221 bye\r\n');return
            else:self.wfile.write(b'250 ok\r\n')

class Registry(socketserver.StreamRequestHandler):
    def handle(self):
        request=json.loads(self.rfile.readline())
        self.wfile.write(json.dumps({'pk':keys.get(request['id'])}).encode()+b'\n')

class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):self.handle_request()
    def do_POST(self):self.handle_request()
    def handle_request(self):
        body=self.rfile.read(int(self.headers.get('Content-Length',0)))
        if self.path=='/test/inbox':
            payload=json.dumps(messages).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(payload);return
        if self.path=='/test/advance-minute':
            with sqlite3.connect(database_path) as db:db.execute('DELETE FROM rate_limits WHERE period=60')
            self.send_response(204);self.end_headers();return
        if self.path=='/test/keys':
            keys.update(json.loads(body));self.send_response(204);self.end_headers();return
        conn=http.client.HTTPConnection('127.0.0.1',backend_port,timeout=30)
        headers={k:v for k,v in self.headers.items() if k.lower() not in ['host','connection','content-length']}
        headers['Host']='desk.funti.cc'
        try:
            conn.request(self.command,self.path,body,headers)
            response=conn.getresponse();payload=response.read();self.send_response(response.status)
            for k,v in response.getheaders():
                if k.lower() not in ['transfer-encoding','connection','content-length']:self.send_header(k,v)
            self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
        except OSError:
            self.send_response(503);self.send_header('Content-Length','0');self.end_headers()
        finally:conn.close()

smtp=socketserver.ThreadingTCPServer(('127.0.0.1',0),SMTP)
registry=socketserver.ThreadingUnixStreamServer(socket_path,Registry)
proxy=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy)
for server in [smtp,registry,proxy]:
    threading.Thread(target=server.serve_forever,daemon=True).start()
print(json.dumps({'proxy_port':proxy.server_address[1],'smtp_port':smtp.server_address[1]}),flush=True)
threading.Event().wait()
