#!/usr/bin/env bash
# publish.yml (イメージの publish の reusable workflow) の step を抜き出し、ローカルの registry (registry:2) で動かして確かめる。
# Google Cloud の認証 (WIF) と AWS の認証 (OIDC で IAM ロールを借りる) は確かめない (本物のクラウドが要るため)。
# docker login は、ローカルの registry と、偽の aws コマンドで確かめる。
# 要るもの: docker・jq・yq (jq の書き方が通るもの)・curl。使い方: bash tests/publish_test.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
workflow="$root/.github/workflows/publish.yml"
work=$(mktemp -d)
port=${REGISTRY_PORT:-5000}
registry="localhost:$port"
container="publish-test-registry-$$"
failures=0

cleanup() {
  docker rm -f "$container" > /dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# publish.yml の id の step の run を取り出す
step_script() {
  local script
  script=$(yq -r ".jobs.publish.steps[] | select(.id == \"$1\") | .run" "$workflow")
  if [ -z "$script" ] || [ "$script" = "null" ]; then
    echo "publish.yml に id: $1 の step がありません" >&2
    return 1
  fi
  printf '%s\n' "$script"
}

# publish.yml の id の step の if を取り出す
step_if() {
  yq -r ".jobs.publish.steps[] | select(.id == \"$1\") | .if" "$workflow"
}

# step を GitHub Actions の bash と同じオプションで動かす。出力は $work/output に書かれる
run_step() {
  local id=$1
  shift
  : > "$work/output"
  step_script "$id" > "$work/$id.sh"
  env GITHUB_OUTPUT="$work/output" GITHUB_ENV="$work/env" GITHUB_STEP_SUMMARY="$work/summary" RUNNER_TEMP="$work" "$@" \
    bash --noprofile --norc -eo pipefail "$work/$id.sh"
}

# publish.yml の id の step の項目 (with・env など) を取り出す
step_field() {
  yq -r ".jobs.publish.steps[] | select(.id == \"$1\") | .$2" "$workflow"
}

output() {
  grep -E "^$1=" "$work/output" | tail -1 | cut -d= -f2-
}

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1" >&2
  failures=$((failures + 1))
}

# ---- 入力の検査 (check) ----

check_env=(IMAGE=sample VERSION=v1.0.0 REPOSITORY=asia-northeast1-docker.pkg.dev/my-project/apps CONTEXT=. FILE=
  CLOUD=google WORKLOAD_IDENTITY_PROVIDER=projects/123/locations/global/workloadIdentityPools/github/providers/github
  SERVICE_ACCOUNT=image-publish@my-project.iam.gserviceaccount.com AWS_ROLE_ARN=)
ecr=123456789012.dkr.ecr.ap-northeast-1.amazonaws.com
aws_env=(IMAGE=sample VERSION=v1.0.0 REPOSITORY="$ecr/apps" CONTEXT=. FILE=
  CLOUD=aws WORKLOAD_IDENTITY_PROVIDER= SERVICE_ACCOUNT= AWS_ROLE_ARN=arn:aws:iam::123456789012:role/image-publish)

# 今の呼び出し元 (cloud を書かない) を変えない
if [ "$(yq -r '.on.workflow_call.inputs.cloud.default' "$workflow")" = "google" ] &&
  [ "$(yq -r '.on.workflow_call.inputs.workload_identity_provider.required' "$workflow")" = "false" ] &&
  [ "$(yq -r '.on.workflow_call.inputs.service_account.required' "$workflow")" = "false" ] &&
  [ "$(yq -r '.on.workflow_call.inputs.aws_role_arn.required' "$workflow")" = "false" ] &&
  [ "$(step_field check env.CLOUD)" = '${{ inputs.cloud }}' ]; then
  pass "inputs: cloud の既定は google で、クラウドごとの入力は check で確かめる"
else
  fail "inputs: cloud の既定か、クラウドごとの入力の required が違う"
fi

if run_step check "${check_env[@]}" CONTEXT=services/api FILE=services/api/Dockerfile.prod > /dev/null; then
  pass "check: リポジトリの中の相対パスの context・file を受け付ける"
else
  fail "check: リポジトリの中の context・file を断った"
fi

