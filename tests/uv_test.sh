#!/usr/bin/env bash
# uv/action.yml (uv に ID トークンを渡す composite の Action) の step を抜き出し、偽の ID トークンの発行元で動かして確かめる。
# 本物の registry への uv add・uv publish は確かめない。
# 要るもの: python3・jq・yq (jq の書き方が通るもの)・curl。使い方: bash tests/uv_test.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
action="$root/uv/action.yml"
work=$(mktemp -d)
port=${UV_TEST_PORT:-5101}
failures=0
server=""

cleanup() {
  if [ -n "$server" ]; then kill "$server" 2> /dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

script=$(yq -r '.runs.steps[] | select(.id == "credentials") | .run' "$action")
if [ -z "$script" ] || [ "$script" = "null" ]; then
  echo "uv/action.yml に id: credentials の step がありません" >&2
  exit 1
fi
printf '%s\n' "$script" > "$work/credentials.sh"

# step を GitHub Actions の bash と同じオプションで動かす。$GITHUB_ENV は $work/env、出力は $work/log に書かれる
run_step() {
  : > "$work/env"
  env GITHUB_ENV="$work/env" "$@" bash --noprofile --norc -eo pipefail "$work/credentials.sh" > "$work/log" 2>&1
}

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1" >&2
  failures=$((failures + 1))
}

# 偽の ID トークンの発行元 (GET /token)。求められた audience を $work/token-audience に書く。/bad は JWT でない値を返す
cat > "$work/server.py" <<'PY'
import http.server, json, sys, urllib.parse

work = sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path not in ("/token", "/bad") or self.headers.get("Authorization") != "bearer request-token":
            self.send_response(401)
            self.end_headers()
            return
        audience = urllib.parse.parse_qs(url.query).get("audience", [""])[0]
        with open(f"{work}/token-audience", "w") as f:
            f.write(audience)
        value = "header.payload.signature" if url.path == "/token" else "not a jwt"
        body = json.dumps({"value": value}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
python3 "$work/server.py" "$port" "$work" &
server=$!
for _ in $(seq 1 30); do
  curl -s -o /dev/null "http://127.0.0.1:$port/" && break
  sleep 0.2
done

issuer=(ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$port/token?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token)

# ---- $GITHUB_ENV に書く値 ----

expected='UV_INDEX_INTERNAL_USERNAME=__token__
UV_INDEX_INTERNAL_PASSWORD=header.payload.signature
UV_PUBLISH_USERNAME=__token__
UV_PUBLISH_PASSWORD=header.payload.signature'
if run_step HOST=Registry.Example.IO INDEX=internal "${issuer[@]}" && [ "$(cat "$work/env")" = "$expected" ]; then
  pass "index と uv publish の資格情報を \$GITHUB_ENV に書く"
else
  fail "\$GITHUB_ENV が違う: $(cat "$work/env" "$work/log")"
fi

if [ "$(cat "$work/token-audience")" = "https://registry.example.io/v2" ]; then
  pass "audience は https://<小文字の host>/v2"
else
  fail "audience が違う: $(cat "$work/token-audience")"
fi

if grep -qxF "::add-mask::header.payload.signature" "$work/log"; then
  pass "トークンを ::add-mask:: する"
else
  fail "トークンを ::add-mask:: していない"
fi

if [ "$(grep -c "header.payload.signature" "$work/log")" = "1" ]; then
  pass "トークンは ::add-mask:: のほかにログに出さない"
else
  fail "トークンがログに出ている"
fi

if run_step HOST=registry.example.io INDEX=my-index.v2 "${issuer[@]}" &&
  grep -qxF "UV_INDEX_MY_INDEX_V2_USERNAME=__token__" "$work/env" &&
  grep -qxF "UV_INDEX_MY_INDEX_V2_PASSWORD=header.payload.signature" "$work/env"; then
  pass "index の名前は、大文字にして英数字のほかを _ にする"
else
  fail "index の名前の変換が違う: $(cat "$work/env")"
fi

# ---- 断る ----

rejects() { # <説明> <ログに出るはずの文字> <env...>
  local title=$1 message=$2
  shift 2
  if run_step "$@"; then
    fail "$title: 成功した"
  elif [ -s "$work/env" ]; then
    fail "$title: 失敗したのに \$GITHUB_ENV に書いた"
  elif grep -q -- "$message" "$work/log"; then
    pass "$title"
  else
    fail "$title: エラーの文が違う: $(cat "$work/log")"
  fi
}

rejects "host が無いと断る" "with: host" HOST= INDEX=internal "${issuer[@]}"
rejects "スキームを付けた host は断る" "スキーム" HOST=https://registry.example.io INDEX=internal "${issuer[@]}"
rejects "パスを付けた host は断る" "スキーム" HOST=registry.example.io/python INDEX=internal "${issuer[@]}"
rejects "index が空なら断る" "tool.uv.index" HOST=registry.example.io INDEX= "${issuer[@]}"
rejects "index に改行があれば断る (\$GITHUB_ENV に行を足させない)" "tool.uv.index" HOST=registry.example.io INDEX=$'internal\nFOO=bar' "${issuer[@]}"
rejects "index に = があれば断る" "tool.uv.index" HOST=registry.example.io INDEX="a=b" "${issuer[@]}"
rejects "id-token: write が無ければ案内して失敗する" "id-token: write" HOST=registry.example.io INDEX=internal ACTIONS_ID_TOKEN_REQUEST_URL= ACTIONS_ID_TOKEN_REQUEST_TOKEN=
rejects "ID トークンを取れなければ失敗する" "取得できませんでした" HOST=registry.example.io INDEX=internal \
  ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$port/token?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=wrong
rejects "応答が JWT の形でなければ失敗する" "JWT の形" HOST=registry.example.io INDEX=internal \
  ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$port/bad?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures 件失敗" >&2
  exit 1
fi
echo "すべて通った"
