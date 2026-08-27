import yaml, re, sys, glob, os
import kubernetes_validate
os.chdir(os.path.join(os.path.dirname(__file__), "..", "helm"))
def get(values, path):
    cur = values
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur: return None
        cur = cur[part]
    return cur
def render(tpl, values):
    # REVIEW FIX 4.4 — conditionals are tracked with a STACK, not a flat
    # depth counter plus a single `skip` flag. The old model only evaluated
    # the condition at depth 1, so an inner `if` nested inside the chart-wide
    # `{{- if .Values.ingress.enabled }}` was never evaluated at all and BOTH
    # branches were emitted. That produced invalid YAML for the HTTPS ingress
    # and would have silently mis-rendered any future nested conditional.
    out, stack, lines, i = [], [], tpl.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        mif = re.match(r"\s*\{\{-? if (?:\.Values\.)([\w.]+) \}\}", line)
        mend = re.match(r"\s*\{\{-? end \}\}", line)
        # REVIEW FIX 4.4 — {{- else }} support. helm/frontend/templates/
        # ingress.yaml needs it to emit HTTPS annotations when a certificate is
        # configured and plain HTTP when it is not. Without this the renderer
        # emitted BOTH branches and produced invalid YAML.
        melse = re.match(r"\s*\{\{-? else \}\}", line)
        mrange = re.match(r"(\s*)\{\{-? range \$key, \$val := \.Values\.([\w.]+) \}\}", line)
        # REVIEW FIX 4.6 — list ranges, e.g. {{- range .Values.a.b }} ... {{ . }}
        mrangelist = re.match(r"(\s*)\{\{-? range \.Values\.([\w.]+) \}\}", line)
        if mif:
            stack.append(bool(get(values, mif.group(1))))
            i += 1; continue
        if mend:
            if stack: stack.pop()
            i += 1; continue
        if melse:
            if stack: stack[-1] = not stack[-1]
            i += 1; continue
        if not all(stack): i += 1; continue
        if mrangelist:
            path, body = mrangelist.group(2), []
            i += 1
            while not re.match(r"\s*\{\{-? end \}\}", lines[i]):
                body.append(lines[i]); i += 1
            i += 1
            for item in (get(values, path) or []):
                for b in body:
                    out.append(b.replace("{{ . }}", str(item)))
            continue
        if mrange:
            path, body = mrange.group(2), []
            i += 1
            while not re.match(r"\s*\{\{-? end \}\}", lines[i]):
                body.append(lines[i]); i += 1
            i += 1
            for k, v in (get(values, path) or {}).items():
                for b in body:
                    out.append(b.replace("{{ $key }}", str(k)).replace("{{ $val | quote }}", chr(34)+str(v)+chr(34)))
            continue
        line = re.sub(r"\{\{ include \(print \$\.Template\.BasePath .*?\| sha256sum \}\}", "dummychecksum", line)
        # PHASE 5 — the renderer had to learn four more forms, because the
        # observability templates use them and an unrendered "{{" produces
        # invalid YAML rather than a useful error.
        #
        # Kept deliberately narrow: this is a stand-in that lets the STRICT
        # Kubernetes schema check run with no helm binary, not a Helm
        # reimplementation. `helm template` itself is exercised by T18.4.
        #
        # 1. inline conditional:  {{ if .Values.a }}text{{ end }}

        def _inline_if(m):
            return m.group(2) if get(values, m.group(1)) else ""
        line = re.sub(r"\{\{ if \.Values\.([\w.]+) \}\}(.*?)\{\{ end \}\}", _inline_if, line)
        # 2. {{ .Values.a | default .Values.b | quote }} and the two-term form.
        #    `default` in Helm falls back when the left side is EMPTY, which is
        #    exactly how build.version falls back to image.tag.

        def _default_chain(m):
            v = get(values, m.group(1))
            if not v:
                v = get(values, m.group(2))
            return chr(34) + str(v or "") + chr(34)
        line = re.sub(r"\{\{ \.Values\.([\w.]+) \| default \.Values\.([\w.]+) \| quote \}\}",
                      _default_chain, line)
        line = re.sub(r"\{\{ \.Values\.([\w.]+) \| default \.Release\.Name \| quote \}\}",
                      lambda m: chr(34) + str(get(values, m.group(1)) or "release") + chr(34), line)
        # 3. {{ .Values.a | quote }}
        line = re.sub(r"\{\{ \.Values\.([\w.]+) \| quote \}\}",
                      lambda m: chr(34) + str(get(values, m.group(1)) or "") + chr(34), line)
        # 4. {{ .Release.Namespace }} / {{ .Release.Name }}
        line = line.replace("{{ .Release.Namespace }}", "devops-app")
        line = line.replace("{{ .Release.Name }}", "release")
        line = re.sub(r"\{\{ \.Values\.([\w.]+) \}\}", lambda m: str(get(values, m.group(1)) or ""), line)
        out.append(line); i += 1
    return "\n".join(out)
errors, count, crds = [], 0, 0
for chart in ["backend", "worker", "frontend"]:
    values = yaml.safe_load(open(f"{chart}/values.yaml"))
    values["image"]["registry"] = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
    if values.get("serviceAccount", {}).get("roleArn") == "" and chart != "frontend":
        values["serviceAccount"]["roleArn"] = "arn:aws:iam::123456789012:role/test"
    for k in values.get("config", {}):
        if values["config"][k] == "": values["config"][k] = "test-value"
    for t in sorted(glob.glob(f"{chart}/templates/*.yaml")):
        rendered = render(open(t).read(), values)
        if not rendered.strip(): continue
        docs = [d for d in yaml.safe_load_all(rendered) if d]
        for d in docs:
            # Custom resources (ServiceMonitor, PrometheusRule) have no builtin
            # Kubernetes schema, so kubernetes_validate cannot check them. They
            # are validated by kubeconform against tests/crd-schemas/ instead.
            # Counted separately rather than folded into the pass count: a
            # skipped check must never be reported as a passed one.
            if d.get("apiVersion", "").startswith("monitoring.coreos.com/"):
                crds += 1
                continue
            count += 1
            try: kubernetes_validate.validate(d, "1.35", strict=True)
            except Exception as e: errors.append(f"{t}: {e}")
if errors:
    print("\n".join(errors)); sys.exit(1)
print(f"{count} manifests valid (K8s 1.35 strict); "
      f"{crds} custom resources skipped here, validated by kubeconform")
