# 🔑 registry.fastship.jp token

[registry.fastship.jp](https://registry.fastship.jp) (FastShip の private な Terraform Module Registry) からモジュールを取得するための、GitHub Actions の ID トークンを取得します。
トークンの発行や、secret への保管は要りません。

## 📖 使い方

```yaml
jobs:
  terraform:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write  # ID トークンの取得に要る
    steps:
      - uses: actions/checkout@v7

      - id: registry
        uses: theindiehacker/registry-fastship-action@v1.0.0

      - run: terraform init
        env:
          TF_TOKEN_registry_fastship_jp: ${{ steps.registry.outputs.token }}
```

- トークンは、`terraform init` の step の `env` にだけ渡してください。`GITHUB_ENV` に書くと、後の step (plan で動く provider など) からも読めます。
- トークンの有効期限は短いため、`terraform init` の直前に取得します。
- 版はタグ (`@v1.0.0`) か、コミットの SHA で固定してください。

## 📤 出力

| 名前 | 内容 |
|---|---|
| `token` | ID トークン (audience は `https://registry.fastship.jp`)。ログには出ません (マスク済み) |

## ✅ 前提

- **契約企業の登録**: GitHub の org を、registry.fastship.jp の契約企業として登録済みであること。登録していない org のトークンは 401 になります。
- **権限**: 呼び出す job に `permissions: id-token: write` が要ります。fork からの PR では取得できません。
- **イベント**: 受け付けるのは `push`・`pull_request`・`workflow_dispatch`・`schedule`・`merge_group`・`release`・`repository_dispatch` です。`pull_request_target`・`issue_comment`・`workflow_run` などは、外部の PR のコードが base のリポジトリの権限で動くことがあるため、registry が拒否します。
