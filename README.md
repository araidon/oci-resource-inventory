# OCI Resource Inventory Script

OCI テナンシー配下の主要リソースをスペック付きで CSV 出力するシェルスクリプトです。OCI Cloud Shell でそのまま実行できます。

## 使い方

### Cloud Shell で実行（推奨）

1. OCI Console 右上のアイコンから **Cloud Shell** を起動
2. 画面右上の **Upload** メニューから `oci_resource_inventory.sh` をアップロード
3. ターミナルで実行
   ```bash
   bash oci_resource_inventory.sh -v
   ```
4. 完了後、画面右上の **Download** メニューから生成された CSV をダウンロード

### コマンド例

```bash
# 全リージョン × 全コンパートメント、進捗表示あり
bash oci_resource_inventory.sh -v

# 東京リージョンのみ
bash oci_resource_inventory.sh -r ap-tokyo-1 -v

# 特定コンパートメント配下のみ（テナンシー全体への権限が無い場合はこちら）
bash oci_resource_inventory.sh -c ocid1.compartment.oc1..xxxxx -v

# クイックモード（ボリュームのアタッチ判定を省略して高速化）
bash oci_resource_inventory.sh -q -o quick.csv
```

### オプション

| オプション | 説明 | デフォルト |
|---|---|---|
| `-o FILE` | 出力 CSV のパス | `oci_inventory_<YYYYMMDD_HHMMSS>.csv` |
| `-r NAME` | 対象リージョン名（1つだけ）<br>例: `ap-tokyo-1`、`us-ashburn-1` | サブスクライブ済み全リージョン |
| `-c OCID` | 対象コンパートメントの OCID（その配下の子コンパートメントも再帰的に対象） | テナンシー全体 |
| `-q` | クイックモード（ボリュームのアタッチ判定とサイズ集計を省略） | 通常モード |
| `-v` | 進捗を標準エラーに表示 | 非表示 |
| `-h` | ヘルプ表示 | - |

## 対応サービスと取得項目

| ResourceType | 説明 | Shape | OCPU | MemoryGB | StorageGB | Details 列の補足 |
|---|---|---|---|---|---|---|
| ComputeInstance | コンピュート・インスタンス | ✓ | ✓ | ✓ | ✓ <br>(Boot+Block 合計) | `boot=NGB,block=NGB` 内訳 |
| BootVolume | ブート・ボリューム | - | - | - | ✓ | `attached_to=<インスタンス名>` または `standalone` |
| BlockVolume | ブロック・ボリューム | - | - | - | ✓ | `attached_to=<インスタンス名>` または `standalone` |
| DBSystem | Base Database (VM/BM) | ✓ | ✓ | - | ✓ | `edition=...,version=...` |
| AutonomousDB | Autonomous Database | OCPU / ECPU 区分 | ✓ | - | ✓ (GB) | `workload=OLTP/DW/...` |
| MySQLDBSystem | MySQL HeatWave | ✓ | ✓ | ✓ | ✓ | `version=...` |
| FileSystem | File Storage Service | - | - | - | ✓ (使用量) | `metered=NB` |
| Bucket | Object Storage バケット | - | - | - | -（注） | `namespace=...` |
| LoadBalancer | Load Balancer | ✓ | - | - | - | `bw=N-NMbps`（帯域） |
| NetworkLoadBalancer | Network Load Balancer | - | - | - | - | - |
| OKECluster | Container Engine for Kubernetes | - | - | - | - | `k8s=<バージョン>` |

**(注) バケットの容量について**: オブジェクトサイズ合計は本スクリプトでは取得していません（テナンシー全体で重い処理になるため）。必要な場合は個別に以下で取得してください。
```bash
oci os bucket get --bucket-name <バケット名> --namespace-name <ネームスペース> \
  --fields approximateCount,approximateSize
```

---

## 補足

### 前提条件

- OCI Cloud Shell で実行することを推奨（`oci` CLI と `jq` が標準でインストール済み・認証済み）
- ローカル PC で実行する場合: OCI CLI（`~/.oci/config` で認証設定済み）、jq、bash が必要
- 実行ユーザーが対象コンパートメントに対し各リソースタイプの read 権限を持っていること

