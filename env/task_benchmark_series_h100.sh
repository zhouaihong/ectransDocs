#!/usr/bin/env bash
# begin: 2026-05-03 21:20:00
# type: sh
# effect: H100上按task标准顺序运行benchmark并维护CPU/GPU双索引
# version: 260502_12

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
perl_bin="/usr/bin/perl"

find_repo_root() {
  local start="$1"
  local dir="$start"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/install" && -d "$dir/env" && -d "$dir/data" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

resolve_repo_root() {
  local repo_root_default="${EC_HOME:-}"
  if [[ -z "$repo_root_default" ]]; then
    repo_root_default=$(find_repo_root "$script_dir" || true)
  fi
  if [[ -z "$repo_root_default" ]]; then
    printf '%s\n' "无法自动定位repo_root，请先导出EC_HOME" >&2
    exit 1
  fi
  repo_root="${EC_HOME:-$repo_root_default}"
}

label_base=""
repeats=1
sleep_between=0
target=""
partition="${PARTITION:-h100x}"
nodes=1
ntasks=1
cpus_per_task=2
gpus=""
profile="release"

canonical_label=""
cmd_text=""
task_callmode=2
task_grid=""
task_truncation=79
task_nfld=1
task_nlev=1
task_nproma=0
task_npromatr=0

device_kind=""
precision_kind=""
exe=""
env_init=""
log_root=""
index_tsv=""
error_log=""
omp_threads=1
cpu_cores_total=1
gpu_count_effective=0
compute_line=""
mpirun_text=""
inner_script=""

typeset -a benchmark_args
typeset -a index_rows
benchmark_args=()
index_rows=()

interrupted=0
terminate_reason=""
current_label=""
current_runid=""
current_log_path=""
current_exit_code=0
current_child_pid=""

usage() {
  cat <<'EOF'
用法:
  task_benchmark_series_h100.sh \
    --label-base task002-mode2 \
    --target gpu-dp \
    --repeats 1 \
    --partition h100x \
    --nodes 1 \
    --ntasks 1 \
    --cpus-per-task 2 \
    --gpus 1 \
    --profile release \
    -- \
    -n 1 --niter-warmup 0 -t 159 -f 4 -l 4 --callmode 2 \
    --vordiv --scders --uvders --nproma 512 --npromatr 1024 -v

说明:
  --target 仅支持 cpu-dp cpu-sp gpu-dp gpu-sp
  --profile 仅支持 release debug
  --gpus 对cpu-*目标也保留，便于在GPU分区上申请资源并做日志溯源
  重复次数repeats保留，GPU下每一轮都会重新提交一次yhrun
EOF
}

sanitize_label() {
  local raw="$1"
  local cleaned
  cleaned=$(printf '%s' "$raw" | tr -cs '[:alnum:]._-' '_')
  cleaned=${cleaned##_}
  cleaned=${cleaned%%_}
  printf '%s' "$cleaned"
}

now_epoch() {
  "$perl_bin" -MTime::HiRes=gettimeofday -e '($s,$us)=gettimeofday; printf "%d.%06d\n", $s, $us'
}

now_stamp() {
  "$perl_bin" -MTime::HiRes=gettimeofday -MPOSIX=strftime -e '($s,$us)=gettimeofday; print strftime("%Y-%m-%d %H:%M:%S", localtime($s)), sprintf(".%06d %s\n", $us, strftime("%z", localtime($s)))'
}

duration_ms() {
  "$perl_bin" -e 'my ($start,$end)=@ARGV; printf "%.3f\n", ($end-$start)*1000.0' "$1" "$2"
}

backup_if_exists() {
  local target_path="$1"
  local bak_ts
  if [[ -e "$target_path" ]]; then
    bak_ts=$("$perl_bin" -MTime::HiRes=gettimeofday -MPOSIX=strftime -e '($s,$us)=gettimeofday; print strftime("%Y%m%d%H%M%S", localtime($s)), sprintf("%06d\n", $us)')
    cp "$target_path" "$target_path.bak-$bak_ts"
  fi
}

join_args() {
  local text=""
  local arg
  for arg in "$@"; do
    if [[ -n "$text" ]]; then
      text+=" "
    fi
    text+="$arg"
  done
  printf '%s' "$text"
}

parse_benchmark_args_metadata() {
  task_callmode=2
  task_grid=""
  task_truncation=79
  task_nfld=1
  task_nlev=1
  task_nproma=0
  task_npromatr=0

  while (( $# > 0 )); do
    case "$1" in
      -t|--truncation) task_truncation="$2"; shift 2 ;;
      -g|--grid) task_grid="$2"; shift 2 ;;
      -f|--nfld) task_nfld="$2"; shift 2 ;;
      -l|--nlev) task_nlev="$2"; shift 2 ;;
      --callmode) task_callmode="$2"; shift 2 ;;
      --nproma) task_nproma="$2"; shift 2 ;;
      --npromatr) task_npromatr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$task_grid" ]]; then
    task_grid="O$((task_truncation + 1))"
  fi
}

