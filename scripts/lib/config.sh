#!/usr/bin/env bash

# 从运行配置生成可连接的代理地址，写入调用方的 http_address/socks_address。
# 端口未配置时对应地址为空；读取或解析失败返回 1。不调整端口，也不修改配置。
_proxy_addresses() {
  http_address='' socks_address=''
  local values mixed_port http_port socks_port bind_addr allow_lan host port auth_base64 auth='' auth_prefix=''
  values=$("$BIN_YQ" -er 'select(tag == "!!map") |
    [.mixed-port // 0, .port // 0, .socks-port // 0,
     .bind-address // "*", .allow-lan // false,
     (.authentication[0] // "" | @base64)] | @tsv' "$CLASH_CONFIG_RUNTIME" 2>/dev/null) || return 1
  # 非空白分隔符保留空字段；认证字段用 base64 避免换行、制表符干扰拆分。
  values=${values//$'\t'/$'\x1f'}
  IFS=$'\x1f' read -r mixed_port http_port socks_port bind_addr allow_lan auth_base64 <<<"$values"
  if [ -n "$auth_base64" ]; then
    auth=$(printf '%s' "$auth_base64" | base64 --decode 2>/dev/null && printf '.') || return 1
    auth=${auth%.}
    case $auth in
    '') ;;
    *:*) auth_prefix="$(_urlencode "${auth%%:*}"):$(_urlencode "${auth#*:}")@" ;;
    *) auth_prefix="$(_urlencode "$auth")@" ;;
    esac
  fi
  case $allow_lan in
  false) host=127.0.0.1 ;;
  true) host=$(_connect_host "$bind_addr") || return 1 ;;
  *) return 1 ;;
  esac
  if port=$(_connect_port "$http_port" "$mixed_port"); then
    http_address="http://${auth_prefix}${host}:${port}"
  fi
  if port=$(_connect_port "$socks_port" "$mixed_port"); then
    socks_address="socks5h://${auth_prefix}${host}:${port}"
  fi
  return 0
}

# 监听地址转为可连接的主机：通配地址改用本机回环，IPv6 加方括号。
_connect_host() {
  local host=$1
  case $host in
  '' | '*' | 0.0.0.0) host=127.0.0.1 ;;
  :: | '[::]') host='::1' ;;
  esac
  host=${host#\[}
  host=${host%\]}
  # 拒绝控制字符及 URL 中的凭据、路径，避免破坏终端布局。
  case $host in '' | *[!a-zA-Z0-9.:%_-]*) return 1 ;; esac
  case $host in *:*) host="[${host//%/%25}]" ;; esac
  printf '%s\n' "$host"
}

