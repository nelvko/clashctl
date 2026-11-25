[Unit]
Description=placeholder_kernel_desc
After=network.target NetworkManager.service systemd-networkd.service iwd.service

[Service]
Type=simple
LimitNOFILE=1000000
# 默认以 root 运行。若要以普通用户运行，取消下面 User= 的注释；
# AmbientCapabilities 这一行正是为此准备的。
#   User=mihomo
#
# 不要再把 LimitNPROC 加回来。它限制的是该*用户*在全系统的任务总数，
# 配合 User= 时，普通桌面账户轻易超过 1500 个线程，systemd 在 setuid
# 之后 exec 会直接 EAGAIN，报成 status=203/EXEC——而 203/EXEC 的字面
# 含义是「找不到或不可执行」，会把人引向完全无关的方向。
#
# CAP_SYS_TIME（修改系统时钟）与 CAP_SYS_PTRACE（调试任意进程）对代理
# 内核毫无用处，已刻意移除。CAP_DAC_* 保留：服务以 root 运行，但要向
# 可能属于安装用户的 resources 目录写入 cache.db 和日志。
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=placeholder_cmd_full
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