extract_runtime_value() {
  local logfile="$1"
  local key="$2"
  local fallback="$3"
  local value

  value=$(awk -v key="$key" '$1 == key { print $2; exit }' "$logfile")
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

append_index_row() {
  local runid="$1"
  local log_path="$2"
  local exit_code="$3"
  local elapsed_ms="$4"
  local effective_grid
  local effective_truncation
  local effective_nfld
  local effective_nlev
  local effective_nproma
  local effective_npromatr

  effective_grid=$(extract_runtime_value "$log_path" "grid" "$task_grid")
  effective_truncation=$(extract_runtime_value "$log_path" "nsmax" "$task_truncation")
  effective_nfld=$(extract_runtime_value "$log_path" "nfld" "$task_nfld")
  effective_nlev=$(extract_runtime_value "$log_path" "nlev" "$task_nlev")
  effective_nproma=$(extract_runtime_value "$log_path" "nproma" "$task_nproma")
  effective_npromatr=$(extract_runtime_value "$log_path" "npromatr" "$task_npromatr")

  index_rows+=("${taskid}"$'\t'"${runid}"$'\t'"${canonical_label}"$'\t'"${device_kind}"$'\t'"${precision_kind}"$'\t'"${gpu_count_effective}"$'\t'"${ntasks}"$'\t'"${cpus_per_task}"$'\t'"${cpu_cores_total}"$'\t'"${omp_threads}"$'\t'"${task_callmode}"$'\t'"${effective_grid}"$'\t'"${effective_truncation}"$'\t'"${effective_nfld}"$'\t'"${effective_nlev}"$'\t'"${effective_nproma}"$'\t'"${effective_npromatr}"$'\t'"${exit_code}"$'\t'"${elapsed_ms}"$'\t'"${log_path}"$'\t'"${args_text}")
}

write_task_index() {
  local tmp_index

  tmp_index=$(mktemp "${TMPDIR:-/tmp}/ectrans.task_index.XXXXXX")
  {
    printf 'taskid\trunid\tlabel\tdevice\tprecision\tgpus\tntasks\tcpus_per_task\tcpu_cores_total\tomp_threads\tcallmode\tgrid\ttruncation\tnfld\tnlev\tnproma\tnpromatr\texit_code\tduration_ms\tlogfile\targs\n'
    if [[ -f "$index_tsv" ]]; then
      awk -F '\t' -v taskid="$taskid" 'NR > 1 && $1 != taskid { print }' "$index_tsv"
    fi
    for row in "${index_rows[@]}"; do
      printf '%s\n' "$row"
    done
  } > "$tmp_index"

  backup_if_exists "$index_tsv"
  mv "$tmp_index" "$index_tsv"
}

append_error_log() {
  local reason="$1"
  local error_stamp
  error_stamp=$(now_stamp)
  {
    printf '[%s] %s\n' "$error_stamp" "$reason"
    printf 'label_base=%s\n' "$canonical_label"
    printf 'runid=%s\n' "$current_runid"
    printf 'label=%s\n' "$current_label"
    printf 'logfile=%s\n' "$current_log_path"
    printf 'cmd=%s\n' "$cmd_text"
    printf '\n'
  } >> "$error_log"
}

handle_sigint() {
  interrupted=1
  terminate_reason="人工Ctrl+C中止"
  if [[ -n "$current_child_pid" ]]; then
    kill -INT "$current_child_pid" 2>/dev/null || true
  fi
}

trap 'handle_sigint' INT

configure_target() {
  case "$target" in
    cpu-dp) device_kind="cpu"; precision_kind="dp" ;;
    cpu-sp) device_kind="cpu"; precision_kind="sp" ;;
    gpu-dp) device_kind="gpu"; precision_kind="dp" ;;
    gpu-sp) device_kind="gpu"; precision_kind="sp" ;;
    *)
      printf '%s\n' "不支持的 --target: $target" >&2
      exit 1
      ;;
  esac

  case "$profile" in
    release|debug) ;;
    *)
      printf '%s\n' "不支持的 --profile: $profile" >&2
      exit 1
      ;;
  esac

  env_init="$repo_root/env/envInit.sh"
  exe="$repo_root/install/ectrans-${device_kind}-${profile}/bin/ectrans-benchmark-${device_kind}-${precision_kind}"
  if [[ "$device_kind" == "gpu" ]]; then
    if [[ -z "$gpus" ]]; then
      gpus="$ntasks"
    fi
    gpu_count_effective="$gpus"
    log_root="$repo_root/data/gpulog"
  else
    if [[ -z "$gpus" ]]; then
      gpus=1
    fi
    gpu_count_effective="$gpus"
    log_root="$repo_root/data/cpulog"
  fi
  index_tsv="$log_root/task_index.tsv"
  error_log="$log_root/error.log"

  omp_threads="$cpus_per_task"
  cpu_cores_total=$((ntasks * cpus_per_task))
  compute_line="${device_kind} ${precision_kind} gpus=${gpu_count_effective} ntasks=${ntasks} cpus_per_task=${cpus_per_task} cpu_cores_total=${cpu_cores_total} omp_threads=${omp_threads}"

  [[ -r "$env_init" ]] || { printf '%s\n' "缺少环境脚本: $env_init" >&2; exit 1; }
  [[ -x "$exe" ]] || { printf '%s\n' "缺少可执行文件: $exe" >&2; exit 1; }
}