if run_step check "${check_env[@]}" > /dev/null; then
  if [ "$(output host)" = "asia-northeast1-docker.pkg.dev" ] &&
    [ "$(output image)" = "asia-northeast1-docker.pkg.dev/my-project/apps/sample" ] &&
    [ "$(output path)" = "my-project/apps/sample" ]; then
    pass "check: 正しい入力から、ホスト・イメージ・パスを出す"
  else
    fail "check: 出力が違う: $(cat "$work/output")"
  fi
else
  fail "check: 正しい入力を断った"
fi

if run_step check IMAGE=Sample VERSION=v1.0.0 REPOSITORY=asia-northeast1-docker.pkg.dev/my-project/apps > /dev/null 2>&1 &&
  [ "$(output image)" = "asia-northeast1-docker.pkg.dev/my-project/apps/sample" ]; then
  fail "check: 大文字のイメージ名を受け付けた"
else
  pass "check: 大文字のイメージ名を断る"
fi

for bad in \
  "IMAGE=../sample" \
  "IMAGE=sample:v1" \
  "IMAGE=" \
  "VERSION=latest" \
  "VERSION=" \
  "VERSION=-v1" \
  "VERSION=v1/2" \
  "REPOSITORY=docker.io/library" \
  "REPOSITORY=https://asia-northeast1-docker.pkg.dev/my-project/apps" \
  "REPOSITORY=asia-northeast1-docker.pkg.dev/my-project" \
  "REPOSITORY=asia-northeast1-docker.pkg.dev/my-project/apps/sample" \
  "CONTEXT=/home/runner" \
  "CONTEXT=.." \
  "CONTEXT=app/../.." \
  "CONTEXT=~" \
  "FILE=/etc/Dockerfile" \
  "FILE=../Dockerfile" \
  "CLOUD=" \
  "CLOUD=azure" \
  "WORKLOAD_IDENTITY_PROVIDER=" \
  "SERVICE_ACCOUNT=" \
  "REPOSITORY=$ecr/apps"; do
  if run_step check "${check_env[@]}" "$bad" > /dev/null 2>&1; then
    fail "check: $bad を受け付けた"
  else
    pass "check: $bad を断る"
  fi
done

# ---- AWS (ECR) の入力の検査 (check) ----

if run_step check "${aws_env[@]}" > /dev/null; then
  if [ "$(output host)" = "$ecr" ] &&
    [ "$(output image)" = "$ecr/apps/sample" ] &&
    [ "$(output path)" = "apps/sample" ] &&
    [ "$(output region)" = "ap-northeast-1" ]; then
    pass "check (aws): ECR のリポジトリから、ホスト・イメージ・パス・リージョンを出す"
  else
    fail "check (aws): 出力が違う: $(cat "$work/output")"
  fi
else
  fail "check (aws): 正しい入力を断った"
fi

if run_step check "${aws_env[@]}" REPOSITORY="$ecr/team/apps" IMAGE=api/worker > /dev/null &&
  [ "$(output image)" = "$ecr/team/apps/api/worker" ] && [ "$(output path)" = "team/apps/api/worker" ]; then
  pass "check (aws): 何段かの接頭辞と、/ を含むイメージ名を受け付ける"
else
  fail "check (aws): 何段かの接頭辞か、/ を含むイメージ名を断った: $(cat "$work/output")"
fi

if run_step check "${aws_env[@]}" REPOSITORY="$ecr" > /dev/null &&
  [ "$(output image)" = "$ecr/sample" ] && [ "$(output path)" = "sample" ]; then
  pass "check (aws): 接頭辞の無いレジストリ (ホストだけ) を受け付ける"
else
  fail "check (aws): ホストだけのレジストリを断った: $(cat "$work/output")"
fi

for bad in \
  "AWS_ROLE_ARN=" \
  "AWS_ROLE_ARN=image-publish" \
  "AWS_ROLE_ARN=arn:aws:iam::12345:role/image-publish" \
  "AWS_ROLE_ARN=arn:aws:iam::123456789012:user/image-publish" \
  "REPOSITORY=asia-northeast1-docker.pkg.dev/my-project/apps" \
  "REPOSITORY=https://$ecr/apps" \
  "REPOSITORY=$ecr/Apps" \
  "REPOSITORY=$ecr/apps/" \
  "REPOSITORY=12345678901.dkr.ecr.ap-northeast-1.amazonaws.com/apps" \
  "REPOSITORY=123456789012.dkr.ecr.ap-northeast-1.example.com/apps" \
  "REPOSITORY=public.ecr.aws/apps" \
  "CONTEXT=.." \
  "VERSION=latest"; do
  if run_step check "${aws_env[@]}" "$bad" > /dev/null 2>&1; then
    fail "check (aws): $bad を受け付けた"
  else
    pass "check (aws): $bad を断る"
  fi
