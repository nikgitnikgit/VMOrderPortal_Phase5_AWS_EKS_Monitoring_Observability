"""tests/fake_prometheus.py -- a Prometheus that lies, on purpose.

Drives scripts/monitoring-gate.sh through its failure modes without a
cluster. Every mode returns HTTP 200, because that is the point: a real
Prometheus answers 200 with {"status":"error"} in the body, and a gate that
trusts the status code sees success.

  empty       success status, empty result vector -- "no data"
  error200    HTTP 200 carrying an error body
  healthy     everything within SLO
  badlatency  p95 of 3.5s against a 0.5s SLO
  wrongsha    healthy, but no pod reports the commit being deployed

Used by T18.18 and T18.19. The gate has to FAIL four of these and PASS one;
a gate that cannot fail is decoration, and a gate that cannot pass blocks
every release.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
MODE = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        q = parse_qs(urlparse(self.path).query).get("query", [""])[0]
        if MODE == "empty":                      # reason 1: no data
            body = {"status":"success","data":{"resultType":"vector","result":[]}}
        elif MODE == "error200":                 # reason 2: 200 + error body
            body = {"status":"error","errorType":"bad_data","error":"parse error"}
        elif MODE == "healthy":
            v = {"vector(1)":"1","count(up":"3","count(app_build_info":"2"}
            val = "0.001" if "http_requests_total" in q else \
                  "0.12" if "histogram_quantile" in q else \
                  next((x for k,x in v.items() if q.startswith(k)), "1")
            body = {"status":"success","data":{"resultType":"vector",
                    "result":[{"metric":{},"value":[0,val]}]}}
        elif MODE == "badlatency":
            val = "0.001" if "http_requests_total" in q else \
                  "3.5" if "histogram_quantile" in q else "3"
            body = {"status":"success","data":{"resultType":"vector",
                    "result":[{"metric":{},"value":[0,val]}]}}
        elif MODE == "wrongsha":
            if "app_build_info" in q:
                body = {"status":"success","data":{"resultType":"vector","result":[]}}
            else:
                val = "0.001" if "http_requests_total" in q else \
                      "0.1" if "histogram_quantile" in q else "3"
                body = {"status":"success","data":{"resultType":"vector",
                        "result":[{"metric":{},"value":[0,val]}]}}
        self.send_response(200)                  # ALWAYS 200 — the point
        self.send_header("Content-Type","application/json"); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