# 输出第一个有效端口；0 表示未配置，此时改用第二个参数。
_connect_port() {
  local port=${1:-0}
  [ "$port" != 0 ] || port=${2:-0}
  [[ $port =~ ^[0-9]+$ ]] && [ "${#port}" -le 5 ] || return 1
  ((10#$port > 0 && 10#$port <= 65535)) || return 1
  printf '%d\n' "$((10#$port))"
}

_detect_proxy_port() {
  local mixed_port http_port socks_port
  IFS='|' read -r mixed_port http_port socks_port < <(
    "$BIN_YQ" '[.mixed-port // "", .port // "", .socks-port // ""] | join("|")' "$CLASH_CONFIG_RUNTIME"
  )

  [ -z "$mixed_port" ] && [ -z "$http_port" ] && [ -z "$socks_port" ] && mixed_port=7890

  local count=0
  local service_active=false
  service_is_active >&/dev/null && service_active=true

  local entries=(
    "mixed-port:$mixed_port"
    "port:$http_port"
    "socks-port:$socks_port"
  )

  local entry yaml_key port new_port
  for entry in "${entries[@]}"; do
    yaml_key=${entry%%:*}
    port=${entry#*:}
    [ -n "$port" ] && [ "$service_active" != true ] || continue
    new_port=$(_replacement_port "$yaml_key" "$port") || { [ $? -eq 1 ] && continue; return 1; }
    count=$((count + 1))
    "$BIN_YQ" -i ".${yaml_key} = $new_port" "$CLASH_CONFIG_MIXIN"
  done

  if [ "$count" -gt 0 ] && ! _merge_config; then
    _errorcat '代理端口已调整，但运行配置更新失败'
    return 1
  fi
  return 0
}

_detect_ext_addr() {
  local ext_addr new_port
  ext_addr=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME")

  local ext_ip=${ext_addr%%:*}
  EXT_IP=$ext_ip
  EXT_PORT=${ext_addr##*:}
  [ "$ext_ip" = '0.0.0.0' ] && EXT_IP=$(_get_local_ip)

  # 服务运行时端口由它自己占用，不需要换。
  service_is_active >&/dev/null && return 0
  new_port=$(_replacement_port external-controller "$EXT_PORT") || { [ $? -eq 1 ] && return 0; return 1; }
  EXT_PORT=$new_port
  EXT_ADDR="$ext_ip:$new_port" "$BIN_YQ" -i '.external-controller = env(EXT_ADDR)' "$CLASH_CONFIG_MIXIN"
  _merge_config
}

_get_secret() {
  "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME"
}

_valid_config() {
  local config="$1"
  [[ ! -e "$config" || "$(wc -l <"$config")" -lt 1 ]] && return 1

  local test_log
  # 校验须与服务同工作目录（resources/ 内含随仓库分发的 geodata）：
  # 配置已迁到 data/，若用 -d "$(dirname config)" 内核会在校验期现下载 geodata。
  test_log=$("$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$config" -t 2>&1) || {
    printf '%s\n' "$test_log" >&2
    grep -qs "unsupport proxy type" <<<"$test_log" && {
      _errorcat "检测到订阅中包含不受支持的代理协议, 请检查并升级内核版本"
    }
    return 1
  }
}

# 主配置与订阅使用相同的节点结构约束：解析失败也必须拒绝。
_has_proxy_nodes() {
  [ -s "$1" ] && "$BIN_YQ" -e '
      ((.proxies | type) == "!!seq" and (.proxies | length) > 0) or
      ((.proxy-providers | type) == "!!map" and (.proxy-providers | length) > 0)
    ' "$1" >/dev/null 2>&1
}

# 未选择订阅时允许直连启动；已选订阅缺失或损坏仍须报错。
_require_base_config() {
  if [ ! -s "$CLASH_CONFIG_BASE" ]; then
    local selected=''
    if [ -e "$CLASH_PROFILES_META" ]; then
      selected=$("$BIN_YQ" -e '
        select(type == "!!map") |
        select(.use == null or (.use | type) == "!!str") |
        .use // ""
      ' "$CLASH_PROFILES_META" 2>/dev/null) || {
        _ui_error '订阅记录无效，无法启动内核'
        _ui_detail '配置文件' "$CLASH_PROFILES_META"
        return 1
      }
    fi
    if [ -n "$selected" ]; then
      _ui_error '已选订阅的主配置缺失或为空，无法启动内核'
      _ui_detail '配置文件' "$CLASH_CONFIG_BASE"
      return 1
    fi
    return 0
  fi
  if ! _has_proxy_nodes "$CLASH_CONFIG_BASE"; then
    _ui_error '主配置无效或缺少代理节点，无法启动内核'
    _ui_detail '配置文件' "$CLASH_CONFIG_BASE"
    return 1
  fi
  local validation_log
  if validation_log=$(_valid_config "$CLASH_CONFIG_BASE" 2>&1); then
    return 0
  fi
  _ui_error '主配置校验失败，无法启动内核'
  _ui_detail '配置文件' "$CLASH_CONFIG_BASE"
  [ -z "$validation_log" ] || printf '%s\n' "$validation_log" >&2
  return 1
}

_merge_config() {
  _require_base_config || return 1
  local candidate rc=0
  candidate=$(mktemp "${CLASH_CONFIG_RUNTIME}.XXXXXX") || return 1
  if [ -s "$CLASH_CONFIG_BASE" ]; then
    _build_runtime_config "$CLASH_CONFIG_BASE" >"$candidate" || rc=$?
  else
    # 仅作为合并输入，不写入订阅配置；Mixin 可覆盖默认直连模式。
    _build_runtime_config <(printf 'mode: direct\n') >"$candidate" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    command rm -f -- "$candidate"
    _errorcat '配置合并失败：请检查主配置与 Mixin'
    return 1
  fi
  if ! _valid_config "$candidate"; then
    command rm -f -- "$candidate"
    _errorcat '验证失败：请检查 Mixin 配置'
    return 1
  fi
  if ! command mv -f -- "$candidate" "$CLASH_CONFIG_RUNTIME"; then
    command rm -f -- "$candidate"
    return 1
  fi
}

_build_runtime_config() {
  # shellcheck disable=SC2016
  "$BIN_YQ" eval-all '
      ########################################
      #              Load Files              #
      ########################################
      select(fileIndex==0) as $config |
      select(fileIndex==1) as $mixin |

      ########################################
      #              Deep Merge              #
      ########################################
      $mixin |= del(._custom) |
      (($config // {}) * $mixin) as $runtime |
      $runtime |

      ########################################
      #        Tun DNS fallback              #
      ########################################
      # DNS 默认不接管，仅在 Tun 开启且无任何 dns 配置时补
      # 最小骨架，避免 dns-hijack 劫持的查询收到 SERVFAIL。
      (((.tun.enable // false) == true)) as $tunOn |
      (select($tunOn and ((.dns // {}) | keys | length) == 0) | .dns = {
        "enable": true,
        "listen": "0.0.0.0:1053",
        "enhanced-mode": "fake-ip",
        "nameserver": ["114.114.114.114", "8.8.8.8"]
      }) // . |

      ########################################
      #               Rules                  #
      ########################################
      .rules = (
        ($mixin.rules.prepend // []) +
        ($config.rules // []) +
        ($mixin.rules.append // [])
      ) |

      ########################################
      #                Proxies               #
      ########################################
      .proxies = (
        ($mixin.proxies.prepend // []) +
        (
          ($config.proxies // []) as $configList |
          ($mixin.proxies.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxies.append // [])
      ) |

      ########################################
      #             ProxyGroups              #
      ########################################
      .proxy-groups = (
        ($mixin.proxy-groups.prepend // []) +
        (
          ($config.proxy-groups // []) as $configList |
          ($mixin.proxy-groups.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxy-groups.append // [])
      ) |

      ########################################
      #         ProxyGroups Inject           #
      ########################################
      ($mixin.proxy-groups.inject // {}) as $inj |
      .proxy-groups[] |= (
        . as $g |
        ($inj | .[$g.name] // []) as $extra |
        .proxies = (.proxies + $extra | unique)
      )
    ' "$1" "$CLASH_CONFIG_MIXIN"
}
tunstatus() {
  _tun_is_active && {
    printf 'Tun 状态：启用\n'
    return 0
  }
  printf 'Tun 状态：关闭\n' >&2
  return 1
}
_is_tun_enabled() {
  "$BIN_YQ" -e '.tun.enable == true' "$CLASH_CONFIG_RUNTIME" >&/dev/null
}
_merge_config_restart() {
  local was_tun_active=false

  tunstatus >&/dev/null && was_tun_active=true
  # rc=1：合并/校验失败，runtime 保持旧配置。
  _merge_config || return 1

  if [ "${was_tun_active}" = true ]; then
    service_sudo_stop >/dev/null || return 2
    service_is_active >&/dev/null && {
      _errorcat "请先关闭 Tun 模式"
      return 2
    }
  else
    service_stop >&/dev/null || return 2
  fi

  sleep 0.1

  # rc=2：合并成功（runtime 已是新配置）但服务重启失败
  if _is_tun_enabled; then
    service_sudo_start >/dev/null || return 2
    sleep 1
    tunstatus >&/dev/null || {
      _errorcat "Tun 模式重启失败，请检查代理内核日志"
      return 2
    }
  else
    service_start >/dev/null || return 2
  fi
}