done

# ---- クラウドの認証 (auth・aws-auth) ----

if [ "$(step_if auth)" = "inputs.cloud == 'google'" ] && [ "$(step_if aws-auth)" = "inputs.cloud == 'aws'" ]; then
  pass "auth: Google Cloud と AWS の認証は、選んだクラウドのほうだけ動く"
else
  fail "auth: if が違う: $(step_if auth) / $(step_if aws-auth)"
fi

if [[ "$(step_field aws-auth uses)" =~ ^aws-actions/configure-aws-credentials@[0-9a-f]{40}$ ]] &&
  [ "$(step_field aws-auth 'with["role-to-assume"]')" = '${{ inputs.aws_role_arn }}' ] &&
  [ "$(step_field aws-auth 'with["aws-region"]')" = '${{ steps.check.outputs.region }}' ] &&
  [ "$(step_field aws-auth 'with["audience"]')" = "sts.amazonaws.com" ] &&
  [ "$(step_field aws-auth 'with["output-credentials"]')" = "true" ] &&
  [ "$(step_field aws-auth 'with["output-env-credentials"]')" = "false" ]; then
  pass "aws-auth: IAM ロールを OIDC (audience sts.amazonaws.com) で借り、認証情報を後の step の環境変数に残さない"
else
  fail "aws-auth: uses か with が違う: $(step_field aws-auth uses) $(step_field aws-auth with)"
fi

# ---- registry へのログイン (login) ----

docker run -d --rm --name "$container" -p "$port:5000" registry:2 > /dev/null
for _ in $(seq 1 30); do
  curl -fsS "http://$registry/v2/" > /dev/null 2>&1 && break
  sleep 1
done

# 偽の aws コマンド。借りた認証情報で ecr get-login-password --region ap-northeast-1 を呼んだときだけ、パスワードを返す
mkdir -p "$work/bin"
cat > "$work/bin/aws" <<'AWS'
#!/usr/bin/env bash
if [ "$*" = "ecr get-login-password --region ap-northeast-1" ] && [ "$AWS_ACCESS_KEY_ID" = "AKIAEXAMPLE" ] &&
  [ "$AWS_SECRET_ACCESS_KEY" = "secret" ] && [ "$AWS_SESSION_TOKEN" = "session" ]; then
  echo "ecr-password"
  exit 0
fi
echo "unexpected: $*" >&2
exit 254
AWS
chmod +x "$work/bin/aws"
docker_auth() {
  jq -r --arg host "$registry" '.auths[$host].auth // empty' "$work/docker-config/config.json" | base64 -d
}
aws_login_env=(CLOUD=aws HOST="$registry" REGION=ap-northeast-1 TOKEN= PATH="$work/bin:$PATH"
  AWS_ACCESS_KEY_ID=AKIAEXAMPLE AWS_SECRET_ACCESS_KEY=secret AWS_SESSION_TOKEN=session)

: > "$work/env"
if run_step login CLOUD=google HOST="$registry" REGION= TOKEN=google-token > /dev/null 2>&1 &&
  [ "$(output authorization)" = "Bearer google-token" ] &&
  [ "$(docker_auth)" = "oauth2accesstoken:google-token" ] &&
  grep -qxF "DOCKER_CONFIG=$work/docker-config" "$work/env"; then
  pass "login (google): アクセストークンで、RUNNER_TEMP の中の DOCKER_CONFIG にログインし、Bearer を出す"
else
  fail "login (google): 出力かログインが違う: $(cat "$work/output")"
fi

rm -rf "$work/docker-config"
if run_step login "${aws_login_env[@]}" > /dev/null 2>&1 &&
  [ "$(output authorization)" = "Basic $(printf 'AWS:ecr-password' | base64 -w0)" ] &&
  [ "$(docker_auth)" = "AWS:ecr-password" ]; then
  pass "login (aws): 借りた IAM ロールで ECR のパスワードを取ってログインし、Basic を出す"
