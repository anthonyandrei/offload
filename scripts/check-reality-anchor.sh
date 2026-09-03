#!/usr/bin/env bash
set -euo pipefail
input=''; scratch=''
while (($#)); do
  case "$1" in
    --input) shift; input=${1:-} ;;
    --scratch-root) shift; scratch=${1:-} ;;
    --json) ;;
    *) echo '{"status":"unverified","reason":"unknown argument"}'; exit 1 ;;
  esac
  shift
done
if [[ -z "$input" || -z "$scratch" ]]; then echo '{"status":"unverified","reason":"usage requires --input and --scratch-root"}'; exit 1; fi
python3 - "$input" "$scratch" <<'PY'
import json, os, sys
def fail(msg):
    print(json.dumps({'status':'unverified','reason':msg}, separators=(',', ':')))
    raise SystemExit(1)
try:
    with open(sys.argv[1], encoding='utf-8') as f: claim=json.load(f)
except Exception as exc: fail(f'invalid anchor JSON: {exc}')
kind=str(claim.get('claim_type',''))
if not any(x in kind.lower() for x in ('browser','headless','gui','render')):
    print(json.dumps({'status':'not_required','reason':'claim is not browser or headless'}, separators=(',', ':')))
    raise SystemExit(0)
artifact_type=str(claim.get('artifact_type','')); artifact=str(claim.get('artifact_path',''))
claim_text=str(claim.get('claim') or claim.get('criterion') or kind)
if not artifact_type or not artifact or not claim_text: fail('browser/headless anchor requires artifact_type, artifact_path, and claim or criterion')
root=os.path.realpath(sys.argv[2]); candidate=os.path.realpath(artifact if os.path.isabs(artifact) else os.path.join(root, artifact))
try: inside=os.path.commonpath((root,candidate)) == root
except ValueError: inside=False
if not inside: fail(f'anchor path is outside scratch root: {candidate}')
if os.path.islink(candidate) or not os.path.isfile(candidate): fail(f'anchor artifact is missing or not a regular file: {candidate}')
print(json.dumps({'status':'verified','artifact_type':artifact_type,'artifact_path':candidate,'claim':claim_text}, separators=(',', ':')))
PY