while (( $# > 0 )); do
  case "$1" in
    --label-base) label_base="$2"; shift 2 ;;
    --repeats) repeats="$2"; shift 2 ;;
    --sleep-between) sleep_between="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    --partition) partition="$2"; shift 2 ;;
    --nodes) nodes="$2"; shift 2 ;;
    --ntasks) ntasks="$2"; shift 2 ;;
    --cpus-per-task) cpus_per_task="$2"; shift 2 ;;
    --gpus) gpus="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; benchmark_args=("$@"); break ;;
    *) benchmark_args+=("$1"); shift ;;
  esac
done

label_base=$(sanitize_label "$label_base")
if [[ -z "$label_base" ]]; then
  printf '%s\n' "missing --label-base" >&2
  exit 1
fi
if [[ -z "$target" ]]; then
  printf '%s\n' "missing --target" >&2
  exit 1
fi
if (( ${#benchmark_args[@]} == 0 )); then
  printf '%s\n' "missing benchmark args after --" >&2
  exit 1
fi

if [[ "$label_base" =~ ^task([0-9]+)(.*)$ ]]; then
  task_number_raw="${BASH_REMATCH[1]}"
  task_suffix="${BASH_REMATCH[2]}"
  task_number=$((10#$task_number_raw))
  taskid=$(printf '%03d' "$task_number")
  canonical_label="task${taskid}${task_suffix}"
else
  taskid="000"
  canonical_label="$label_base"
fi

resolve_repo_root
configure_target

args_text=$(join_args "${benchmark_args[@]}")
parse_benchmark_args_metadata "${benchmark_args[@]}"

yhrun_cmd=(yhrun -p "$partition" -N "$nodes" -n 1 -c "$cpu_cores_total")
if (( gpu_count_effective > 0 )); then
  yhrun_cmd+=(-G "$gpu_count_effective")
fi
mpirun_cmd=(mpirun -np "$ntasks" "$exe" "${benchmark_args[@]}")
printf -v mpirun_text '%q ' "${mpirun_cmd[@]}"
mpirun_text=${mpirun_text% }
inner_script=$(cat <<EOF
set -euo pipefail
module purge >/dev/null 2>&1 || true
module load nvhpc/24.1-openmpi4 >/dev/null 2>&1
if [[ "$device_kind" == "gpu" ]]; then
  module load CUDA/12.3 >/dev/null 2>&1 || true
fi
source '$env_init'
export ECTRANS_HOME='$repo_root/install/ectrans-${device_kind}-${profile}'
export ECTRANS_BIN='$exe'
export PATH="\$ECTRANS_HOME/bin:\$PATH"
export OMP_NUM_THREADS='$omp_threads'
echo compute_node=\$(hostname)
echo CUDA_VISIBLE_DEVICES=\${CUDA_VISIBLE_DEVICES-}
echo OMP_NUM_THREADS=\$OMP_NUM_THREADS
echo ECTRANS_BIN=\$ECTRANS_BIN
$mpirun_text
EOF
)
cmd_text="$(join_args "${yhrun_cmd[@]}") bash -lc $(printf '%q' "$inner_script")"
host_name=$(hostname)

mkdir -p "$log_root"

printf 'label_base : %s\n' "$canonical_label"
printf 'target     : %s\n' "$target"
printf 'repeats    : %s\n' "$repeats"
printf 'log_root   : %s\n' "$log_root"
printf 'compute    : %s\n' "$compute_line"

for ((i = 1; i <= repeats; ++i)); do
  idx=$(printf '%02d' "$i")
  runid="${idx}/$(printf '%02d' "$repeats")"
  log_label="${canonical_label}run${idx}"
  log_path="$log_root/${log_label}.log"
  tmp_path=$(mktemp "${TMPDIR:-/tmp}/ectrans.${log_label}.XXXXXX")
  current_label="$log_label"
  current_runid="$runid"
  current_log_path="$log_path"

  backup_if_exists "$log_path"
  start_epoch=$(now_epoch)
  start_stamp=$(now_stamp)
  printf 'running    : %s\n' "$log_label"

  set +e
  current_child_pid=""
  "${yhrun_cmd[@]}" bash -lc "$inner_script" >"$tmp_path" 2>&1 &
  current_child_pid=$!
  wait "$current_child_pid"
  code=$?
  current_child_pid=""
  set -e
  current_exit_code="$code"

  end_epoch=$(now_epoch)
  end_stamp=$(now_stamp)
  elapsed_ms=$(duration_ms "$start_epoch" "$end_epoch")

  {
    printf '# label: %s\n' "$log_label"
    printf '# run_index: %s\n' "$runid"
    printf '# compute: %s\n' "$compute_line"
    printf '# start_timestamp: %s\n' "$start_stamp"
    printf '# end_timestamp: %s\n' "$end_stamp"
    printf '# duration_ms: %s\n' "$elapsed_ms"
    printf '# cwd: %s\n' "$repo_root"
    printf '# bin: %s\n' "$exe"
    printf '# cmd: %s\n' "$cmd_text"
    printf '# host: %s\n' "$host_name"
    printf '# pid: %s\n' "$$"
    printf '# exit_code: %s\n' "$code"
    cat "$tmp_path"
  } > "$log_path"
  rm -f "$tmp_path"

  append_index_row "$runid" "$log_path" "$code" "$elapsed_ms"
  write_task_index

  if (( interrupted )); then
    append_error_log "$terminate_reason"
    printf '已写入%s\n' "$error_log"
    exit 130
  fi

  if (( code != 0 )); then
    append_error_log "运行中止：${log_label} exit_code=${code}"
    printf '已写入%s\n' "$error_log"
    exit "$code"
  fi

  if (( i < repeats )) && [[ "$sleep_between" != "0" ]]; then
    sleep "$sleep_between"
  fi
done

printf '已写入%s\n' "$index_tsv"
