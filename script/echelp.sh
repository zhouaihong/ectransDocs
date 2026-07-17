#!/usr/bin/env bash
set -euo pipefail

echome_default="/HOME/acict_hpjia/acict_hpjia_1/HDD_POOL/ectrans-dev"
echome="${echome:-${EC_HOME:-$echome_default}}"
echome="${echome%/}"
help_file="$echome/script/echelp.txt"

if [[ -d "$echome" ]]; then
  echome_physical=$(cd "$echome" && pwd -P)
else
  echome_physical="$echome"
fi

if [[ ! -r "$help_file" ]]; then
  printf '找不到echelp.txt: %s\n' "$help_file" >&2
  exit 1
fi

usage() {
  cat <<EOF
用法:
  echelp            按当前目录显示说明
  echelp 路径       显示指定目录说明
  echelp --list     列出已维护目录
  echelp --home     显示当前 echome
  echelp --help     显示本帮助
当前 echome: $echome
说明文件: $help_file
EOF
}

strip_slash() {
  local value="$1"
  while [[ "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

expand_path() {
  local value="$1"
  value="${value//\$\{echome\}/$echome}"
  value="${value//\$echome/$echome}"
  strip_slash "$value"
}

physical_path() {
  local value="$1"
  if [[ -d "$value" ]]; then
    cd "$value" && pwd -P
  else
    strip_slash "$value"
  fi
}

arg_to_path() {
  local value="$1"
  if [[ "$value" == "~" ]]; then
    value="$HOME"
  elif [[ "$value" == ~/* ]]; then
    value="$HOME/${value#~/}"
  elif [[ "$value" != /* ]]; then
    value="$PWD/$value"
  fi
  strip_slash "$value"
}

block_paths() {
  awk '
    /^\[/ {
      section=$0
      gsub(/^\[/,"",section)
      gsub(/\]$/,"",section)
      next
    }
    /^绝对目录=/ {
      value=substr($0,index($0,"=")+1)
      print section "\t" value
    }
  ' "$help_file"
}

print_block() {
  local target="$1"
  awk -v target="$target" -v echome="$echome" '
    function expand(v){
      gsub(/\$\{echome\}/,echome,v)
      gsub(/\$echome/,echome,v)
      return v
    }
    function value(){return substr($0,index($0,"=")+1)}
    /^\[/ {
      section=$0
      gsub(/^\[/,"",section)
      gsub(/\]$/,"",section)
      active=(section==target)
      if(active){
        print "["section"]"
        printed_can=0
        printed_dont=0
        printed_note=0
      }
      next
    }
    active&&/^绝对目录=/ {print "绝对目录: "expand(value());next}
    active&&/^简介=/ {print "简介: "value();next}
    active&&/^可操作=/ {
      if(!printed_can){print "可操作:";printed_can=1}
      print "  - "value()
      next
    }
    active&&/^不可操作=/ {
      if(!printed_dont){print "不可操作:";printed_dont=1}
      print "  - "value()
      next
    }
    active&&/^备注=/ {
      if(!printed_note){print "备注:";printed_note=1}
      print "  - "value()
      next
    }
  ' "$help_file"
}

list_blocks() {
  block_paths | while IFS=$'\t' read -r section raw_path; do
    [[ -n "${section:-}" && -n "${raw_path:-}" ]] || continue
    printf '%-28s %s\n' "[$section]" "$(expand_path "$raw_path")"
  done
}

find_match() {
  local target_logical="$1"
  local target_physical="$2"
  local mode="$3"
  local section raw_path path path_physical best_section= best_path= best_len=0 len
  while IFS=$'\t' read -r section raw_path; do
    [[ -n "${section:-}" && -n "${raw_path:-}" ]] || continue
    path=$(expand_path "$raw_path")
    path_physical=$(physical_path "$path")
    if [[ "$mode" == exact ]]; then
      if [[ "$target_logical" == "$path" || "$target_physical" == "$path_physical" ]]; then
        printf '%s\n' "$section"
        return 0
      fi
    else
      if [[ "$target_logical" == "$path"/* || "$target_physical" == "$path_physical"/* ]]; then
        len=${#path_physical}
        if (( len > best_len )); then
          best_len=$len
          best_section="$section"
          best_path="$path"
        fi
      fi
    fi
  done < <(block_paths)
  if [[ "$mode" == parent && -n "$best_section" ]]; then
    printf '%s\t%s\n' "$best_section" "$best_path"
    return 0
  fi
  return 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --home) printf '%s\n' "$echome"; exit 0 ;;
  --list) list_blocks; exit 0 ;;
  --*) printf 'echelp: 未知参数: %s\n' "$1" >&2; usage; exit 2 ;;
esac

if [[ $# -gt 1 ]]; then
  printf 'echelp: 最多一个目录参数。\n' >&2
  usage >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  target_logical=$(arg_to_path "$1")
else
  target_logical=$(strip_slash "$PWD")
fi
target_physical=$(physical_path "$target_logical")

if section=$(find_match "$target_logical" "$target_physical" exact); then
  print_block "$section"
  exit 0
fi

if record=$(find_match "$target_logical" "$target_physical" parent); then
  parent_section="${record%%$'\t'*}"
  parent_path="${record#*$'\t'}"
  printf '当前目录: %s\n' "$target_logical"
  printf '所属上级: [%s]\n' "$parent_section"
  printf '上级目录: %s\n' "$parent_path"
  printf '提示: 当前下级目录暂无独立说明，可添加或查看上级目录说明。\n'
  exit 0
fi

if [[ "$target_logical" == "$echome" || "$target_logical" == "$echome"/* || "$target_physical" == "$echome_physical" || "$target_physical" == "$echome_physical"/* ]]; then
  printf '当前目录: %s\n' "$target_logical"
  printf '提示: 当前目录位于ectrans-dev内但尚未建立独立说明。\n'
  printf 'echelp --list可以查看已维护目录\n'
  exit 0
fi

printf '当前目录: %s\n' "$target_logical"
printf '提示: 当前目录不在ectrans-dev工作区内。\n'
printf '项目根目录: %s\n' "$echome"
printf '可进入项目根目录后执行echelp。\n'
