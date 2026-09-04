#!/usr/bin/env bash
set -euo pipefail
input=''; output=''
while (($#)); do
  case "$1" in
    --input) shift; input=${1:-} ;;
    --output) shift; output=${1:-} ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$input" && -n "$output" ]] || { echo 'usage: --input <json> --output <json>' >&2; exit 2; }
python3 - "$input" "$output" <<'PY'
import json, re, sys
mark='[REDACTED]'
query=re.compile(r'''(?i)([?&](?:access_token|refresh_token|id_token|token|api[_-]?key|secret|password|key)=)[^&#\s"']+''')
assign=re.compile(r'''(?i)\b(password|secret|token|api[_-]?key)\s*([=:])\s*(?:"[^"]*"|'[^']*'|[^\s,;&]+)''')
common_words = r"header|headers|failed|failure|required|requirement|denied|error|check|status|code|granted|missing|rejected|was|is|rule|rules|policy|policies|flow|attempt|request|requests|diagnostic|diagnostics|completed|endpoint|level|context|type|mode|info|information|parameter|param|params|service"
param_header = re.compile(rf"""(?i)\b(authorization|proxy-authorization)(?::\s*|\s+(?!{common_words}\b))([A-Za-z0-9_.-]+)\s+([A-Za-z0-9_.-]+\s*=\s*(?:"[^"]*"|'[^']*'|[A-Za-z0-9_.~+-]+)(?:\s*,\s*[A-Za-z0-9_.-]+\s*=\s*(?:"[^"]*"|'[^']*'|[A-Za-z0-9_.~+-]+))*)""")
token_header = re.compile(rf"""(?i)\b(authorization|proxy-authorization)(:\s*|\s+(?!{common_words}\b))([A-Za-z0-9_.-]+)\s+(?![A-Za-z0-9_.-]+\s*=\s*(?:"[^"]*"|'[^']*'|[A-Za-z0-9_.~+-]+))([^\s,;]+)""")
param_secret = re.compile(r"""(?i)\b(response|mac|signature|secret|password|token|api[_-]?key|key|credential|credentials|auth[_-]?token)\s*=\s*(?:"[^"]*"|'[^']*'|[A-Za-z0-9_.~+-]+)""")

def sub_param(m):
    p = m.group(0)[:len(m.group(0)) - len(m.group(3))]
    redacted_params = param_secret.sub(r'\1=' + mark, m.group(3))
    return p + redacted_params

def string(v):
    v=re.sub(r'(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----',mark,v)
    v=query.sub(r'\1'+mark,v)
    v=param_header.sub(sub_param,v)
    v=token_header.sub(r'\1\2\3 '+mark,v)
    v=re.sub(r'(?i)\b(Bearer)\s+[^\s,;]+',r'\1 '+mark,v)
    v=assign.sub(r'\1\2'+mark,v)
    return re.sub(r'(?i)\b(cookie|set-cookie)\s*:\s*[^\r\n]+',r'\1: '+mark,v)
def redact(v):
    if isinstance(v,str): return string(v)
    if isinstance(v,dict):
        return {k:(mark if re.fullmatch(r'(?i)(authorization|proxy-authorization|cookie|set-cookie|password|secret|token|api[_-]?key)',str(k)) else redact(x)) for k,x in v.items()}
    if isinstance(v,list): return [redact(x) for x in v]
    return v
with open(sys.argv[1],encoding='utf-8') as f: data=json.load(f)
with open(sys.argv[2],'w',encoding='utf-8') as f: json.dump(redact(data),f,indent=2); f.write('\n')
PY
