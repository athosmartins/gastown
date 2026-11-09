# fakeapi2.py: como a fakeapi.py, mas o arquivo de roteiro pode ser uma LISTA de ferramentas (uma por rodada): Read e depois Edit, que o Edit exige.
import http.server, json, sys
PORTFILE, LOG, PLAN = sys.argv[1:4]
def ev(t, d): return ("event: %s\ndata: %s\n\n" % (t, json.dumps(d))).encode()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, ctype, out):
        self.send_response(code); self.send_header("content-type", ctype); self.send_header("content-length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def do_GET(self): self.reply(200, "application/json", b'{"data": []}')
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        try: j = json.loads(body)
        except Exception: j = {}
        with open(LOG, "a") as f: f.write(json.dumps({"path": self.path, "body": j}) + "\n")
        if "/v1/messages" not in self.path or "count_tokens" in self.path:
            return self.reply(200, "application/json", b'{"input_tokens": 10}')
        msgs = j.get("messages", [])
        step = sum(1 for m in msgs if isinstance(m.get("content"), list) for b in m["content"] if b.get("type") == "tool_result")  # quantos resultados de ferramenta ja voltaram = passo atual do roteiro
        tools = [t.get("name") for t in j.get("tools", [])]
        plan = json.load(open(PLAN))
        plan = plan if isinstance(plan, list) else [plan]  # roteiro: lista de ferramentas, uma por rodada (um dict so = uma ferramenta, como na fakeapi.py)
        cur = plan[step] if step < len(plan) else {"name": "none", "input": {}}
        out = ev("message_start", {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "model": j.get("model", "m"), "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}})
        if cur["name"] in tools:
            out += ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_%d" % step, "name": cur["name"], "input": {}}})
            out += ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": json.dumps(cur["input"])}})
            out += ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            out += ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None}, "usage": {"output_tokens": 5}})
        else:
            out += ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            out += ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "FIM"}})
            out += ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            out += ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 2}})
        out += ev("message_stop", {"type": "message_stop"})
        self.reply(200, "text/event-stream", out)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORTFILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