else
  fail "login (aws): 出力かログインが違う: $(cat "$work/output")"
fi

run_step login "${aws_login_env[@]}" > "$work/mask.log" 2>&1 || true
if grep -qxF "::add-mask::ecr-password" "$work/mask.log"; then
  pass "login (aws): ECR のパスワードをログに出さない (add-mask)"
else
  fail "login (aws): ECR のパスワードを add-mask していない"
fi

if run_step login "${aws_login_env[@]}" AWS_SESSION_TOKEN= > /dev/null 2>&1; then
  fail "login (aws): ECR のパスワードを取れないのに成功した"
else
  pass "login (aws): ECR のパスワードを取れなければ失敗する"
fi

if [ "$(step_field login env.AWS_ACCESS_KEY_ID)" = '${{ steps.aws-auth.outputs.aws-access-key-id }}' ] &&
  [ "$(step_field login env.AWS_SECRET_ACCESS_KEY)" = '${{ steps.aws-auth.outputs.aws-secret-access-key }}' ] &&
  [ "$(step_field login env.AWS_SESSION_TOKEN)" = '${{ steps.aws-auth.outputs.aws-session-token }}' ] &&
  [ "$(step_field exists env.AUTHORIZATION)" = '${{ steps.login.outputs.authorization }}' ]; then
  pass "login・exists: 借りた認証情報は login にだけ渡し、exists は login の Authorization で確かめる"
else
  fail "login・exists: env が違う: $(step_field login env) / $(step_field exists env)"
fi

# ---- 同じタグがあればスキップする (exists・build) ----

mkdir -p "$work/src/app"
cat > "$work/src/app/Dockerfile" <<'EOF'
FROM busybox:1.37 AS base
RUN echo base > /stage
FROM base AS api
RUN echo api > /stage
FROM base AS worker
RUN echo worker > /stage
EOF

