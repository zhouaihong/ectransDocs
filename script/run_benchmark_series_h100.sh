#!/usr/bin/env bash
# type:sh
# effect:H100顺序多次运行ectransbenchmark;日志写入runs/logs;索引写入runs/rundata;单task只重写一次TSV
# 260726 release 标记任务索引与历史制品规范版本
# version:60726_01

set -euo pipefail
echome_default="/HOME/acict_hpjia/acict_hpjia_1/HDD_POOL/ectrans-dev"
echome="${echome:-${EC_HOME:-$echome_default}}"
echome="${echome%/}"
repo_root="$echome"
perl_bin="/usr/bin/perl"

label_base=""
repeats=1
sleep_between=0
target=""
profile="release"
bin_version=""
# 260726 ret begin 记录代码commit、构建制品和验证用例
requested_commit=""
requested_artifact_id=""
case_id=""
selected_commit=""
selected_commit_full=""
selected_build_version=""
selected_artifact_id=""
selected_manifest=""
artifact_index=""
block_index=""
index_schema=1
# 260726 ret end
partition="${PARTITION:-h100x}"
nodes=1
ntasks=1
cpu_threads=2
gpus=""
niter=1
niter_warmup=0
dry_run=0
log_root="$repo_root/runs/logs"
rundata_root="$repo_root/runs/rundata"

device_kind=""
precision_kind=""
exe=""
env_init="$repo_root/env/envInit.sh"
install_home=""
index_tsv=""
error_log=""
canonical_label=""
taskid=""
args_text=""
cmd_text=""
current_child_pid=""
current_label=""
current_runid=""
current_log_path=""
interrupted=0
terminate_reason=""
# 260726 ret begin 记录任务索引新增运行状态
task_slurm_job_id=""
task_compute_node=""
task_run_status=""
commit_mismatch=0
# 260726 ret end

task_callmode=""
task_grid=""
task_truncation=""
task_nfld=""
task_nlev=""
task_nproma=""
task_npromatr=""
task_nprtrw=""
task_nprtrv=""

typeset -a benchmark_args benchmark_cmd index_rows
benchmark_args=()
benchmark_cmd=()
index_rows=()

