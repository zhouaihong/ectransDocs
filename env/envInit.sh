#!/usr/bin/bash

# 260130 wrqt begin
    # 需用 . envInit.sh
    # 或用 source envInit.sh
    # 而非 bash envInit.sh
# 260130 wrqt end

export EC_HOME="${EC_HOME:-$HOME/HDD_POOL/ectrans-dev}"
path_prepend() {
  [ -d "$1" ] || return 0
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1${PATH:+:$PATH}" ;;
  esac
}
ld_prepend() {
  [ -d "$1" ] || return 0
  case ":${LD_LIBRARY_PATH-}:" in
    *":$1:"*) ;;
    *) LD_LIBRARY_PATH="$1${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
  esac
}
pkg_prepend() {
  [ -d "$1" ] || return 0
  case ":${PKG_CONFIG_PATH-}:" in
    *":$1:"*) ;;
    *) PKG_CONFIG_PATH="$1${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;;
  esac
}
cmake_prepend() {
  [ -d "$1" ] || return 0
  case ":${CMAKE_PREFIX_PATH-}:" in
    *":$1:"*) ;;
    *) CMAKE_PREFIX_PATH="$1${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}" ;;
  esac
}

# 260201 wrqt cmake3.29
export CMAKE_HOME="${CMAKE_HOME:-$EC_HOME/deps/cmake-3.29.0}"
if [ -x "$CMAKE_HOME/bin/cmake" ]; then
  path_prepend "$CMAKE_HOME/bin"
fi

# 260130 wrqt 我编译的优先级最高，因为自带的也有其他fftw
path_prepend(){ case ":$PATH:" in *":$1:"*) ;; *) PATH="$1${PATH:+:$PATH}";; esac; } 

ld_prepend(){ case ":${LD_LIBRARY_PATH-}:" in *":$1:"*) ;; *) LD_LIBRARY_PATH="$1${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}";; esac; }
pkg_prepend(){ case ":${PKG_CONFIG_PATH-}:" in *":$1:"*) ;; *) PKG_CONFIG_PATH="$1${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}";; esac; }
cmake_prepend(){ case ":${CMAKE_PREFIX_PATH-}:" in *":$1:"*) ;; *) CMAKE_PREFIX_PATH="$1${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}";; esac; }


# export FFTW_FLAVOR="${FFTW_FLAVOR:-fftw-dbl-mpi}" # 260130 wrqt 默认用double precision + mpi 
# # 260130 wrqt 其他三项，可快速选定
# # export FFTW_FLAVOR="${FFTW_FLAVOR:-fftw-dbl-nompi}" # double precision noMPI
# # export FFTW_FLAVOR="${FFTW_FLAVOR:-fftw-f32-mpi}"   # single precision (float) + MPI
# # export FFTW_FLAVOR="${FFTW_FLAVOR:-fftw-f32-nompi}" # single precision (float) + noMPI
# export FFTW_HOME="${FFTW_HOME:-$EC_HOME/deps/$FFTW_FLAVOR}"
# [[ -d "$FFTW_HOME/lib" ]] && ld_prepend "$FFTW_HOME/lib"
# [[ -d "$FFTW_HOME/lib/pkgconfig" ]] && pkg_prepend "$FFTW_HOME/lib/pkgconfig"
# [[ -d "$FFTW_HOME" ]] && cmake_prepend "$FFTW_HOME"

export FFTW_DBL_FLAVOR="${FFTW_DBL_FLAVOR:-fftw-dbl-mpi}"
export FFTW_F32_FLAVOR="${FFTW_F32_FLAVOR:-fftw-f32-mpi}"
export FFTW_DBL_HOME="${FFTW_DBL_HOME:-$EC_HOME/deps/$FFTW_DBL_FLAVOR}"
export FFTW_F32_HOME="${FFTW_F32_HOME:-$EC_HOME/deps/$FFTW_F32_FLAVOR}"
[[ -d "$FFTW_DBL_HOME/lib" ]] && ld_prepend "$FFTW_DBL_HOME/lib"
[[ -d "$FFTW_DBL_HOME/lib/pkgconfig" ]] && pkg_prepend "$FFTW_DBL_HOME/lib/pkgconfig"
[[ -d "$FFTW_DBL_HOME" ]] && cmake_prepend "$FFTW_DBL_HOME"
[[ -d "$FFTW_F32_HOME/lib" ]] && ld_prepend "$FFTW_F32_HOME/lib"
[[ -d "$FFTW_F32_HOME/lib/pkgconfig" ]] && pkg_prepend "$FFTW_F32_HOME/lib/pkgconfig"
[[ -d "$FFTW_F32_HOME" ]] && cmake_prepend "$FFTW_F32_HOME"

export LD_LIBRARY_PATH=/APP/u22/ai_x86/CUDA/12.3/lib64:/APP/u22/ai_x86/CUDA/12.3/targets/x86_64-linux/lib:${LD_LIBRARY_PATH-}

# 260130 wrqt 确保以上变量在后续子进程都得到继承如make mpirun 
# yhrun(yhrun调度器不能洗环境，sbatch就有--export=NONE的选项)

export PATH LD_LIBRARY_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH