#!/usr/bin/env bash
#==============================================================================
# OCI Resource Inventory Script (for OCI Cloud Shell)
#
# テナンシー配下の主要リソースをスペック付きで CSV 出力する。
#
# 取得対象:
#   - Compute Instance      (Shape, OCPU, MemoryGB, Boot+Block ストレージ合計)
#   - Boot Volume / Block Volume (スタンドアロン)
#   - DB System (BM/VM)     (Shape, CPU, ストレージ)
#   - Autonomous Database   (CPU/ECPU, ストレージ)
#   - MySQL HeatWave        (Shape, CPU, Memory, ストレージ)
#   - File System (FSS)     (使用量)
#   - Object Storage Bucket (一覧のみ。サイズはバケット使用量APIが必要)
#   - Load Balancer / NLB
#   - OKE Cluster
#
# 使い方 (Cloud Shell):
#   bash oci_resource_inventory.sh                    # 全リージョン×全コンパートメント
#   bash oci_resource_inventory.sh -r ap-tokyo-1      # 特定リージョンのみ
#   bash oci_resource_inventory.sh -c <comp-ocid>     # 特定コンパートメント配下のみ
#   bash oci_resource_inventory.sh -q                 # クイックモード(ストレージ詳細スキップ)
#   bash oci_resource_inventory.sh -o my.csv -v       # 出力ファイル指定 + 進捗表示
#
# 前提:
#   - OCI Cloud Shell (oci CLI / jq が標準で入っている)
#   - 実行ユーザーに参照するコンパートメントの read 権限があること
#
# bash 3.2 互換 / set -u
#==============================================================================

set -u
LANG=C
LC_ALL=C

#-----------------------------------------------------------------------------
# Args
#-----------------------------------------------------------------------------
OUTPUT=""
REGIONS_OPT=""
ROOT_COMP=""
QUICK=0
VERBOSE=0

usage() {
  cat <<'EOF'
Usage: bash oci_resource_inventory.sh [options]
  -o FILE   Output CSV path (default: oci_inventory_<timestamp>.csv)
  -r NAME   Single region name (default: all subscribed regions)
  -c OCID   Root compartment subtree (default: tenancy root)
  -q        Quick mode (skip per-volume storage detail calls)
  -v        Verbose progress to stderr
  -h        This help
EOF
}

while getopts "o:r:c:qvh" opt; do
  case "$opt" in
    o) OUTPUT="$OPTARG" ;;
    r) REGIONS_OPT="$OPTARG" ;;
    c) ROOT_COMP="$OPTARG" ;;
    q) QUICK=1 ;;
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

[ -z "$OUTPUT" ] && OUTPUT="oci_inventory_$(date +%Y%m%d_%H%M%S).csv"