sanitize_label() {
  local raw="$1"
  local cleaned
  cleaned=$(printf '%s' "$raw" | tr -cs '[:alnum:]._-' '_')
  cleaned=${cleaned##_}
  cleaned=${cleaned%%_}
  printf '%s' "$cleaned"
}

now_epoch() {
  "$perl_bin" -MTime::HiRes=gettimeofday -e '($s,$us)=gettimeofday;printf "%d.%06d\n",$s,$us'
}

now_stamp() {
  "$perl_bin" -MTime::HiRes=gettimeofday -MPOSIX=strftime -e '($s,$us)=gettimeofday;print strftime("%Y-%m-%d %H:%M:%S",localtime($s)),sprintf(".%06d %s\n",$us,strftime("%z",localtime($s)))'
}

duration_ms() {
  "$perl_bin" -e 'my($start,$end)=@ARGV;printf "%.3f\n",($end-$start)*1000.0' "$1" "$2"
}

join_args() {
  local text=""
  local arg
  for arg in "$@"; do
    [[ -n "$text" ]] && text+=" "
    text+="$arg"
  done
  printf '%s' "$text"
}

# 260726 ret begin 解析commit与现有历史构建制品
normalize_short_commit() {
  local value
  value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$value" =~ ^[0-9a-f]{8}$ ]] || return 1
  printf '%s' "$value"
}

manifest_value() {
  local manifest="$1"
  local key="$2"
  [[ -r "$manifest" ]] || return 0
  awk -F '\t' -v key="$key" '$1==key{print $2;exit}' "$manifest" 2>/dev/null || true
}

validate_selected_libraries() {
  local library_path=""
  local library_count=0
  while IFS= read -r library_path; do
    [[ -n "$library_path" ]] || continue
    library_count=$((library_count + 1))
    [[ "$library_path" == "$install_home/lib/"* ]] || exit 1
  done < <(env LD_LIBRARY_PATH="$install_home/lib:${LD_LIBRARY_PATH:-}" ldd "$exe" 2>/dev/null | awk '$1~/^libectrans/&&$2=="=>"{print $3}')
  (( library_count > 0 )) || exit 1
}

resolve_bin_version_for_commit() {
  local source_commit=""
  local registry_line=""
  local registry_count=0
  local registry_commit registry_version registry_profile registry_artifact registry_manifest
  local candidate version install_candidate
  local -a matches
  matches=()

  [[ -z "$bin_version" ]] || return 0

  if [[ -r "$artifact_index" ]]; then
    while IFS= read -r registry_line; do
      [[ -n "$registry_line" ]] || continue
      registry_count=$((registry_count + 1))
      if (( registry_count == 1 )); then
        IFS=$'\t' read -r registry_commit registry_version registry_profile registry_artifact registry_manifest <<< "$registry_line"
      fi
    done < <(awk -F '\t' -v commit="$requested_commit" -v profile="${device_kind}-${profile}" -v artifact="$requested_artifact_id" '
      NR>1&&$1==commit&&$3==profile&&(artifact==""||$4==artifact){print}
    ' "$artifact_index")
    if (( registry_count == 1 )); then
      bin_version="$registry_version"
      selected_artifact_id="$registry_artifact"
      if [[ -n "$registry_manifest" ]]; then
        if [[ "$registry_manifest" == /* ]]; then
          selected_manifest="$registry_manifest"
        else
          selected_manifest="$repo_root/$registry_manifest"
        fi
      fi
      return 0
    fi
    (( registry_count == 0 )) || exit 1
  fi

  if git -C "$repo_root/src/ectrans" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    source_commit=$(git -C "$repo_root/src/ectrans" rev-parse --short=8 HEAD 2>/dev/null || true)
    source_commit=$(printf '%s' "$source_commit" | tr '[:upper:]' '[:lower:]')
  fi
  [[ "$source_commit" != "$requested_commit" ]] || return 0

  while IFS= read -r candidate; do
    version=$(basename "$candidate")
    install_candidate="$repo_root/install/${version}-${device_kind}-${profile}"
    [[ -d "$install_candidate" ]] && matches+=("$version")
  done < <(find "$repo_root/runs/bin" -mindepth 1 -maxdepth 1 -type d -name "*-${requested_commit}*" -print 2>/dev/null | sort)

  (( ${#matches[@]} == 1 )) || exit 1
  bin_version="${matches[0]}"
}

resolve_selected_metadata() {
  local manifest_commit=""
  local manifest_full=""
  local manifest_artifact=""
  local manifest_version=""
  local manifest_profile=""
  local parsed_commit=""

  if [[ -z "$selected_manifest" && -r "$install_home/manifest.tsv" ]]; then
    selected_manifest="$install_home/manifest.tsv"
  fi
  if [[ -n "$selected_manifest" ]]; then
    manifest_commit=$(manifest_value "$selected_manifest" "commit_short")
    manifest_full=$(manifest_value "$selected_manifest" "commit_full")
    manifest_artifact=$(manifest_value "$selected_manifest" "artifact_id")
    manifest_version=$(manifest_value "$selected_manifest" "bin_version")
    manifest_profile=$(manifest_value "$selected_manifest" "profile")
    [[ -n "$manifest_commit" ]] && manifest_commit=$(normalize_short_commit "$manifest_commit")
  fi

  if [[ "$bin_version" =~ -([0-9a-fA-F]{8})(-|$) ]]; then
    parsed_commit=$(normalize_short_commit "${BASH_REMATCH[1]}")
  fi
  [[ -z "$requested_commit" || -z "$parsed_commit" || "$requested_commit" == "$parsed_commit" ]] || exit 1

  if [[ -n "$requested_commit" ]]; then
    selected_commit="$requested_commit"
  elif [[ -n "$manifest_commit" ]]; then
    selected_commit="$manifest_commit"
  elif [[ -n "$parsed_commit" ]]; then
    selected_commit="$parsed_commit"
  else
    selected_commit=$(git -C "$repo_root/src/ectrans" rev-parse --short=8 HEAD 2>/dev/null || true)
    selected_commit=$(normalize_short_commit "$selected_commit")
  fi

  [[ -z "$manifest_commit" || "$manifest_commit" == "$selected_commit" ]] || exit 1
  [[ -z "$manifest_version" || "$manifest_version" == "${bin_version:-current}" ]] || exit 1
  [[ -z "$manifest_profile" || "$manifest_profile" == "${device_kind}-${profile}" ]] || exit 1
  selected_commit_full="$manifest_full"
  if [[ -z "$selected_commit_full" && -z "$bin_version" ]]; then
    selected_commit_full=$(git -C "$repo_root/src/ectrans" rev-parse HEAD 2>/dev/null || true)
  fi
  selected_build_version="${bin_version:-current}"
  if [[ -n "$manifest_artifact" ]]; then
    [[ -z "$selected_artifact_id" || "$selected_artifact_id" == "$manifest_artifact" ]] || exit 1
    selected_artifact_id="$manifest_artifact"
  elif [[ -z "$selected_artifact_id" ]]; then
    selected_artifact_id="${selected_commit}-${selected_build_version}-${device_kind}-${profile}"
  fi
  [[ -z "$requested_artifact_id" || "$requested_artifact_id" == "$selected_artifact_id" ]] || exit 1
}

register_task_block() {
  local block_start=$((task_number / 10 * 10))
  local assigned_commit=""
  local lock_file="${block_index}.lock"
  local lock_fd

  (( task_number >= 100 )) || return 0
  mkdir -p "$(dirname "$block_index")"
  exec {lock_fd}>"$lock_file"
  flock "$lock_fd"
  if [[ -f "$block_index" ]]; then
    assigned_commit=$(awk -F '\t' -v block="$block_start" 'NR>1&&$1==block{print $2;exit}' "$block_index")
  fi
  if [[ -z "$assigned_commit" ]]; then
    (( task_number % 10 == 0 )) || { flock -u "$lock_fd"; exit 1; }
    if [[ ! -s "$block_index" ]]; then
      printf '号段起点\t代码commit\t分配时间\t说明\n' > "$block_index"
    fi
    printf '%s\t%s\t%s\t%s\n' "$block_start" "$selected_commit" "$(date '+%Y%m%d%H%M%S')" "task${block_start}-task$((block_start + 9))" >> "$block_index"
  else
    [[ "$assigned_commit" == "$selected_commit" ]] || { flock -u "$lock_fd"; exit 1; }
  fi
  flock -u "$lock_fd"
}
# 260726 ret end

parse_benchmark_args_metadata() {
  task_callmode=""
  task_grid=""
  task_truncation=""
  task_nfld=""
  task_nlev=""
  task_nproma=""
  task_npromatr=""
  task_nprtrw=""
  task_nprtrv=""
  while (( $# > 0 )); do
    case "$1" in
      -t|--truncation) task_truncation="${2:-}"; shift 2 ;;
      -g|--grid) task_grid="${2:-}"; shift 2 ;;
      -f|--nfld) task_nfld="${2:-}"; shift 2 ;;
      -l|--nlev) task_nlev="${2:-}"; shift 2 ;;
      --callmode) task_callmode="${2:-}"; shift 2 ;;
      --nproma) task_nproma="${2:-}"; shift 2 ;;
      --npromatr) task_npromatr="${2:-}"; shift 2 ;;
      --nprtrw) task_nprtrw="${2:-}"; shift 2 ;;
      --nprtrv) task_nprtrv="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -z "$task_grid" && -n "$task_truncation" ]]; then
    task_grid="O$((task_truncation + 1))"
  fi
  return 0
}

extract_runtime_value() {
  local logfile="$1"
  local key="$2"
  local fallback="$3"
  local value=""
  [[ -r "$logfile" ]] && value=$(awk -v key="$key" '$1==key{print $2;exit}' "$logfile" || true)
  [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

extract_marker_value() {
  local logfile="$1"
  local key="$2"
  awk -F '=' -v key="$key" '$1==key{print substr($0,index($0,"=")+1);exit}' "$logfile" 2>/dev/null || true
}

# 260726 ret begin 从benchmark输出提取实际代码commit
extract_runtime_commit() {
  local logfile="$1"
  local runtime_commit=""
  runtime_commit=$(extract_runtime_value "$logfile" "commit:" "")
  runtime_commit="${runtime_commit:0:8}"
  [[ -n "$runtime_commit" ]] || return 0
  normalize_short_commit "$runtime_commit" || true
}
# 260726 ret end

append_index_row() {
  local runid="$1"
  local log_path="$2"
  local exit_code="$3"
  local elapsed_ms="$4"
  local submit_elapsed_ms="$5"
  # 260726 ret begin 接收实际代码commit、作业状态和调度信息
  local code_commit="$6"
  local run_status="$7"
  local slurm_job_id="$8"
  local compute_node="${9}"
  local row
  # 260726 ret end
  local effective_grid effective_truncation effective_nfld effective_nlev effective_nproma effective_npromatr effective_nprtrw effective_nprtrv
  effective_grid=$(extract_runtime_value "$log_path" "grid" "$task_grid")
  effective_truncation=$(extract_runtime_value "$log_path" "nsmax" "$task_truncation")
  effective_nfld=$(extract_runtime_value "$log_path" "nfld" "$task_nfld")
  effective_nlev=$(extract_runtime_value "$log_path" "nlev" "$task_nlev")
  effective_nproma=$(extract_runtime_value "$log_path" "nproma" "$task_nproma")
  effective_npromatr=$(extract_runtime_value "$log_path" "npromatr" "$task_npromatr")
  effective_nprtrw=$(extract_runtime_value "$log_path" "nprtrw" "$task_nprtrw")
  effective_nprtrv=$(extract_runtime_value "$log_path" "nprtrv" "$task_nprtrv")
  row="${taskid}"$'\t'"${runid}"$'\t'"${canonical_label}"$'\t'"${device_kind}"$'\t'"${target}"$'\t'"${profile}"$'\t'"${precision_kind}"$'\t'"${cpu_threads}"$'\t'"${cpu_cores_total}"$'\t'"${gpus}"$'\t'"${niter_warmup}"$'\t'"${niter}"$'\t'"${partition}"$'\t'"${nodes}"$'\t'"${ntasks}"$'\t'"${task_callmode}"$'\t'"${effective_grid}"$'\t'"${effective_truncation}"$'\t'"${effective_nfld}"$'\t'"${effective_nlev}"$'\t'"${effective_nproma}"$'\t'"${effective_npromatr}"$'\t'"${effective_nprtrw}"$'\t'"${effective_nprtrv}"$'\t'"${exit_code}"$'\t'"${elapsed_ms}"$'\t'"${submit_elapsed_ms}"$'\t'"${log_path}"$'\t'"${args_text}"
  # 260726 ret begin task100起追加代码、制品、用例和调度审计列
  if (( index_schema == 2 )); then
    row+=$'\t'"${code_commit}"$'\t'"${selected_build_version}"$'\t'"${selected_artifact_id}"$'\t'"${case_id}"$'\t'"${slurm_job_id}"$'\t'"${run_status}"$'\t'"${compute_node}"
  fi
  # 260726 ret end
  index_rows+=("$row")
}

write_task_index() {
  local tmp_index lock_file lock_fd row
  mkdir -p "$(dirname "$index_tsv")"
  # 260726 ret begin 加锁后按完整标签覆盖本次任务结果
  lock_file="${index_tsv}.lock"
  exec {lock_fd}>"$lock_file"
  flock "$lock_fd"
  tmp_index=$(mktemp "${TMPDIR:-/tmp}/ectrans.task_index.${device_kind}.XXXXXX")
  {
    if (( index_schema == 2 )); then
      printf '任务ID\t运行ID\t标签\t设备\t目标\t构建类型\t精度\tCPU线程数\tCPU总线程数\tGPU申请数\t预热次数\t迭代次数\t分区\t节点数\tMPI进程数\tcallmode\tgrid\ttruncation\tnfld\tnlev\tnproma\tnpromatr\tnprtrw\tnprtrv\t退出码\t耗时毫秒\t提交耗时毫秒\t日志路径\t参数\t代码commit\t构建版本\t制品ID\t用例ID\tSlurm作业ID\t运行状态\t计算节点\n'
    else
      printf '任务ID\t运行ID\t标签\t设备\t目标\t构建类型\t精度\tCPU线程数\tCPU总线程数\tGPU申请数\t预热次数\t迭代次数\t分区\t节点数\tMPI进程数\tcallmode\tgrid\ttruncation\tnfld\tnlev\tnproma\tnpromatr\tnprtrw\tnprtrv\t退出码\t耗时毫秒\t提交耗时毫秒\t日志路径\t参数\n'
    fi
    # 260719 wrqt begin 按完整标签替换本次结果，保留相同任务编号的其他版本
    [[ -f "$index_tsv" ]] && awk -F '\t' -v label="$canonical_label" 'NR>1&&$3!=label{print}' "$index_tsv"
    # 260719 wrqt end 按完整标签替换本次结果，保留相同任务编号的其他版本
    for row in "${index_rows[@]}"; do
      printf '%s\n' "$row"
    done
  } > "$tmp_index"
  mv "$tmp_index" "$index_tsv"
  flock -u "$lock_fd"
  # 260726 ret end
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
    printf 'cmd=%s\n\n' "$cmd_text"
  } >> "$error_log"
}

handle_sigint() {
  interrupted=1
  terminate_reason="人工Ctrl+C中止"
  [[ -n "$current_child_pid" ]] && kill -INT "$current_child_pid" 2>/dev/null || true
}
trap 'handle_sigint' INT

screen_progress_filter() {
  awk '
    function emit(){print;fflush()}
    /^yhrun:/ {emit();next}
    # 260717 wrqt begin 把每轮开始标记显示到终端
    /^__EC_RUN_BEGIN=/ {sub(/^__EC_RUN_BEGIN=/,"running        : ");emit();next}
    # 260717 wrqt end 把每轮开始标记显示到终端
    /^__EC_BENCH_START_TIMESTAMP=/ {sub(/^__EC_BENCH_START_TIMESTAMP=/,"benchmark_start=");emit();next}
    /^__EC_BENCH_END_TIMESTAMP=/ {sub(/^__EC_BENCH_END_TIMESTAMP=/,"benchmark_end=");emit();next}
    /^__EC_BENCH_EXIT_CODE=/ {sub(/^__EC_BENCH_EXIT_CODE=/,"benchmark_exit_code=");emit();next}
    # 260726 ret begin 显示作业、节点和构建制品身份
    /^(slurm_job_id|compute_node|CUDA_VISIBLE_DEVICES|OMP_NUM_THREADS|ECTRANS_BIN|selected_commit|build_version|artifact_id|case_id)=/ {emit();next}
    # 260726 ret end
    /^GPU .*version/ {emit();next}
    /^ ===GPU arrays successfully allocated/ {emit();next}
    /^======= Start of runtime parameters =======/ {in_runtime=1;emit();next}
    /^======= End of runtime parameters =======/ {in_runtime=0;emit();next}
    in_runtime {emit();next}
    /(^|[[:space:]])(grid|nsmax|nfld|nlev|nproma|npromatr|nprtrw|nprtrv)([[:space:]=]|$)/ {emit();next}
    /(ERROR|Error|error|WARNING|Warning|warning|abort|Abort|failed|Failed|not found|cannot open shared object file|Exit code|exit code)/ {emit();next}
    /^Time step[[:space:]]+/ {
      step=$3+0
      if(step==1 || step%10==0) emit()
      next
    }
    /^[[:space:]]+[0-9]+[[:space:]]+TIME STEP[[:space:]]+-/ {emit();next}
    /^TOTAL WALLCLOCK TIME/ {emit();next}
  '
}

configure_target() {
  case "$target" in
    cpu-dp) device_kind="cpu"; precision_kind="dp" ;;
    cpu-sp) device_kind="cpu"; precision_kind="sp" ;;
    gpu-dp) device_kind="gpu"; precision_kind="dp" ;;
    gpu-sp) device_kind="gpu"; precision_kind="sp" ;;
    *) exit 2 ;;
  esac
  case "$profile" in
    release|debug) ;;
    *) exit 2 ;;
  esac
  [[ -z "$gpus" ]] && gpus=1
  # 260726 ret begin 由commit解析现有历史构建版本
  if [[ -n "$requested_commit" ]]; then
    resolve_bin_version_for_commit
  fi
  # 260726 ret end
  # 260719 wrqt begin 指定版本时同时选择归档bin和对应install共享库
  if [[ -n "$bin_version" ]]; then
    exe="$repo_root/runs/bin/$bin_version/ectrans-benchmark-${device_kind}-${profile}-${precision_kind}"
    install_home="$repo_root/install/${bin_version}-${device_kind}-${profile}"
  else
    exe="$repo_root/runs/bin/ectrans-benchmark-${device_kind}-${profile}-${precision_kind}"
    install_home="$repo_root/install/ectrans-${device_kind}-${profile}"
  fi
  # 260719 wrqt end 指定版本时同时选择归档bin和对应install共享库
  # 260726 ret begin task100起使用含代码commit的任务索引
  if (( task_number >= 100 )); then
    index_schema=2
    index_tsv="$rundata_root/task_index_${device_kind}_v2.tsv"
  else
    index_schema=1
    index_tsv="$rundata_root/task_index_${device_kind}.tsv"
  fi
  # 260726 ret end
  error_log="$log_root/error_${device_kind}.log"
  [[ -r "$env_init" ]] || exit 1
  [[ -x "$exe" ]] || exit 1
  [[ -d "$install_home" ]] || exit 1
  # 260726 ret begin 校验ectrans动态库来自所选install目录
  validate_selected_libraries
  # 260726 ret end
  # 260726 ret begin 确认本次实际选择的代码与构建制品
  resolve_selected_metadata
  # 260726 ret end
}

while (( $# > 0 )); do
  case "$1" in
    --label-base) label_base="$2"; shift 2 ;;
    --repeats) repeats="$2"; shift 2 ;;
    --sleep-between) sleep_between="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    # 260719 wrqt begin 接收runs/bin和install共用的版本标识
    --bin-version) bin_version="$2"; shift 2 ;;
    # 260719 wrqt end 接收runs/bin和install共用的版本标识
    # 260726 ret begin 接收代码commit、制品和用例标识
    --commit) requested_commit="$2"; shift 2 ;;
    --artifact-id) requested_artifact_id="$2"; shift 2 ;;
    --case-id) case_id="$2"; shift 2 ;;
    # 260726 ret end
    --partition) partition="$2"; shift 2 ;;
    --nodes) nodes="$2"; shift 2 ;;
    --ntasks) ntasks="$2"; shift 2 ;;
    --cpu-threads) cpu_threads="$2"; shift 2 ;;
    --gpus) gpus="$2"; shift 2 ;;
    --niter) niter="$2"; shift 2 ;;
    --niter-warmup) niter_warmup="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --) shift; benchmark_args=("$@"); break ;;
    *) exit 2 ;;
  esac
done

label_base=$(sanitize_label "$label_base")
[[ -n "$label_base" ]] || exit 1
[[ -n "$target" ]] || exit 1
(( ${#benchmark_args[@]} > 0 )) || exit 1

if [[ "$label_base" =~ ^task([0-9]+)(.*)$ ]]; then
  task_number_raw="${BASH_REMATCH[1]}"
  task_suffix="${BASH_REMATCH[2]}"
  task_number=$((10#$task_number_raw))
  taskid=$(printf '%03d' "$task_number")
  canonical_label="task${taskid}${task_suffix}"
else
  exit 1
fi

# 260726 ret begin 规范commit与用例标识并指定制品登记文件
if [[ -n "$requested_commit" ]]; then
  requested_commit=$(normalize_short_commit "$requested_commit")
fi
requested_artifact_id=$(sanitize_label "$requested_artifact_id")
case_id=$(sanitize_label "$case_id")
if [[ -z "$case_id" ]]; then
  case_id="${task_suffix#[-_.]}"
  case_id=$(sanitize_label "$case_id")
fi
[[ -n "$case_id" ]] || case_id="default"
artifact_index="$rundata_root/build_artifacts.tsv"
block_index="$rundata_root/commit_task_blocks.tsv"
# 260726 ret end

configure_target
benchmark_cmd=("$exe" -n "$niter" --niter-warmup "$niter_warmup" "${benchmark_args[@]}")
args_text=$(join_args "${benchmark_cmd[@]}")
parse_benchmark_args_metadata "${benchmark_args[@]}"

cpu_cores_total=$((ntasks * cpu_threads))
# 260718 wrqt begin h100x显式申请H100资源，避免-G被调度器解析为A100
if [[ "$partition" == "h100x" ]]; then
  yhrun_gpu_args=(--gres="gpu:h100:${gpus}")
else
  yhrun_gpu_args=(-G "$gpus")
fi
yhrun_cmd=(yhrun -p "$partition" -N "$nodes" -n 1 -c "$cpu_cores_total" "${yhrun_gpu_args[@]}")
# 260718 wrqt end h100x显式申请H100资源，避免-G被调度器解析为A100
mpirun_cmd=(mpirun --oversubscribe -np "$ntasks" "${benchmark_cmd[@]}")
printf -v mpirun_text '%q ' "${mpirun_cmd[@]}"
mpirun_text=${mpirun_text% }
inner_script=$(cat <<EOF_INNER
set -euo pipefail
module purge >/dev/null 2>&1 || true
module load nvhpc/24.1-openmpi4 >/dev/null 2>&1
if [[ "$device_kind" == "gpu" ]]; then
  module load CUDA/12.3 >/dev/null 2>&1 || true
fi
source '$env_init'
export ECTRANS_HOME='$install_home'
export LD_LIBRARY_PATH="\$ECTRANS_HOME/lib:\${LD_LIBRARY_PATH:-}"
export ECTRANS_BIN='$exe'
export PATH="\$ECTRANS_HOME/bin:\$PATH"
export OMP_NUM_THREADS='$cpu_threads'
# 260717 wrqt begin 向单次allocation传入repeats、运行间隔、标签和日志目录
series_repeats='$repeats'
series_sleep_between='$sleep_between'
series_label='$canonical_label'
series_log_dir='$log_root/$device_kind/task$taskid'
# 260717 wrqt end 向单次allocation传入repeats、运行间隔、标签和日志目录

# 260717 wrqt begin 将单轮benchmark封装为可重复调用的函数
run_benchmark() {
# 260726 ret begin 把Slurm作业和所选制品写入每轮日志
echo slurm_job_id=\${SLURM_JOB_ID-}
echo compute_node=\$(hostname)
echo CUDA_VISIBLE_DEVICES=\${CUDA_VISIBLE_DEVICES-}
echo OMP_NUM_THREADS=\$OMP_NUM_THREADS
echo ECTRANS_BIN=\$ECTRANS_BIN
echo selected_commit='$selected_commit'
echo build_version='$selected_build_version'
echo artifact_id='$selected_artifact_id'
echo case_id='$case_id'
# 260726 ret end
bench_start_epoch=\$("$perl_bin" -MTime::HiRes=gettimeofday -e '(\$s,\$us)=gettimeofday;printf "%d.%06d\n",\$s,\$us')
bench_start_stamp=\$("$perl_bin" -MTime::HiRes=gettimeofday -MPOSIX=strftime -e '(\$s,\$us)=gettimeofday;print strftime("%Y-%m-%d %H:%M:%S",localtime(\$s)),sprintf(".%06d %s\n",\$us,strftime("%z",localtime(\$s)))')
echo __EC_BENCH_START_EPOCH=\$bench_start_epoch
echo __EC_BENCH_START_TIMESTAMP=\$bench_start_stamp
set +e
$mpirun_text
bench_code=\$?
set -e
bench_end_epoch=\$("$perl_bin" -MTime::HiRes=gettimeofday -e '(\$s,\$us)=gettimeofday;printf "%d.%06d\n",\$s,\$us')
bench_end_stamp=\$("$perl_bin" -MTime::HiRes=gettimeofday -MPOSIX=strftime -e '(\$s,\$us)=gettimeofday;print strftime("%Y-%m-%d %H:%M:%S",localtime(\$s)),sprintf(".%06d %s\n",\$us,strftime("%z",localtime(\$s)))')
echo __EC_BENCH_END_EPOCH=\$bench_end_epoch
echo __EC_BENCH_END_TIMESTAMP=\$bench_end_stamp
echo __EC_BENCH_EXIT_CODE=\$bench_code
return "\$bench_code"
}
# 260717 wrqt end 将单轮benchmark封装为可重复调用的函数

# 260717 wrqt begin 在同一allocation内循环执行全部benchmark并分别写入日志
for ((run_index=1;run_index<=series_repeats;++run_index)); do
  idx=\$(printf '%02d' "\$run_index")
  # 260726 ret begin 使用完整标签加run编号组成标准日志名
  log_label="\${series_label}-run\${idx}"
  # 260726 ret end
  log_path="\$series_log_dir/\${log_label}.log"
  echo __EC_RUN_BEGIN=\$log_label
  set +e
  run_benchmark 2>&1 | tee -a "\$log_path"
  pipe_codes=("\${PIPESTATUS[@]}")
  bench_code="\${pipe_codes[0]}"
  if (( bench_code == 0 && pipe_codes[1] != 0 )); then
    bench_code="\${pipe_codes[1]}"
  fi
  set -e
  if (( bench_code != 0 )); then
    exit "\$bench_code"
  fi
  if [[ "\$run_index" -lt "\$series_repeats" && "\$series_sleep_between" != "0" ]]; then
    sleep "\$series_sleep_between"
  fi
done
# 260717 wrqt end 在同一allocation内循环执行全部benchmark并分别写入日志
EOF_INNER
)
cmd_text="$(join_args "${yhrun_cmd[@]}") bash -lc $(printf '%q' "$inner_script")"
host_name=$(hostname)
# 260726 ret begin 按任务ID分级保存全部运行日志
log_dir="$log_root/$device_kind/task$taskid"
# 260726 ret end

printf 'label_base     : %s\n' "$canonical_label"
printf 'device         : %s\n' "$device_kind"
printf 'target         : %s\n' "$target"
printf 'profile        : %s\n' "$profile"
# 260719 wrqt begin 显示本次实际使用的版本、可执行文件和共享库目录
printf 'bin_version    : %s\n' "${bin_version:-current}"
printf 'bin             : %s\n' "$exe"
printf 'install_home    : %s\n' "$install_home"
# 260719 wrqt end 显示本次实际使用的版本、可执行文件和共享库目录
# 260726 ret begin 显示本次代码、制品与用例身份
printf 'code_commit    : %s\n' "$selected_commit"
printf 'artifact_id    : %s\n' "$selected_artifact_id"
printf 'case_id        : %s\n' "$case_id"
printf 'manifest       : %s\n' "${selected_manifest:-none}"
# 260726 ret end
printf 'cpu_threads    : %s\n' "$cpu_threads"
printf 'cpu_threads_total: %s\n' "$cpu_cores_total"
printf 'gpus_requested : %s\n' "$gpus"
printf 'niter_warmup   : %s\n' "$niter_warmup"
printf 'niter          : %s\n' "$niter"
printf 'repeats        : %s\n' "$repeats"
printf 'log_dir        : %s\n' "$log_dir"
printf 'index_tsv      : %s\n' "$index_tsv"
printf 'command        : %s\n' "$cmd_text"

if (( dry_run )); then
  printf 'dry_run        : 1\n'
  exit 0
fi

# 260726 ret begin 正式运行时再创建日志和任务数据目录
mkdir -p "$log_dir" "$rundata_root"
# 260726 ret end

# 260726 ret begin 首次正式运行时固定commit对应的10号任务段
register_task_block
# 260726 ret end

# 260717 wrqt begin 申请资源前预建各轮日志并记录共用allocation
submit_start_epoch=$(now_epoch)
submit_start_stamp=$(now_stamp)
for ((i=1;i<=repeats;++i)); do
  idx=$(printf '%02d' "$i")
  runid="${idx}/$(printf '%02d' "$repeats")"
  # 260726 ret begin 使用完整标签加run编号组成标准日志名
  log_label="${canonical_label}-run${idx}"
  # 260726 ret end
  log_path="$log_dir/${log_label}.log"
  current_label="$log_label"
  current_runid="$runid"
  current_log_path="$log_path"
  {
    printf '# label: %s\n' "$log_label"
    printf '# device: %s\n' "$device_kind"
    printf '# target: %s\n' "$target"
    printf '# profile: %s\n' "$profile"
    # 260719 wrqt begin 把指定版本和共享库目录写入每轮标准日志
    printf '# bin_version: %s\n' "${bin_version:-current}"
    printf '# install_home: %s\n' "$install_home"
    # 260719 wrqt end 把指定版本和共享库目录写入每轮标准日志
    # 260726 ret begin 写入代码、制品与用例身份
    printf '# code_commit: %s\n' "$selected_commit"
    printf '# artifact_id: %s\n' "$selected_artifact_id"
    printf '# case_id: %s\n' "$case_id"
    printf '# manifest: %s\n' "${selected_manifest:-none}"
    # 260726 ret end
    printf '# cpu_threads: %s\n' "$cpu_threads"
    printf '# cpu_threads_total: %s\n' "$cpu_cores_total"
    printf '# gpus_requested: %s\n' "$gpus"
    printf '# niter_warmup: %s\n' "$niter_warmup"
    printf '# niter: %s\n' "$niter"
    printf '# run_index: %s\n' "$runid"
    printf '# submit_start_timestamp: %s\n' "$submit_start_stamp"
    printf '# cwd: %s\n' "$repo_root"
    printf '# bin: %s\n' "$exe"
    printf '# cmd: %s\n' "$cmd_text"
    printf '# host: %s\n' "$host_name"
    printf '# pid: %s\n' "$$"
    printf '# live_output: 1\n'
    printf '# allocation_reused: 1\n'
    printf '\n'
  } > "$log_path"
done
# 260717 wrqt end 申请资源前预建各轮日志并记录共用allocation

# 260717 wrqt begin 只申请一次yhrun allocation并等待全部benchmark结束
# 260726 ret begin 使用标准日志名跟踪当前运行
current_label="${canonical_label}-run01"
# 260726 ret end
current_runid="01/$(printf '%02d' "$repeats")"
current_log_path="$log_dir/${current_label}.log"
set +e
current_child_pid=""
"${yhrun_cmd[@]}" bash -lc "$inner_script" > >(screen_progress_filter) 2>&1 &
current_child_pid=$!
wait "$current_child_pid"
yhrun_code=$?
current_child_pid=""
set -e

submit_end_epoch=$(now_epoch)
submit_end_stamp=$(now_stamp)
allocation_elapsed_ms=$(duration_ms "$submit_start_epoch" "$submit_end_epoch")
completed_runs=0
series_code=0
# 260717 wrqt end 只申请一次yhrun allocation并等待全部benchmark结束

# 260717 wrqt begin 从各轮日志提取时间与退出状态并写入TSV
for ((i=1;i<=repeats;++i)); do
  idx=$(printf '%02d' "$i")
  runid="${idx}/$(printf '%02d' "$repeats")"
  # 260726 ret begin 使用完整标签加run编号组成标准日志名
  log_label="${canonical_label}-run${idx}"
  # 260726 ret end
  log_path="$log_dir/${log_label}.log"
  current_label="$log_label"
  current_runid="$runid"
  current_log_path="$log_path"
  bench_start_epoch=$(extract_marker_value "$log_path" "__EC_BENCH_START_EPOCH")
  bench_end_epoch=$(extract_marker_value "$log_path" "__EC_BENCH_END_EPOCH")
  benchmark_code=$(extract_marker_value "$log_path" "__EC_BENCH_EXIT_CODE")
  start_stamp=$(extract_marker_value "$log_path" "__EC_BENCH_START_TIMESTAMP")
  end_stamp=$(extract_marker_value "$log_path" "__EC_BENCH_END_TIMESTAMP")
  # 260726 ret begin 提取本轮调度信息和实际代码commit
  task_slurm_job_id=$(extract_marker_value "$log_path" "slurm_job_id")
  task_compute_node=$(extract_marker_value "$log_path" "compute_node")
  runtime_commit=$(extract_runtime_commit "$log_path")
  [[ -n "$runtime_commit" ]] || runtime_commit="$selected_commit"
  # 260726 ret end

  if [[ -z "$benchmark_code" ]]; then
    code="$yhrun_code"
    (( code == 0 )) && code=1
    elapsed_ms="$allocation_elapsed_ms"
    submit_elapsed_ms="$allocation_elapsed_ms"
    start_stamp="$submit_start_stamp"
    end_stamp="$submit_end_stamp"
    # 260726 ret begin 区分人工中止与调度或benchmark失败
    if (( interrupted )); then
      task_run_status="interrupted"
    else
      task_run_status="failed"
    fi
    # 260726 ret end
    {
      printf '\n# start_timestamp: %s\n' "$start_stamp"
      printf '# end_timestamp: %s\n' "$end_stamp"
      printf '# submit_end_timestamp: %s\n' "$submit_end_stamp"
      printf '# duration_ms: %s\n' "$elapsed_ms"
      printf '# submit_duration_ms: %s\n' "$submit_elapsed_ms"
      printf '# benchmark_exit_code: %s\n' "$benchmark_code"
      printf '# yhrun_exit_code: %s\n' "$yhrun_code"
      printf '# exit_code: %s\n' "$code"
      # 260726 ret begin 写入本轮实际代码和运行状态
      printf '# runtime_commit: %s\n' "$runtime_commit"
      printf '# run_status: %s\n' "$task_run_status"
      # 260726 ret end
    } >> "$log_path"
    append_index_row "$runid" "$log_path" "$code" "$elapsed_ms" "$submit_elapsed_ms" "$runtime_commit" "$task_run_status" "$task_slurm_job_id" "$task_compute_node"
    series_code="$code"
    break
  fi

  completed_runs=$((completed_runs + 1))
  if [[ -n "$bench_start_epoch" && -n "$bench_end_epoch" ]]; then
    elapsed_ms=$(duration_ms "$bench_start_epoch" "$bench_end_epoch")
  else
    start_stamp="$submit_start_stamp"
    end_stamp="$submit_end_stamp"
    elapsed_ms="$allocation_elapsed_ms"
  fi
  if (( i == 1 )) && [[ -n "$bench_end_epoch" ]]; then
    submit_elapsed_ms=$(duration_ms "$submit_start_epoch" "$bench_end_epoch")
  else
    submit_elapsed_ms="$elapsed_ms"
  fi
  code="$benchmark_code"
  # 260726 ret begin 校验实际运行代码并确定本轮状态
  if [[ "$runtime_commit" != "$selected_commit" ]]; then
    code=86
    task_run_status="commit-mismatch"
    commit_mismatch=1
  elif (( code == 0 )); then
    task_run_status="succeeded"
  else
    task_run_status="failed"
  fi
  # 260726 ret end
  {
    printf '\n# start_timestamp: %s\n' "$start_stamp"
    printf '# end_timestamp: %s\n' "$end_stamp"
    printf '# submit_end_timestamp: %s\n' "$end_stamp"
    printf '# duration_ms: %s\n' "$elapsed_ms"
    printf '# submit_duration_ms: %s\n' "$submit_elapsed_ms"
    printf '# benchmark_exit_code: %s\n' "$benchmark_code"
    printf '# yhrun_exit_code: %s\n' "$yhrun_code"
    printf '# exit_code: %s\n' "$code"
    # 260726 ret begin 写入本轮实际代码和运行状态
    printf '# runtime_commit: %s\n' "$runtime_commit"
    printf '# run_status: %s\n' "$task_run_status"
    # 260726 ret end
  } >> "$log_path"

  append_index_row "$runid" "$log_path" "$code" "$elapsed_ms" "$submit_elapsed_ms" "$runtime_commit" "$task_run_status" "$task_slurm_job_id" "$task_compute_node"
  if (( code != 0 )); then
    series_code="$code"
    break
  fi
done
# 260717 wrqt end 从各轮日志提取时间与退出状态并写入TSV

# 260717 wrqt begin 汇总中断、运行失败和yhrun异常并写入任务索引
if (( interrupted )); then
  append_error_log "$terminate_reason"
  write_task_index
  printf '已写入%s\n' "$index_tsv"
  printf '已写入%s\n' "$error_log"
  exit 130
fi
if (( series_code != 0 )); then
  # 260726 ret begin 区分代码commit不一致与普通运行失败
  if (( commit_mismatch )); then
    append_error_log "代码commit不一致:${current_label}selected=${selected_commit},runtime=${runtime_commit}"
  else
    append_error_log "运行失败:${current_label}exit_code=${series_code}"
  fi
  # 260726 ret end
  write_task_index
  printf '已写入%s\n' "$index_tsv"
  printf '已写入%s\n' "$error_log"
  exit "$series_code"
fi
if (( completed_runs == repeats && yhrun_code != 0 )); then
  printf '# yhrun_warning: yhrun returned nonzero after benchmark success\n' >> "$current_log_path"
  append_error_log "调度层返回非零但benchmark成功:${current_label}yhrun_exit_code=${yhrun_code}"
fi

write_task_index
printf '已写入%s\n' "$index_tsv"
# 260717 wrqt end 汇总中断、运行失败和yhrun异常并写入任务索引