image_path="test/apps/sample"
exists_env=(REGISTRY_URL="http://$registry" IMAGE_PATH="$image_path" VERSION=v1.0.0 AUTHORIZATION="Bearer dummy")
build_env=(IMAGE="$registry/$image_path" VERSION=v1.0.0 CONTEXT="$work/src" FILE="$work/src/app/Dockerfile" TARGET=api
  GITHUB_WORKSPACE="$work/src" GITHUB_REPOSITORY=theindiehacker/example GITHUB_SHA=0123456789abcdef GITHUB_SERVER_URL=https://github.com)

if run_step exists "${exists_env[@]}" > /dev/null && [ "$(output exists)" = "false" ]; then
  pass "exists: タグが無ければ exists=false"
else
  fail "exists: タグが無いのに exists=false にならない: $(cat "$work/output")"
fi

if [ "$(step_if build)" = "steps.exists.outputs.exists == 'false'" ] && [ "$(step_if checkout)" = "steps.exists.outputs.exists == 'false'" ]; then
  pass "build・checkout は、タグが無いときだけ動く"
else
  fail "build・checkout の if が違う: $(step_if build) / $(step_if checkout)"
fi

built=""
if run_step build "${build_env[@]}"; then
  built=$(output digest)
  if [[ "$built" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    pass "build: target を指定してビルドして push し、digest を出す"
  else
    fail "build: digest が違う: $built"
  fi
else
  fail "build: ビルドか push に失敗した"
fi

if [ -n "$built" ]; then
  docker image rm -f "$registry/$image_path:v1.0.0" > /dev/null 2>&1 || true
  if docker pull -q "$registry/$image_path@$built" > /dev/null &&
    [ "$(docker run --rm "$registry/$image_path@$built" cat /stage)" = "api" ]; then
    pass "build: 出力の digest で pull でき、指定した target の中身になる"
  else
    fail "build: 出力の digest で pull できないか、target が違う"
  fi
  source_label=$(docker image inspect "$registry/$image_path@$built" --format '{{index .Config.Labels "org.opencontainers.image.source"}}')
  if [ "$source_label" = "https://github.com/theindiehacker/example" ]; then
    pass "build: イメージに、ビルドしたリポジトリのラベルを付ける"
  else
    fail "build: org.opencontainers.image.source が違う: $source_label"
  fi
fi

# リポジトリの中のシンボリックリンクで、外 (RUNNER_TEMP など) を指すものは断る
mkdir -p "$work/outside"
cp "$work/src/app/Dockerfile" "$work/outside/Dockerfile"
ln -s "$work/outside" "$work/src/escape"
for bad in "CONTEXT=$work/src/escape" "FILE=$work/src/escape/Dockerfile"; do
  if run_step build "${build_env[@]}" VERSION=v9.9.9 "$bad" > /dev/null 2>&1; then
    fail "build: リポジトリの外を指すシンボリックリンク ($bad) でビルドした"
  else
    pass "build: リポジトリの外を指すシンボリックリンク (${bad%%=*}) は断る"
  fi
done
rm "$work/src/escape"
mkdir -p "$work/src/linked"
ln -s "$work/outside/Dockerfile" "$work/src/linked/Dockerfile"
if run_step build "${build_env[@]}" VERSION=v9.9.9 CONTEXT="$work/src/linked" FILE= > /dev/null 2>&1; then
  fail "build: file を省略し、<context>/Dockerfile が外を指すシンボリックリンクなのにビルドした"
else
  pass "build: file を省略しても、<context>/Dockerfile が外を指すシンボリックリンクなら断る"
fi
rm -r "$work/src/linked"
if run_step build "${build_env[@]}" VERSION=v1.0.1 CONTEXT="$work/src/app" FILE= TARGET=worker > /dev/null 2>&1; then
  pass "build: file を省略すると <context>/Dockerfile でビルドする"
else
  fail "build: file を省略すると、<context>/Dockerfile でビルドできない"
fi

if run_step exists "${exists_env[@]}" > /dev/null && [ "$(output exists)" = "true" ] && [ "$(output digest)" = "$built" ]; then
  pass "exists: 同じタグがあれば exists=true で、push したときと同じ digest を出す"
else
  fail "exists: 同じタグがあるのに、exists=true と同じ digest にならない: $(cat "$work/output") (push: $built)"
fi

if run_step exists REGISTRY_URL="http://$registry" IMAGE_PATH="$image_path" VERSION=v2.0.0 AUTHORIZATION="Bearer dummy" > /dev/null && [ "$(output exists)" = "false" ]; then
  pass "exists: ほかのタグは exists=false"
else
  fail "exists: ほかのタグなのに exists=false にならない"
fi

# registry を読めないときは、無いとみなしてビルドせず、失敗する
if run_step exists REGISTRY_URL="http://localhost:1" IMAGE_PATH="$image_path" VERSION=v1.0.0 AUTHORIZATION="Bearer dummy" > /dev/null 2>&1; then
  fail "exists: registry に繋がらないのに成功した: $(cat "$work/output")"
else
  pass "exists: registry に繋がらなければ失敗する"
fi
# login の Authorization を、そのまま送る。401 (認証の失敗など) は、無いとみなさずに失敗する
python3 -c '
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        if self.headers.get("Authorization") == "Basic QVdTOmVjci1wYXNzd29yZA==":
            self.send_response(200)
            self.send_header("Docker-Content-Digest", "sha256:" + "a" * 64)
        else:
            self.send_response(401)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' "$((port + 1))" &
denied_server=$!
sleep 1
if run_step exists REGISTRY_URL="http://127.0.0.1:$((port + 1))" IMAGE_PATH="$image_path" VERSION=v1.0.0 \
  AUTHORIZATION="Basic $(printf 'AWS:ecr-password' | base64 -w0)" > /dev/null &&
  [ "$(output exists)" = "true" ] && [ "$(output digest)" = "sha256:$(printf 'a%.0s' $(seq 64))" ]; then
  pass "exists: login の Authorization (ECR の Basic) を、そのまま送る"
else
  fail "exists: Authorization を送っていない: $(cat "$work/output")"
fi
if run_step exists REGISTRY_URL="http://127.0.0.1:$((port + 1))" IMAGE_PATH="$image_path" VERSION=v1.0.0 AUTHORIZATION="Bearer dummy" > /dev/null 2>&1; then
  fail "exists: 401 なのに成功した: $(cat "$work/output")"
else
  pass "exists: 401 なら失敗する"
fi
kill "$denied_server"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures 件失敗" >&2
  exit 1
fi
echo "すべて通った"