### 出力 CSV の列

| 列名 | 内容 |
|---|---|
| Region | リソースが存在するリージョン名 |
| CompartmentName | コンパートメント表示名 |
| CompartmentId | コンパートメント OCID |
| ResourceType | リソース種別（上表参照） |
| ResourceName | リソースの表示名 |
| ResourceId | リソース OCID |
| Shape | シェイプ／フォーム（該当する場合） |
| OCPU | OCPU 数（AutonomousDB は Shape 列に OCPU/ECPU 区分を出力） |
| MemoryGB | メモリ（GB） |
| StorageGB | ストレージ（GB） |
| LifecycleState | リソース状態（RUNNING / STOPPED / AVAILABLE / ACTIVE 等） |
| AvailabilityDomain | 配置されている AD（該当する場合） |
| TimeCreated | 作成日時（ISO 8601） |
| Details | リソース固有の補足情報（上表参照） |

### 必要な IAM 権限

実行ユーザーが所属するグループに対し、最低限以下のポリシーがあれば動作します（Read のみ）。

**A. テナンシー全体を対象にする場合（引数なしで実行）**

```
Allow group <YourGroup> to inspect all-resources in tenancy
```

**B. 特定コンパートメントだけに限定する場合（`-c <OCID>` で実行）**

```
Allow group <YourGroup> to inspect all-resources in compartment <YourCompartment>
```

B のケースでは、テナンシーレベルの read 権限が無くても動作します。

### エラー時の挙動

スクリプトはベストエフォート方式で動作し、個別リソースの API 呼び出しが失敗しても止まりません（CSV 生成は継続）。

- **`-v` 指定時**: 失敗の都度、stderr に詳細を表示
- **終了時のサマリ**: 失敗が発生していれば WARNING を表示
- **詳細ログ**: 失敗があった場合、`<出力CSV名>.errors.log` に全失敗内容が保存されます

サマリに WARNING が出ていない場合は、すべての API 呼び出しが成功しており CSV は完全です。

### トラブルシューティング

| 症状 | 対処 |
|---|---|
| `テナンシー OCID を特定できません` | Cloud Shell で実行するか、`~/.oci/config` の `tenancy=` を設定するか、環境変数 `OCI_TENANCY` を直接指定してください |
| `テナンシー全体のコンパートメント一覧取得に失敗しました` | テナンシーレベルの read 権限が無い可能性。`-c <compartment-OCID>` でアクセス可能なコンパートメントを指定してください |
| `ROOT_COMP=... を取得できませんでした` | `-c` で指定した OCID が誤っているかアクセス権が無い可能性 |
| あるリージョンのリソースが0件 | サブスクライブ済みでも当該サービスが未提供のリージョンの場合があります |
| 実行が長い | 大規模テナンシーでは数十分かかることがあります。`-q`/`-r`/`-c` で範囲を絞ってください |
| 終了時に `WARNING: N 件の OCI CLI 呼び出しが失敗しました` | `<出力CSV名>.errors.log` を確認。権限不足 / 未提供リージョン / レート制限が典型原因です |

### 既知の制約

- **未対応サービス**: 以下は本スクリプトでは取得対象外です
  - Exadata Cloud Service / Exadata Infrastructure
  - OCI Functions / API Gateway / Streaming
  - DNS / Health Checks / Email Delivery
  - Vault / KMS / Bastion 等のセキュリティ系
  - Data Science / Data Catalog / Integration / Analytics 等のデータ系
- **バケット容量未取得**: 上記「対応サービス」表の注記参照
- **権限の影響**: 実行ユーザーが見えないコンパートメント／リソースは出力に含まれません
- **コスト・使用量集計には非対応**: 本スクリプトは「現状一覧」の出力です。コスト見積りや使用量集計は OCI Cost Analysis / Usage API をご利用ください

### サポート

スクリプトに関する不具合・追加要望は、本配布元までご連絡ください。
