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
def string(v):
    v=re.sub(r'(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----',mark,v)
    v=query.sub(r'\1'+mark,v)
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