#-----------------------------------------------------------------------------
# Pre-checks
#-----------------------------------------------------------------------------
command -v oci >/dev/null 2>&1 || { echo "ERROR: oci CLI not found. OCI Cloud Shell で実行してください。" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found." >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() { [ "$VERBOSE" -eq 1 ] && echo "[$(date +%H:%M:%S)] $*" >&2; return 0; }

#-----------------------------------------------------------------------------
# エラー記録: oci_json は失敗してもリソース反復は止めない（ベストエフォート方針）
# が、件数と stderr は記録し、終了時にサマリを表示する。
#-----------------------------------------------------------------------------
ERROR_COUNT_FILE="$TMP_DIR/error_count"
ERROR_LOG="$TMP_DIR/errors.log"
echo 0 > "$ERROR_COUNT_FILE"
: > "$ERROR_LOG"

oci_json() {
  local out rc cnt err_file
  err_file="$TMP_DIR/_err.$$"
  out=$(oci "$@" 2>"$err_file")
  rc=$?
  if [ $rc -ne 0 ]; then
    cnt=$(cat "$ERROR_COUNT_FILE" 2>/dev/null || echo 0)
    echo $((cnt + 1)) > "$ERROR_COUNT_FILE"
    {
      echo "[$(date +%H:%M:%S)] FAILED (exit=$rc): oci $*"
      sed 's/^/    /' "$err_file" 2>/dev/null
      echo ""
    } >> "$ERROR_LOG"
    if [ "$VERBOSE" -eq 1 ]; then
      {
        echo "[$(date +%H:%M:%S)] oci CLI failed (exit=$rc): $*"
        sed 's/^/    /' "$err_file" 2>/dev/null
      } >&2
    fi
  fi
  rm -f "$err_file"
  if [ -z "$out" ]; then echo '{}'; else echo "$out"; fi
}

# 応答の各要素を JSONL で吐く。
# 以下の応答形すべてに対応:
#   標準            : {"data":[...]}
#   コレクション単発: {"data":{"items":[...]}}
#   コレクション+--all: {"data":[{"items":[...]}, {"items":[...]}]}  ← NLB 等
to_items() {
  jq -c '
    .data
    | if . == null then []
      elif type == "object" then
        if has("items")      then .items
        elif has("collection") then .collection
        else [.] end
      elif type == "array" then
        if length == 0 then []
        elif (.[0] | type) == "object" and (.[0] | has("items"))      then (map(.items)      | add // [])
        elif (.[0] | type) == "object" and (.[0] | has("collection")) then (map(.collection) | add // [])
        else . end
      else [] end
    | .[]?
  '
}

#-----------------------------------------------------------------------------
# Tenancy / Regions / Compartments の解決
#-----------------------------------------------------------------------------
# テナンシー OCID 検出: (1) OCI_TENANCY 環境変数 (Cloud Shell が自動設定)
#                      (2) ~/.oci/config の tenancy= (アクティブプロファイル)
detect_tenancy_from_config() {
  local profile="${OCI_CLI_PROFILE:-DEFAULT}"
  local cfg="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
  [ -f "$cfg" ] || return 1
  awk -v p="[$profile]" '
    BEGIN { in_p=0 }
    /^\[/ { in_p = ($0 == p) }
    in_p && /^tenancy[[:space:]]*=/ {
      sub(/^tenancy[[:space:]]*=[[:space:]]*/, "")
      print
      exit
    }
  ' "$cfg"
}

if [ -n "${OCI_TENANCY:-}" ]; then
  TENANCY="$OCI_TENANCY"
else
  TENANCY=$(detect_tenancy_from_config)
fi
if [ -z "$TENANCY" ]; then
  echo "ERROR: テナンシー OCID を特定できません。" >&2
  echo "  - Cloud Shell で実行する場合は OCI_TENANCY が自動設定されます。" >&2
  echo "  - ローカル PC の場合は ~/.oci/config に tenancy= を設定するか、" >&2
  echo "    環境変数 OCI_TENANCY を直接指定してください。" >&2
  exit 1
fi
[ -z "$ROOT_COMP" ] && ROOT_COMP="$TENANCY"

if [ -n "$REGIONS_OPT" ]; then
  REGIONS="$REGIONS_OPT"
else
  REGIONS=$(oci iam region-subscription list 2>/dev/null | jq -r '.data[]."region-name"')
fi
[ -z "$REGIONS" ] && { echo "ERROR: 対象リージョンが取得できません。" >&2; exit 1; }

# コンパートメント取得方針:
#   - ROOT_COMP がテナンシー: 1コール subtree 取得（管理者向けに最速）
#   - ROOT_COMP がサブコンパートメント: 当該配下を BFS で辿る
#     （テナンシー全体の read 権限が無いユーザーでも動作させるため）
if [ "$ROOT_COMP" = "$TENANCY" ]; then
  log "Fetching all compartments under tenancy (subtree)..."
  oci iam compartment list \
    --compartment-id "$TENANCY" \
    --compartment-id-in-subtree true \
    --include-root \
    --lifecycle-state ACTIVE \
    --all > "$TMP_DIR/compartments.json" 2> "$TMP_DIR/comp_err.log"

  if [ ! -s "$TMP_DIR/compartments.json" ] \
     || [ "$(jq '(.data // []) | length' "$TMP_DIR/compartments.json")" = "0" ]; then
    echo "ERROR: テナンシー全体のコンパートメント一覧取得に失敗しました。" >&2
    [ -s "$TMP_DIR/comp_err.log" ] && { echo "--- oci stderr ---" >&2; cat "$TMP_DIR/comp_err.log" >&2; }
    echo "  ヒント: テナンシーレベルの read 権限が無い場合は -c <compartment-OCID>" >&2
    echo "         でアクセス可能なコンパートメントを指定してください。" >&2
    exit 1
  fi
  jq -r '.data[] | [.id, .name] | @tsv' "$TMP_DIR/compartments.json" > "$TMP_DIR/compartments.tsv"
else
  log "Walking compartment tree from $ROOT_COMP (BFS)..."
  : > "$TMP_DIR/compartments.tsv"

  # ROOT_COMP 自身を取得（権限と存在確認も兼ねる）
  root_get=$(oci_json iam compartment get --compartment-id "$ROOT_COMP")
  root_name=$(echo "$root_get" | jq -r '.data.name // empty')
  root_state=$(echo "$root_get" | jq -r '.data."lifecycle-state" // empty')
  if [ -z "$root_name" ] || [ "$root_state" != "ACTIVE" ]; then
    echo "ERROR: ROOT_COMP=$ROOT_COMP を取得できませんでした (state='$root_state')。" >&2
    echo "  - OCID が正しいかご確認ください。" >&2
    echo "  - 実行ユーザーに当該コンパートメントの read 権限があるかご確認ください。" >&2
    exit 1
  fi
  printf '%s\t%s\n' "$ROOT_COMP" "$root_name" >> "$TMP_DIR/compartments.tsv"

  echo "$ROOT_COMP" > "$TMP_DIR/comp_queue.txt"
  while [ -s "$TMP_DIR/comp_queue.txt" ]; do
    current=$(head -n1 "$TMP_DIR/comp_queue.txt")
    tail -n +2 "$TMP_DIR/comp_queue.txt" > "$TMP_DIR/comp_queue.txt.tmp"
    mv "$TMP_DIR/comp_queue.txt.tmp" "$TMP_DIR/comp_queue.txt"

    children=$(oci_json iam compartment list \
      --compartment-id "$current" \
      --lifecycle-state ACTIVE \
      --all)
    echo "$children" | jq -r '.data[]? | [.id, .name] | @tsv' >> "$TMP_DIR/compartments.tsv"
    echo "$children" | jq -r '.data[]?.id // empty' >> "$TMP_DIR/comp_queue.txt"
  done
fi

COMP_COUNT=$(wc -l < "$TMP_DIR/compartments.tsv" | tr -d ' ')

if [ "$COMP_COUNT" = "0" ]; then
  echo "ERROR: アクセスできるコンパートメントが見つかりません。" >&2
  echo "  - 実行ユーザーに read 権限があるかご確認ください。" >&2
  exit 1
fi

echo "Tenancy:        $TENANCY"
echo "Root:           $ROOT_COMP"
echo "Regions:        $(echo $REGIONS | tr '\n' ' ')"
echo "Compartments:   $COMP_COUNT"
echo "Output:         $OUTPUT"
echo "Quick mode:     $QUICK"
echo ""

#-----------------------------------------------------------------------------
# CSV 書き出しヘルパー
#-----------------------------------------------------------------------------
echo "Region,CompartmentName,CompartmentId,ResourceType,ResourceName,ResourceId,Shape,OCPU,MemoryGB,StorageGB,LifecycleState,AvailabilityDomain,TimeCreated,Details" > "$OUTPUT"

csv_escape() {
  local v="${1:-}"
  case "$v" in
    "" ) printf '' ;;
    *,*|*\"*|*$'\n'*)
      v=$(printf '%s' "$v" | sed 's/"/""/g')
      printf '"%s"' "$v"
      ;;
    *) printf '%s' "$v" ;;
  esac
}

write_row() {
  # 14 fields matching header
  local first=1 a out=""
  for a in "$@"; do
    if [ "$first" -eq 1 ]; then
      out="$(csv_escape "$a")"; first=0
    else
      out="${out},$(csv_escape "$a")"
    fi
  done
  echo "$out" >> "$OUTPUT"
}

# AD list per region (cache)
ads_for_region() {
  local region="$1"
  local cache="$TMP_DIR/ads_${region}"
  if [ ! -f "$cache" ]; then
    oci_json --region "$region" iam availability-domain list --compartment-id "$TENANCY" \
      | jq -r '.data[]?.name' > "$cache"
  fi
  cat "$cache"
}

#-----------------------------------------------------------------------------
# Collectors
#-----------------------------------------------------------------------------

collect_compute() {
  local region="$1" compid="$2" compname="$3"
  local key="${region}_${compid}"
  local inst_json count
  inst_json=$(oci_json --region "$region" compute instance list --compartment-id "$compid" --all)
  count=$(echo "$inst_json" | jq '(.data // []) | length')
  [ "$count" = "0" ] && return

  # コンパートメント内のボリューム情報を一括取得（QUICK時はスキップ）
  # NOTE: compute boot-volume-attachment list は --availability-domain 必須。
  #       AD ごとに取得して結合する。
  local bva_json va_json bv_json vol_json
  bva_json='{"data":[]}'; va_json='{"data":[]}'; bv_json='{"data":[]}'; vol_json='{"data":[]}'
  if [ "$QUICK" -eq 0 ]; then
    local ad_list ad
    ad_list=$(ads_for_region "$region")
    bva_json=$({
      for ad in $ad_list; do
        oci_json --region "$region" compute boot-volume-attachment list \
          --compartment-id "$compid" --availability-domain "$ad" --all \
          | jq '.data // []'
      done
    } | jq -s 'add // [] | {data: .}')
    va_json=$(oci_json  --region "$region" compute volume-attachment list --compartment-id "$compid" --all)
    bv_json=$(oci_json  --region "$region" bv boot-volume             list --compartment-id "$compid" --all)
    vol_json=$(oci_json --region "$region" bv volume                  list --compartment-id "$compid" --all)

    # collect_volumes で attached/standalone 判定とインスタンス名解決に使う
    printf '%s' "$inst_json" > "$TMP_DIR/inst_${key}.json"
    printf '%s' "$bva_json"  > "$TMP_DIR/bva_${key}.json"
    printf '%s' "$va_json"   > "$TMP_DIR/va_${key}.json"
  fi

  echo "$inst_json" | to_items | while read -r inst; do
    local id name shape ocpu mem ad state created
    id=$(printf '%s' "$inst"     | jq -r '.id')
    name=$(printf '%s' "$inst"   | jq -r '."display-name" // ""')
    shape=$(printf '%s' "$inst"  | jq -r '.shape // ""')
    ocpu=$(printf '%s' "$inst"   | jq -r '."shape-config".ocpus // ""')
    mem=$(printf '%s' "$inst"    | jq -r '."shape-config"."memory-in-gbs" // ""')
    ad=$(printf '%s' "$inst"     | jq -r '."availability-domain" // ""')
    state=$(printf '%s' "$inst"  | jq -r '."lifecycle-state" // ""')
    created=$(printf '%s' "$inst"| jq -r '."time-created" // ""')

    local boot_size=0 block_size=0 total=0 details="-"
    if [ "$QUICK" -eq 0 ]; then
      local bvid
      bvid=$(printf '%s' "$bva_json" | jq -r --arg id "$id" '
        (.data // [])[] | select(."instance-id"==$id) | ."boot-volume-id"' | head -n1)
      if [ -n "$bvid" ] && [ "$bvid" != "null" ]; then
        boot_size=$(printf '%s' "$bv_json" | jq -r --arg id "$bvid" '
          (.data // [])[] | select(.id==$id) | (."size-in-gbs" // 0)' | head -n1)
        case "$boot_size" in ''|null) boot_size=0 ;; esac
      fi
      # 接続中ブロックボリューム合計
      local volids vid s
      volids=$(printf '%s' "$va_json" | jq -r --arg id "$id" '
        (.data // [])[] | select(."instance-id"==$id and (."lifecycle-state" // "ATTACHED")=="ATTACHED") | ."volume-id"')
      for vid in $volids; do
        s=$(printf '%s' "$vol_json" | jq -r --arg id "$vid" '
          (.data // [])[] | select(.id==$id) | (."size-in-gbs" // 0)' | head -n1)
        case "$s" in ''|null) s=0 ;; esac
        block_size=$((block_size + s))
      done
      details="boot=${boot_size}GB,block=${block_size}GB"
    fi
    total=$((boot_size + block_size))

    write_row "$region" "$compname" "$compid" "ComputeInstance" \
      "$name" "$id" "$shape" "$ocpu" "$mem" "$total" "$state" "$ad" "$created" "$details"
  done
}

collect_volumes() {
  local region="$1" compid="$2" compname="$3"
  local key="${region}_${compid}"
  local bv_json vol_json
  bv_json=$(oci_json  --region "$region" bv boot-volume list --compartment-id "$compid" --all)
  vol_json=$(oci_json --region "$region" bv volume      list --compartment-id "$compid" --all)

  # collect_compute でキャッシュ済み (QUICK=0 かつ Compute 存在時のみ生成される)
  local bva_json='{"data":[]}' va_json='{"data":[]}' inst_json='{"data":[]}'
  [ -f "$TMP_DIR/bva_${key}.json" ]  && bva_json=$(cat  "$TMP_DIR/bva_${key}.json")
  [ -f "$TMP_DIR/va_${key}.json" ]   && va_json=$(cat   "$TMP_DIR/va_${key}.json")
  [ -f "$TMP_DIR/inst_${key}.json" ] && inst_json=$(cat "$TMP_DIR/inst_${key}.json")

  echo "$bv_json" | to_items | while read -r v; do
    local id name size state ad created details iid iname
    id=$(printf '%s' "$v"      | jq -r '.id')
    name=$(printf '%s' "$v"    | jq -r '."display-name" // ""')
    size=$(printf '%s' "$v"    | jq -r '."size-in-gbs" // ""')
    state=$(printf '%s' "$v"   | jq -r '."lifecycle-state" // ""')
    ad=$(printf '%s' "$v"      | jq -r '."availability-domain" // ""')
    created=$(printf '%s' "$v" | jq -r '."time-created" // ""')
    if [ "$QUICK" -eq 1 ]; then
      details=""
    else
      iid=$(printf '%s' "$bva_json" | jq -r --arg id "$id" '
        (.data // [])[] | select(."boot-volume-id"==$id and (."lifecycle-state" // "ATTACHED")=="ATTACHED") | ."instance-id"' | head -n1)
      if [ -n "$iid" ] && [ "$iid" != "null" ]; then
        iname=$(printf '%s' "$inst_json" | jq -r --arg id "$iid" '
          (.data // [])[] | select(.id==$id) | ."display-name" // ""' | head -n1)
        if [ -n "$iname" ]; then details="attached_to=$iname"
        else                     details="attached_to=$iid"
        fi
      else
        details="standalone"
      fi
    fi
    write_row "$region" "$compname" "$compid" "BootVolume" \
      "$name" "$id" "" "" "" "$size" "$state" "$ad" "$created" "$details"
  done

  echo "$vol_json" | to_items | while read -r v; do
    local id name size state ad created details iid iname
    id=$(printf '%s' "$v"      | jq -r '.id')
    name=$(printf '%s' "$v"    | jq -r '."display-name" // ""')
    size=$(printf '%s' "$v"    | jq -r '."size-in-gbs" // ""')
    state=$(printf '%s' "$v"   | jq -r '."lifecycle-state" // ""')
    ad=$(printf '%s' "$v"      | jq -r '."availability-domain" // ""')
    created=$(printf '%s' "$v" | jq -r '."time-created" // ""')
    if [ "$QUICK" -eq 1 ]; then
      details=""
    else
      iid=$(printf '%s' "$va_json" | jq -r --arg id "$id" '
        (.data // [])[] | select(."volume-id"==$id and (."lifecycle-state" // "ATTACHED")=="ATTACHED") | ."instance-id"' | head -n1)
      if [ -n "$iid" ] && [ "$iid" != "null" ]; then
        iname=$(printf '%s' "$inst_json" | jq -r --arg id "$iid" '
          (.data // [])[] | select(.id==$id) | ."display-name" // ""' | head -n1)
        if [ -n "$iname" ]; then details="attached_to=$iname"
        else                     details="attached_to=$iid"
        fi
      else
        details="standalone"
      fi
    fi
    write_row "$region" "$compname" "$compid" "BlockVolume" \
      "$name" "$id" "" "" "" "$size" "$state" "$ad" "$created" "$details"
  done
}

collect_db_system() {
  local region="$1" compid="$2" compname="$3"
  local j
  j=$(oci_json --region "$region" db system list --compartment-id "$compid" --all)
  echo "$j" | to_items | while read -r r; do
    local id name shape cores stor state ad created edition version
    id=$(printf '%s' "$r"      | jq -r '.id')
    name=$(printf '%s' "$r"    | jq -r '."display-name" // ""')
    shape=$(printf '%s' "$r"   | jq -r '.shape // ""')
    cores=$(printf '%s' "$r"   | jq -r '."cpu-core-count" // ""')
    stor=$(printf '%s' "$r"    | jq -r '."data-storage-size-in-gbs" // ""')
    state=$(printf '%s' "$r"   | jq -r '."lifecycle-state" // ""')
    ad=$(printf '%s' "$r"      | jq -r '."availability-domain" // ""')
    created=$(printf '%s' "$r" | jq -r '."time-created" // ""')
    edition=$(printf '%s' "$r" | jq -r '."database-edition" // ""')
    version=$(printf '%s' "$r" | jq -r '.version // ""')
    write_row "$region" "$compname" "$compid" "DBSystem" \
      "$name" "$id" "$shape" "$cores" "" "$stor" "$state" "$ad" "$created" \
      "edition=${edition},version=${version}"
  done
}

collect_adb() {
  local region="$1" compid="$2" compname="$3"
  local j
  j=$(oci_json --region "$region" db autonomous-database list --compartment-id "$compid" --all)
  echo "$j" | to_items | while read -r r; do
    local id name workload model cpu ecpu storage state created cpu_disp shape_disp
    id=$(printf '%s' "$r"       | jq -r '.id')
    name=$(printf '%s' "$r"     | jq -r '."display-name" // ""')
    workload=$(printf '%s' "$r" | jq -r '."db-workload" // ""')
    model=$(printf '%s' "$r"    | jq -r '."compute-model" // ""')
    cpu=$(printf '%s' "$r"      | jq -r '."cpu-core-count" // ""')
    ecpu=$(printf '%s' "$r"     | jq -r '."compute-count" // ""')
    storage=$(printf '%s' "$r"  | jq -r '
      if (."data-storage-size-in-gbs" // null) != null then ."data-storage-size-in-gbs"
      elif (."data-storage-size-in-tbs" // null) != null then (."data-storage-size-in-tbs" * 1024)
      else "" end')
    state=$(printf '%s' "$r"    | jq -r '."lifecycle-state" // ""')
    created=$(printf '%s' "$r"  | jq -r '."time-created" // ""')

    if [ "$model" = "ECPU" ] && [ -n "$ecpu" ] && [ "$ecpu" != "null" ]; then
      cpu_disp="$ecpu"; shape_disp="ECPU"
    else
      cpu_disp="$cpu";  shape_disp="OCPU"
    fi
    write_row "$region" "$compname" "$compid" "AutonomousDB" \
      "$name" "$id" "$shape_disp" "$cpu_disp" "" "$storage" "$state" "" "$created" "workload=${workload}"
  done
}

collect_mysql() {
  local region="$1" compid="$2" compname="$3"
  local j
  j=$(oci_json --region "$region" mysql db-system list --compartment-id "$compid" --all)
  echo "$j" | to_items | while read -r r; do
    local id name shape ad state created
    id=$(printf '%s' "$r"      | jq -r '.id')
    name=$(printf '%s' "$r"    | jq -r '."display-name" // ""')
    shape=$(printf '%s' "$r"   | jq -r '."shape-name" // ""')
    ad=$(printf '%s' "$r"      | jq -r '."availability-domain" // ""')
    state=$(printf '%s' "$r"   | jq -r '."lifecycle-state" // ""')
    created=$(printf '%s' "$r" | jq -r '."time-created" // ""')

    local cpu="" mem="" storage="" version=""
    if [ "$QUICK" -eq 0 ]; then
      local d
      d=$(oci_json --region "$region" mysql db-system get --db-system-id "$id")
      cpu=$(printf '%s' "$d"     | jq -r '.data."cpu-core-count" // ""')
      mem=$(printf '%s' "$d"     | jq -r '.data."memory-size-in-gbs" // ""')
      storage=$(printf '%s' "$d" | jq -r '.data."data-storage-size-in-gbs" // ""')
      version=$(printf '%s' "$d" | jq -r '.data."mysql-version" // ""')
    fi
    write_row "$region" "$compname" "$compid" "MySQLDBSystem" \
      "$name" "$id" "$shape" "$cpu" "$mem" "$storage" "$state" "$ad" "$created" "version=${version}"
  done
}

collect_fss() {
  local region="$1" compid="$2" compname="$3"
  local ad_list ad
  ad_list=$(ads_for_region "$region")
  for ad in $ad_list; do
    local j
    j=$(oci_json --region "$region" fs file-system list --compartment-id "$compid" --availability-domain "$ad" --all)
    echo "$j" | to_items | while read -r r; do
      local id name bytes state created gb
      id=$(printf '%s' "$r"      | jq -r '.id')
      name=$(printf '%s' "$r"    | jq -r '."display-name" // ""')
      bytes=$(printf '%s' "$r"   | jq -r '."metered-bytes" // 0')
      state=$(printf '%s' "$r"   | jq -r '."lifecycle-state" // ""')
      created=$(printf '%s' "$r" | jq -r '."time-created" // ""')
      gb=$(awk -v b="$bytes" 'BEGIN{ printf "%.2f", b/1024/1024/1024 }')
      write_row "$region" "$compname" "$compid" "FileSystem" \
        "$name" "$id" "" "" "" "$gb" "$state" "$ad" "$created" "metered=${bytes}B"
    done
  done
}

collect_buckets() {
  local region="$1" compid="$2" compname="$3"
  local ns
  ns=$(oci_json --region "$region" os ns get | jq -r '.data // empty')
  [ -z "$ns" ] && return
  local j
  j=$(oci_json --region "$region" os bucket list --compartment-id "$compid" --namespace-name "$ns" --all)
  echo "$j" | to_items | while read -r r; do
    local name created
    name=$(printf '%s' "$r"    | jq -r '.name // ""')
    created=$(printf '%s' "$r" | jq -r '."time-created" // ""')
    # バケットの実サイズは os bucket get --fields approximateCount,approximateSize で個別取得が必要
    write_row "$region" "$compname" "$compid" "Bucket" \
      "$name" "" "" "" "" "" "" "" "$created" "namespace=${ns}"
  done
}

collect_lb() {
  local region="$1" compid="$2" compname="$3"
  local j
  j=$(oci_json --region "$region" lb load-balancer list --compartment-id "$compid" --all)
  echo "$j" | to_items | while read -r r; do
    local id name shape min max state created
    id=$(printf '%s' "$r"      | jq -r '.id')
    name=$(printf '%s' "$r"    | jq -r '."display-name" // ""')
    shape=$(printf '%s' "$r"   | jq -r '."shape-name" // .shape // ""')
    min=$(printf '%s' "$r"     | jq -r '."shape-details"."minimum-bandwidth-in-mbps" // ""')
    max=$(printf '%s' "$r"     | jq -r '."shape-details"."maximum-bandwidth-in-mbps" // ""')
    state=$(printf '%s' "$r"   | jq -r '."lifecycle-state" // ""')
    created=$(printf '%s' "$r" | jq -r '."time-created" // ""')
    write_row "$region" "$compname" "$compid" "LoadBalancer" \
      "$name" "$id" "$shape" "" "" "" "$state" "" "$created" "bw=${min}-${max}Mbps"
  done

  local jn
  jn=$(oci_json --region "$region" nlb network-load-balancer list --compartment-id "$compid" --all)
  echo "$jn" | to_items | while read -r r; do
    local id name state created
    id=$(printf '%s' "$r"      | jq -r '.id')
    name=$(printf '%s' "$r"    | jq -r '."display-name" // ""')
    state=$(printf '%s' "$r"   | jq -r '."lifecycle-state" // ""')
    created=$(printf '%s' "$r" | jq -r '."time-created" // ""')
    write_row "$region" "$compname" "$compid" "NetworkLoadBalancer" \
      "$name" "$id" "" "" "" "" "$state" "" "$created" ""
  done
}

collect_oke() {
  local region="$1" compid="$2" compname="$3"
  local j
  j=$(oci_json --region "$region" ce cluster list --compartment-id "$compid" --all)
  echo "$j" | to_items | while read -r r; do
    local id name version state created
    id=$(printf '%s' "$r"      | jq -r '.id')
    name=$(printf '%s' "$r"    | jq -r '.name // ""')
    version=$(printf '%s' "$r" | jq -r '."kubernetes-version" // ""')
    state=$(printf '%s' "$r"   | jq -r '."lifecycle-state" // ""')
    created=$(printf '%s' "$r" | jq -r '."metadata"."time-created" // ""')
    write_row "$region" "$compname" "$compid" "OKECluster" \
      "$name" "$id" "" "" "" "" "$state" "" "$created" "k8s=${version}"
  done
}

#-----------------------------------------------------------------------------
# Main loop
#-----------------------------------------------------------------------------
echo "Collecting resources..."
for region in $REGIONS; do
  log "=== Region: $region ==="
  while IFS=$'\t' read -r compid compname; do
    [ -z "$compid" ] && continue
    log " - [$region] $compname"
    collect_compute   "$region" "$compid" "$compname"
    collect_volumes   "$region" "$compid" "$compname"
    collect_db_system "$region" "$compid" "$compname"
    collect_adb       "$region" "$compid" "$compname"
    collect_mysql     "$region" "$compid" "$compname"
    collect_fss       "$region" "$compid" "$compname"
    collect_buckets   "$region" "$compid" "$compname"
    collect_lb        "$region" "$compid" "$compname"
    collect_oke       "$region" "$compid" "$compname"
  done < "$TMP_DIR/compartments.tsv"
done

ROWS=$(($(wc -l < "$OUTPUT") - 1))
ERROR_COUNT=$(cat "$ERROR_COUNT_FILE" 2>/dev/null || echo 0)

echo ""
echo "Done."
echo "  CSV : $OUTPUT"
echo "  Rows: $ROWS"

if [ "${ERROR_COUNT:-0}" -gt 0 ]; then
  ERROR_LOG_OUT="${OUTPUT}.errors.log"
  cp "$ERROR_LOG" "$ERROR_LOG_OUT" 2>/dev/null || true
  echo ""
  echo "WARNING: $ERROR_COUNT 件の OCI CLI 呼び出しが失敗しました。"
  echo "  CSV が不完全な可能性があります（取得できなかったリソースは行に含まれていません）。"
  echo "  詳細ログ: $ERROR_LOG_OUT"
  echo "  典型的な原因: 権限不足 / サービス未提供リージョン / レート制限 / オプション誤り"
  echo "  -v オプションで実行すると失敗時に都度 stderr に表示されます。"
fi
