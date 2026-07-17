#!/usr/bin/env bash
# begin: 2026-04-19 07:20:29
# type: sh
# effect: 检测与运行
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export EC_HOME="${EC_HOME:-$(cd "$script_dir/.." && pwd)}"

partition="${PARTITION:-h100x}"
nodes="${NODES:-1}"
ntasks="${NTASKS:-1}"
cpus_per_task="${CPUS_PER_TASK:-2}"
gpus="${GPUS:-1}"
profile="${ECTRANS_PROFILE:-gpu-release}"

case "$profile" in
  gpu-release|gpu-debug) ;;
  *)
    echo "不支持的 ECTRANS_PROFILE: $profile" >&2
    echo "支持的取值: gpu-release, gpu-debug" >&2
    exit 2
    ;;
esac

prefix="$EC_HOME/install/ectrans-$profile"
bin="$prefix/bin/ectrans-benchmark-gpu-dp"
env_init="$EC_HOME/env/envInit.sh"

[[ -r "$env_init" ]] || { echo "缺少环境初始化脚本: $env_init" >&2; exit 1; }
[[ -x "$bin" ]] || { echo "缺少可执行文件: $bin" >&2; exit 1; }

export EC_HOME
export ECTRANS_PROFILE="$profile"
export ECTRANS_HOME="$prefix"
export ECTRANS_BIN="$bin"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-$cpus_per_task}"

echo "准备提交GPU测试任务:"
echo "  EC_HOME=$EC_HOME"
echo "  ECTRANS_HOME=$ECTRANS_HOME"
echo "  ECTRANS_BIN=$ECTRANS_BIN"
echo "  分区=$partition 节点数=$nodes 任务数=$ntasks 每任务线程=$cpus_per_task GPU数=$gpus"
if [[ $# -gt 0 ]]; then
  printf '  运行参数='
  printf '%q ' "$@"
  printf '\n'
else
  echo "  运行参数=(使用程序默认参数)"
fi

yhrun -p "$partition" -N "$nodes" -n "$ntasks" -c "$cpus_per_task" -G "$gpus" --pty \
  bash -lc '
    set -euo pipefail

    module purge
    module load nvhpc/24.1-openmpi4 >/dev/null 2>&1
    module load CUDA/12.3 >/dev/null 2>&1 || true

    source "$EC_HOME/env/envInit.sh"

    export ECTRANS_HOME="$EC_HOME/install/ectrans-${ECTRANS_PROFILE}"
    export ECTRANS_BIN="$ECTRANS_HOME/bin/ectrans-benchmark-gpu-dp"
    export PATH="$ECTRANS_HOME/bin:$PATH"

    echo "运行节点=$(hostname)"
    echo "EC_HOME=$EC_HOME"
    echo "ECTRANS_HOME=$ECTRANS_HOME"
    echo "ECTRANS_BIN=$ECTRANS_BIN"
    echo "OMP_NUM_THREADS=$OMP_NUM_THREADS"
    module list 2>&1
    echo "mpirun 路径=$(command -v mpirun)"
    mpirun --version | head -n 3 || true
    ldd "$ECTRANS_BIN" | egrep "libmpi|open-rte|pmix|cufft|cublas|not found" || true
    nvidia-smi -L || true
    mpirun -np 1 "$ECTRANS_BIN" "$@"
  ' bash "$@"
