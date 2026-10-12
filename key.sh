#!/usr/bin/env bash
#=============================================================
# SSH Security Installer (key.sh)
# Multi-distro: Debian/Ubuntu, RHEL/CentOS/Fedora/Rocky/Alma,
#               Alpine, Arch/Manjaro, openSUSE
#=============================================================


RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; PURPLE="\033[35m"; CYAN="\033[36m"
GRAY="\033[90m"; BOLD="\033[1m"; RESET="\033[0m"

INFO="${GREEN}[INFO]${RESET}"; WARN="${YELLOW}[WARN]${RESET}"; ERROR="${RED}[ERROR]${RESET}"

JAIL_CONF="/etc/fail2ban/jail.local"
LOG_FILE="/var/log/fail2ban.log"
TARGET_JAIL="sshd"

SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_CONF_DIR="/etc/ssh/sshd_config.d"
SSHD_CUSTOM="${SSHD_CONF_DIR}/00-key.sh.conf"
SSHD_LEGACY="${SSHD_CONF_DIR}/99-key.sh.conf"

[ "$EUID" -ne 0 ] && SUDO="sudo" || SUDO=""

PKG_MGR=""; INIT_SYS=""; SSH_LOG=""; OS_NAME=""; OS_ID=""; OS_VER=""; OS_SHORT=""

# ============ 命令列幫助 ============
case "${1:-}" in
    -h|--help)
        cat <<HELP
SSH Security Installer

用法:
  $0 [選項]

互動模式:
  直接執行 $0 進入互動式選單

命令列模式:
  -g <使用者>    從 GitHub 拉取公鑰
  -u <URL>       從自訂 URL 拉取公鑰
  -f <檔案>      從本地檔案匯入公鑰
  -p <連接埠>    修改 SSH 連接埠
  -d             禁用密碼登入
  -o             覆蓋模式（清空已存公鑰）

其他:
  -h, --help     顯示幫助
HELP
        exit 0 ;;
esac

# ============ 能力偵測 ============
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="${NAME:-Unknown}"; OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-}"
    else
        OS_NAME=$(uname -s); OS_VER=$(uname -r); OS_ID="unknown"
    fi
    case "$OS_ID" in
        debian) OS_SHORT="Debian" ;;
        ubuntu) OS_SHORT="Ubuntu" ;;
        linuxmint) OS_SHORT="Linux Mint" ;;
        kali) OS_SHORT="Kali" ;;
        rhel) OS_SHORT="RHEL" ;;
        centos) OS_SHORT="CentOS" ;;
        fedora) OS_SHORT="Fedora" ;;
        rocky) OS_SHORT="Rocky" ;;
        almalinux) OS_SHORT="AlmaLinux" ;;
        ol) OS_SHORT="Oracle Linux" ;;
        amzn) OS_SHORT="Amazon Linux" ;;
        alpine) OS_SHORT="Alpine" ;;
        arch) OS_SHORT="Arch" ;;
        manjaro) OS_SHORT="Manjaro" ;;
        endeavouros) OS_SHORT="EndeavourOS" ;;
        opensuse*) OS_SHORT="openSUSE" ;;
        sles) OS_SHORT="SLES" ;;
        *)
            local first="${OS_ID:0:1}"
            OS_SHORT="$(echo "$first" | tr '[:lower:]' '[:upper:]')${OS_ID:1}"
            ;;
    esac
}

detect_pkg_mgr() {
    for pm in apt dnf yum zypper pacman apk; do
        command -v "$pm" &>/dev/null && { PKG_MGR="$pm"; return; }
    done
    PKG_MGR="unknown"
}

detect_init() {
    if [ -d /run/systemd/system ]; then INIT_SYS="systemd"
    elif [ -d /run/openrc ]; then INIT_SYS="openrc"
    elif [ -x /sbin/init ]; then INIT_SYS="sysvinit"
    else INIT_SYS="unknown"; fi
}

detect_ssh_log() {
    case "$OS_ID" in
        debian|ubuntu|linuxmint|kali) SSH_LOG="/var/log/auth.log" ;;
        rhel|centos|fedora|rocky|almalinux|ol|amzn) SSH_LOG="/var/log/secure" ;;
        alpine) SSH_LOG="/var/log/messages" ;;
        arch|manjaro|endeavouros) SSH_LOG="/var/log/auth.log" ;;
        opensuse*|sles) SSH_LOG="/var/log/messages" ;;
        *) SSH_LOG="/var/log/auth.log" ;;
    esac
}

# ============ 服務管理抽象 ============
svc_start()  { case "$INIT_SYS" in systemd) $SUDO systemctl start "$1" 2>/dev/null;; openrc) $SUDO rc-service "$1" start 2>/dev/null;; sysvinit) $SUDO service "$1" start 2>/dev/null;; esac; }
svc_stop()   { case "$INIT_SYS" in systemd) $SUDO systemctl stop "$1" 2>/dev/null;; openrc) $SUDO rc-service "$1" stop 2>/dev/null;; sysvinit) $SUDO service "$1" stop 2>/dev/null;; esac; }
svc_restart(){ case "$INIT_SYS" in systemd) $SUDO systemctl restart "$1" 2>/dev/null;; openrc) $SUDO rc-service "$1" restart 2>/dev/null;; sysvinit) $SUDO service "$1" restart 2>/dev/null;; esac; }
svc_enable() { case "$INIT_SYS" in systemd) $SUDO systemctl enable "$1" 2>/dev/null;; openrc) $SUDO rc-update add "$1" default 2>/dev/null;; sysvinit) $SUDO update-rc.d "$1" defaults 2>/dev/null || chkconfig "$1" on 2>/dev/null;; esac; }
svc_disable(){ case "$INIT_SYS" in systemd) $SUDO systemctl disable "$1" 2>/dev/null;; openrc) $SUDO rc-update del "$1" default 2>/dev/null;; sysvinit) $SUDO update-rc.d -f "$1" remove 2>/dev/null || chkconfig "$1" off 2>/dev/null;; esac; }

# ============ 包管理抽象 ============
pkg_install() {
    case "$PKG_MGR" in
        apt) $SUDO apt-get update -qq && $SUDO apt-get install -y "$@" ;;
        dnf) $SUDO dnf install -y "$@" ;;
        yum) $SUDO yum install -y "$@" ;;
        zypper) $SUDO zypper --non-interactive install "$@" ;;
        pacman) $SUDO pacman -Sy --noconfirm "$@" ;;
        apk) $SUDO apk add --no-cache "$@" ;;
        *) echo -e "${ERROR} 未知套件管理器"; return 1 ;;
    esac
}
pkg_remove() {
    case "$PKG_MGR" in
        apt) $SUDO apt-get remove --purge -y "$@"; $SUDO apt-get autoremove -y ;;
        dnf) $SUDO dnf remove -y "$@" ;;
        yum) $SUDO yum remove -y "$@" ;;
        zypper) $SUDO zypper --non-interactive remove "$@" ;;
        pacman) $SUDO pacman -R --noconfirm "$@" ;;
        apk) $SUDO apk del "$@" ;;
        *) return 1 ;;
    esac
}
# 重新安裝包，用於修復殘缺安裝（如 /etc/fail2ban 被誤刪）
pkg_reinstall() {
    case "$PKG_MGR" in
        apt) $SUDO apt-get install --reinstall -y "$@" ;;
        dnf) $SUDO dnf reinstall -y "$@" ;;
        yum) $SUDO yum reinstall -y "$@" ;;
        zypper) $SUDO zypper --non-interactive install --force-resolution "$@" ;;
        pacman) $SUDO pacman -S --noconfirm "$@" ;;
        apk) $SUDO apk add --no-cache "$@" ;;
        *) return 1 ;;
    esac
}

# 偵測 EOL 系統（僅用於提示，不自動修改配置）
check_eol_system() {
    case "$OS_ID" in
        debian)
            case "$OS_VER" in
                8|9|10|11)
                    echo -e "\n${YELLOW}${BOLD}[提示] 偵測到 Debian ${OS_VER}，該系統已停止官方支援。${RESET}"
                    echo -e "${YELLOW}apt 源可能已失效，導致無法正常安裝軟體。${RESET}"
                    echo -e "${YELLOW}如果安裝失敗，可將 /etc/apt/sources.list 改為 archive 源：${RESET}\n"
                    local codename=""
                    case "$OS_VER" in
                        8) codename="jessie" ;;
                        9) codename="stretch" ;;
                        10) codename="buster" ;;
                        11) codename="bullseye" ;;
                    esac
                    if [ -n "$codename" ]; then
                        echo -e "${CYAN}示例：${RESET}"
                        echo -e "  deb http://archive.debian.org/debian ${codename} main contrib non-free"
                        echo -e "  deb http://archive.debian.org/debian ${codename}-updates main contrib non-free"
                        echo -e "\n${CYAN}修改後執行：sudo apt update${RESET}"
                    fi
                    echo ""
                    ;;
            esac
            ;;
        ubuntu)
            case "$OS_VER" in
                14.04|16.04|18.04|20.04|21.04|21.10|22.10)
                    echo -e "\n${YELLOW}${BOLD}[提示] 偵測到 Ubuntu ${OS_VER}，該系統已停止官方支援。${RESET}"
                    echo -e "${YELLOW}apt 源可能已失效，建議升級到 LTS 版本。${RESET}\n"
                    ;;
            esac
            ;;
    esac
}

# ============ SSH 配置管理 ============
# 讀取順序：優先讀 00-key.sh.conf（我們寫入的地方）→ 主檔案 → 其他 .d 檔案
# 與 OpenSSH "First Match Wins" 生效順序一致
get_sshd_config_val() {
    local key="$1" default_val="$2"
    local val=""

    # 1. 優先讀取我們寫入的 00-key.sh.conf
    if [ -f "$SSHD_CUSTOM" ]; then
        val=$(grep -iE "^[[:space:]]*${key}[[:space:]=]+" "$SSHD_CUSTOM" | tail -n 1 | \
              sed -E 's/^[[:space:]]*[^[:space:]=]+[[:space:]=]+//' | awk '{print $1}')
    fi

    # 2. 主檔案
    if [ -z "$val" ] && [ -f "$SSHD_MAIN" ]; then
        val=$(grep -iE "^[[:space:]]*${key}[[:space:]=]+" "$SSHD_MAIN" | tail -n 1 | \
              sed -E 's/^[[:space:]]*[^[:space:]=]+[[:space:]=]+//' | awk '{print $1}')
    fi

    # 3. 其他 .d 檔案
    if [ -z "$val" ] && [ -d "$SSHD_CONF_DIR" ]; then
        for conf in "${SSHD_CONF_DIR}"/*.conf; do
            [ -f "$conf" ] || continue
            [ "$conf" = "$SSHD_CUSTOM" ] && continue
            val=$(grep -iE "^[[:space:]]*${key}[[:space:]=]+" "$conf" | tail -n 1 | \
                  sed -E 's/^[[:space:]]*[^[:space:]=]+[[:space:]=]+//' | awk '{print $1}')
            [ -n "$val" ] && break
        done
    fi

    [ -n "$val" ] && { echo "$val"; return; }
    echo "$default_val"
}

# 寫入 SSH 配置
# 優先寫入 00-key.sh.conf（字典序最靠前 = 最高優先順序 + 避開 Match 塊陷阱）
# 無 sshd_config.d 目錄時才寫主檔案
set_sshd_config() {
    local param="$1" value="$2"

    if [ -d "$SSHD_CONF_DIR" ]; then
        # 0. 清理舊版遺留的 99-key.sh.conf（防重複）
        if [ -f "$SSHD_LEGACY" ]; then
            $SUDO rm -f "$SSHD_LEGACY"
        fi
        # 1. 註解主檔案中的同參數項（防禦 Include 在檔案末尾的邊界情況）
        if [ -f "$SSHD_MAIN" ]; then
            $SUDO sed -i -E "s/^[[:space:]]*#?[[:space:]]*(${param})[[:space:]=].*/# \1 (disabled by key.sh)/" "$SSHD_MAIN"
        fi
        # 2. 註解其他 .conf 中的同參數項，避免 First Match Wins 衝突
        for conf in "${SSHD_CONF_DIR}"/*.conf; do
            [ -f "$conf" ] || continue
            [ "$conf" = "$SSHD_CUSTOM" ] && continue
            $SUDO sed -i -E "s/^[[:space:]]*#?[[:space:]]*(${param})[[:space:]=].*/# \1 (disabled by key.sh)/" "$conf"
        done
        # 3. 確保自訂檔案存在
        [ ! -f "$SSHD_CUSTOM" ] && echo "${param} ${value}" | $SUDO tee "$SSHD_CUSTOM" > /dev/null
        # 4. 刪除自訂檔案中的舊值，寫入新值
        $SUDO sed -i -E "/^[[:space:]]*#?[[:space:]]*(${param})[[:space:]=]/d" "$SSHD_CUSTOM"
        echo "${param} ${value}" | $SUDO tee -a "$SSHD_CUSTOM" > /dev/null
    else
        # 傳統主檔案模式（無 sshd_config.d 目錄的老系統）
        $SUDO sed -i -E "/^[[:space:]]*#?[[:space:]]*(${param})[[:space:]=]/d" "$SSHD_MAIN"
        if grep -q -iE "^[[:space:]]*Match[[:space:]]+" "$SSHD_MAIN"; then
            # 存在 Match 塊，插入到第一個 Match 之前（大小寫不敏感）
            local tmpf; tmpf=$(mktemp)
            awk -v p="${param}" -v v="${value}" '
                BEGIN { inserted=0 }
                tolower($0) ~ /^[[:space:]]*match[[:space:]]/ && !inserted {
                    print p " " v
                    inserted=1
                }
                { print }
            ' "$SSHD_MAIN" > "$tmpf"
            $SUDO cp "$tmpf" "$SSHD_MAIN"
            rm -f "$tmpf"
        else
            echo "${param} ${value}" | $SUDO tee -a "$SSHD_MAIN" > /dev/null
        fi
    fi
}

restart_sshd() {
    echo -e "${INFO} 正在偵測 SSH 配置檔案語法..."
    if command -v sshd &>/dev/null; then
        if ! $SUDO sshd -t; then
            echo -e "${ERROR} SSH 配置檔案測試失敗！偵測到語法錯誤，已取消重啟以防止斷連鎖死！"
            return 1
        fi
    fi

    echo -e "${INFO} 正在重啟 SSH 服務..."
    local restart_ok=1
    if [ "$INIT_SYS" = "systemd" ]; then
        if systemctl list-unit-files 2>/dev/null | grep -q "ssh.socket"; then
            echo -e "${INFO} 偵測到 systemd ssh.socket，正在強制關閉並遮蔽 (mask)..."
            $SUDO systemctl stop ssh.socket &>/dev/null
            $SUDO systemctl disable ssh.socket &>/dev/null
            $SUDO systemctl mask ssh.socket &>/dev/null
        fi
        $SUDO systemctl daemon-reload &>/dev/null
        local ssh_unit=""
        if systemctl list-unit-files 2>/dev/null | grep -q "^ssh.service"; then
            ssh_unit="ssh"
        elif systemctl list-unit-files 2>/dev/null | grep -q "^sshd.service"; then
            ssh_unit="sshd"
        fi
        if [ -n "$ssh_unit" ]; then
            # 防禦性 unmask：避免上層曾 mask 過 ssh.service 導致 enable 靜默失敗
            $SUDO systemctl unmask "${ssh_unit}.service" &>/dev/null || true
            svc_enable "$ssh_unit"
            svc_restart "$ssh_unit" && restart_ok=0
        else
            echo -e "${ERROR} 未找到 ssh.service 或 sshd.service！"
        fi
    elif [ "$INIT_SYS" = "openrc" ]; then
        svc_restart sshd && restart_ok=0
    else
        svc_restart sshd 2>/dev/null && restart_ok=0
        if [ "$restart_ok" -ne 0 ]; then
            svc_restart ssh 2>/dev/null && restart_ok=0
        fi
    fi

    if [ "$restart_ok" -eq 0 ]; then
        echo -e "${INFO} ${GREEN}SSH 服務重啟成功！${RESET}"
        return 0
    else
        echo -e "${ERROR} SSH 服務重啟失敗，請檢查配置檔案！"
        return 1
    fi
}

# ============ 依賴安裝 ============
check_dependencies() {
    local pkgs=()
    for dep in curl ssh-keygen awk; do
        command -v "$dep" &>/dev/null && continue
        case "$dep" in
            curl) pkgs+=("curl") ;;
            ssh-keygen) case "$PKG_MGR" in apt) pkgs+=("openssh-client");; dnf|yum) pkgs+=("openssh-clients");; apk) pkgs+=("openssh-client");; pacman) pkgs+=("openssh");; zypper) pkgs+=("openssh");; esac ;;
            awk) command -v gawk &>/dev/null && continue; pkgs+=("gawk") ;;
        esac
    done
    [ ${#pkgs[@]} -gt 0 ] && { echo -e "${WARN} 正在安裝依賴: ${pkgs[*]}"; pkg_install "${pkgs[@]}"; }
}

init_ssh_dir() {
    mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
    touch "${HOME}/.ssh/authorized_keys"; chmod 600 "${HOME}/.ssh/authorized_keys"
}

# 追加公鑰
# - 保留選項字首（如 from="1.2.3.4",command="..."）
# - 丟棄尾部註解（避免汙染後設資料標籤）
# - 用 base64 主體做去重
append_key_with_meta() {
    local pub_content="$1" source_tag="$2" auth_file="${HOME}/.ssh/authorized_keys"
    local ts; ts=$(date "+%Y-%m-%d %H:%M:%S")
    init_ssh_dir
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        line=$(echo "$line" | sed -e 's/[[:space:]]*$//')

        # 從 ssh-/ecdsa-/sk- 開始，保留「金鑰類型 + Base64 主體」兩列，丟棄尾部註解
        # 保留此前的 option 字首（如果有），以便 from=/command= 等限制不丟失
        local core_key
        core_key=$(echo "$line" | awk '{
            for(i=1;i<=NF;i++){
                if($i ~ /^(ssh-|ecdsa-|sk-)/){
                    for(j=1;j<=i+1 && j<=NF;j++) printf "%s%s", $j, (j<i+1?" ":"")
                    print ""
                    exit
                }
            }
        }')
        [ -z "$core_key" ] && continue

        # 用 base64 主體做去重
        local key_base64
        key_base64=$(echo "$core_key" | awk '{print $NF}')

        if grep -qF "$key_base64" "$auth_file" 2>/dev/null; then
            echo -e "${WARN} 該公鑰已經存在於 authorized_keys 中，已跳過重複追加。"
            continue
        fi

        echo "${core_key} [${ts}|${source_tag}]" >> "$auth_file"
        echo -e "${INFO} ${GREEN}已成功追加公鑰 (${source_tag})${RESET}"
    done <<< "$pub_content"
    chmod 600 "$auth_file"
}

# 統計 authorized_keys 中有效公鑰數量
count_authorized_keys() {
    local auth_file="${HOME}/.ssh/authorized_keys"
    if [ -f "$auth_file" ]; then
        awk '!/^[[:space:]]*(#|$)/{c++} END{print c+0}' "$auth_file"
    else
        echo "0"
    fi
}

# 判斷 authorized_keys 是否有有效公鑰（支援帶 option 字首 + sk- 硬體金鑰）
has_valid_pubkey() {
    local auth_file="${HOME}/.ssh/authorized_keys"
    [ -f "$auth_file" ] || return 1
    grep -qE '(^|[[:space:]])(ssh-|ecdsa-|sk-)' "$auth_file" 2>/dev/null
}

# ============ Fail2Ban ============
# 參數讀取：優先讀 [sshd] 段 → 讀不到再讀 [DEFAULT] 段
# 遞增參數（bantime.increment/factor/maxtime）只應在 [DEFAULT] 段生效
get_f2b_conf() {
    local key=$1
    [ -f "$JAIL_CONF" ] || return
    # 1. 先讀 [sshd] 段
    local result
    result=$(awk -v t="$TARGET_JAIL" -v k="$key" '
        BEGIN { in_block=0; result="" }
        $0 ~ "^\\[" t "\\][[:space:]]*$" { in_block=1; next }
        /^[[:space:]]*\[/ { in_block=0 }
        in_block && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            value=$0
            sub(/^[[:space:]]*[^=]+=[[:space:]]*/, "", value)
            sub(/[[:space:]]+$/, "", value)
            result = value
        }
        END { if (result != "") print result }
    ' "$JAIL_CONF")
    # 2. [sshd] 段沒有 → 從 [DEFAULT] 段取
    if [ -z "$result" ]; then
        result=$(awk -v k="$key" '
            BEGIN { in_block=0; result="" }
            /^\[DEFAULT\][[:space:]]*$/ { in_block=1; next }
            /^[[:space:]]*\[/ { in_block=0 }
            in_block && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
                value=$0
                sub(/^[[:space:]]*[^=]+=[[:space:]]*/, "", value)
                sub(/[[:space:]]+$/, "", value)
                result = value
            }
            END { if (result != "") print result }
        ' "$JAIL_CONF")
    fi
    echo "$result"
}

# 參數寫入：
# - bantime.increment / bantime.factor / bantime.maxtime / dbfile / dbpurgeage 屬於 [DEFAULT] 段
# - 其餘參數寫入 [sshd] 段
set_f2b_conf() {
    local key=$1 val=$2
    local target_section="$TARGET_JAIL"
    case "$key" in
        bantime.increment|bantime.factor|bantime.maxtime|dbfile|dbpurgeage)
            target_section="DEFAULT"
            ;;
    esac

    if [ ! -f "$JAIL_CONF" ]; then
        {
            echo "[DEFAULT]"
            echo "[$TARGET_JAIL]"
        } | $SUDO tee "$JAIL_CONF" > /dev/null
    fi
    # 確保目標段存在
    if ! grep -q "^\[${target_section}\]" "$JAIL_CONF"; then
        echo "" | $SUDO tee -a "$JAIL_CONF" > /dev/null
        echo "[${target_section}]" | $SUDO tee -a "$JAIL_CONF" > /dev/null
    fi

    # 判斷該 key 是否已存在於目標段
    local exists
    exists=$(awk -v t="$target_section" -v k="$key" '
        BEGIN { in_block=0; found=0 }
        $0 ~ "^\\[" t "\\][[:space:]]*$" { in_block=1; next }
        /^[[:space:]]*\[/ { in_block=0 }
        in_block && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { found=1 }
        END { print found }
    ' "$JAIL_CONF")

    if [ "$exists" = "1" ]; then
        # 精確替換目標段內該 key 的值
        local tmpf; tmpf=$(mktemp)
        awk -v t="$target_section" -v k="$key" -v v="$val" '
            BEGIN { in_block=0; done=0 }
            $0 ~ "^\\[" t "\\][[:space:]]*$" { in_block=1; print; next }
            /^[[:space:]]*\[/ { in_block=0 }
            in_block && !done && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
                print k " = " v
                done=1
                next
            }
            { print }
        ' "$JAIL_CONF" > "$tmpf"
        $SUDO cp "$tmpf" "$JAIL_CONF"
        rm -f "$tmpf"
    else
        # 追加到目標段頭下方
        $SUDO sed -i "/^\[${target_section}\]/a ${key} = ${val}" "$JAIL_CONF"
    fi
}

restart_f2b() {
    echo -e "${INFO} 正在重新載入 Fail2Ban 配置..."
    svc_restart fail2ban
    for i in {1..5}; do
        if fail2ban-client ping >/dev/null 2>&1; then
            echo -e "${INFO} ${GREEN}成功！配置已生效。${RESET}"; return 0
        fi; sleep 1
    done
    echo -e "${ERROR} Fail2Ban 重啟超時或失敗。"
    echo -e "${YELLOW}請手動執行 'journalctl -u fail2ban -n 50' 排查錯誤。${RESET}"
}

get_fail2ban_status() {
    # 清命令快取，否則 bash 會記住已被解除安裝的舊路徑，
    # 導致 apt remove 後 command -v 仍返回舊路徑、狀態顯示"已安裝"。
    hash -r 2>/dev/null
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
        local count
        count=$(fail2ban-client status "$TARGET_JAIL" 2>/dev/null | grep -i "Currently banned" | awk '{print $NF}')
        echo -e "${GREEN}防護中 (已封禁${count:-0} IP)${RESET}"
    elif command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${YELLOW}已安裝 / 已停止${RESET}"
    else
        echo -e "${YELLOW}未安裝${RESET}"
    fi
}

fmt_f2b_unit() {
    local val=$1 type=$2
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        [ "$type" == "time" ] && echo "${val}秒" || { [ "$type" == "factor" ] && echo "${val}倍" || echo "$val"; }
    else echo "$val"; fi
}

validate_time() { [[ "$1" =~ ^[0-9]+[smhdw]?$ ]]; }
validate_int() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

# systemd 環境預設走 journal，不寫死 logpath（避免 WARN）
# port 動態讀取目前 SSH 連接埠，避免裝 F2B 前已改連接埠時防護失效
# 遞增參數 + 資料庫配置寫入 [DEFAULT] 段（Fail2Ban 官方要求）
generate_default_jail_conf() {
    local backend="auto"
    local logpath_line="logpath = ${SSH_LOG}"
    if [ "$INIT_SYS" = "systemd" ]; then
        backend="systemd"
        logpath_line=""
    fi
    local ssh_filter="sshd"
    [ "$OS_ID" = "alpine" ] && ssh_filter="alpine-sshd"
    local banaction="iptables-multiport"
    if ! command -v iptables &>/dev/null && command -v nft &>/dev/null; then
        banaction="nftables-multiport"
    fi
    local current_port
    current_port=$(get_sshd_config_val "Port" "22")
    [ -z "$current_port" ] && current_port="22"
    cat <<EOF2
[DEFAULT]
backend = ${backend}
dbfile = /var/lib/fail2ban/fail2ban.sqlite3
dbpurgeage = 648000
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d

[${TARGET_JAIL}]
enabled = true
port = ${current_port}
filter = ${ssh_filter}
${logpath_line}
maxretry = 5
bantime = 600
findtime = 3600
banaction = ${banaction}
ignoreip = 127.0.0.1/8
EOF2
}

# 遷移：老配置裡 [sshd] 段的遞增參數挪到 [DEFAULT] 段
# 老版本腳本把 bantime.increment/factor/maxtime 錯誤地寫在了 [sshd] 段
# Fail2Ban 只認 [DEFAULT]，導致"指數遞增"完全不生效
# 同時確保 dbfile 和 dbpurgeage 存在（遞增功能必需資料庫支援）
migrate_f2b_increment() {
    [ -f "$JAIL_CONF" ] || return
    local k
    # 1. 刪除 [sshd] 段內的遞增參數
    for k in bantime.increment bantime.factor bantime.maxtime; do
        local sshd_has
        sshd_has=$(awk -v t="$TARGET_JAIL" -v kk="$k" '
            BEGIN { in_block=0; found=0 }
            $0 ~ "^\\[" t "\\][[:space:]]*$" { in_block=1; next }
            /^[[:space:]]*\[/ { in_block=0 }
            in_block && $0 ~ "^[[:space:]]*" kk "[[:space:]]*=" { found=1 }
            END { print found }
        ' "$JAIL_CONF")
        if [ "$sshd_has" = "1" ]; then
            $SUDO sed -i "/^\[${TARGET_JAIL}\]/,/^\[/ {/^${k}[[:space:]]*=/d}" "$JAIL_CONF"
        fi
    done

    # 2. 檢查 [DEFAULT] 段是否所有必需參數齊全（遞增三參數 + 資料庫兩參數）
    local need_fix=0
    for k in bantime.increment bantime.factor bantime.maxtime dbfile dbpurgeage; do
        local v
        v=$(awk -v kk="$k" '
            BEGIN { in_block=0; result="" }
            /^\[DEFAULT\][[:space:]]*$/ { in_block=1; next }
            /^[[:space:]]*\[/ { in_block=0 }
            in_block && $0 ~ "^[[:space:]]*" kk "[[:space:]]*=" {
                value=$0
                sub(/^[[:space:]]*[^=]+=[[:space:]]*/, "", value)
                sub(/[[:space:]]+$/, "", value)
                result = value
            }
            END { if (result != "") print result }
        ' "$JAIL_CONF")
        [ -z "$v" ] && need_fix=1
    done

    # 3. 缺失則重寫 [DEFAULT] 段的全部五行配置
    if [ "$need_fix" = "1" ]; then
        # 先清理可能存在的舊配置
        for k in bantime.increment bantime.factor bantime.maxtime dbfile dbpurgeage; do
            $SUDO sed -i "/^\[DEFAULT\]/,/^\[/ {/^${k}[[:space:]]*=/d}" "$JAIL_CONF"
        done
        # 批次插入完整配置（注意順序：資料庫配置在前，遞增配置在後）
        $SUDO sed -i '/^\[DEFAULT\]/a dbfile = /var/lib/fail2ban/fail2ban.sqlite3\ndbpurgeage = 648000\nbantime.increment = true\nbantime.factor = 2\nbantime.maxtime = 7d' "$JAIL_CONF"
    fi

    # 4. 確保資料庫目錄存在且權限正確
    if [ ! -d "/var/lib/fail2ban" ]; then
        $SUDO mkdir -p /var/lib/fail2ban
        $SUDO chmod 755 /var/lib/fail2ban
    fi
}

check_f2b_install() {
    hash -r 2>/dev/null
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${WARN} 未偵測到 Fail2Ban 服務。"
        read -rp "是否立即安裝 Fail2Ban？(y/N): " install_confirm
        [[ ! "$install_confirm" =~ ^[Yy]$ ]] && { echo -e "${WARN} 已取消安裝。"; return 1; }

        echo -e "${INFO} 正在安裝 Fail2Ban 及相關依賴..."
        local f2b_pkgs=()
        case "$PKG_MGR" in
            apt) f2b_pkgs=("fail2ban" "python3-systemd" "rsyslog");;
            dnf|yum) f2b_pkgs=("fail2ban" "rsyslog");;
            zypper) f2b_pkgs=("fail2ban" "rsyslog");;
            pacman) f2b_pkgs=("fail2ban");;
            apk) f2b_pkgs=("fail2ban");;
        esac

        pkg_install "${f2b_pkgs[@]}"
        hash -r 2>/dev/null

        if ! command -v fail2ban-client >/dev/null 2>&1; then
            echo -e "\n${ERROR} Fail2Ban 安裝失敗！${RESET}"
            check_eol_system
            echo -e "${YELLOW}請先解決軟體源問題，然後重新執行本腳本。${RESET}"
            read -rp "按 Enter 鍵返回..."
            return 1
        fi

        if [ ! -d "/etc/fail2ban" ]; then
            echo -e "\n${ERROR} /etc/fail2ban 目錄不存在，安裝可能不完整。${RESET}"
            echo -e "${YELLOW}請檢查 Fail2Ban 是否安裝成功：dpkg -l | grep fail2ban${RESET}"
            read -rp "按 Enter 鍵返回..."
            return 1
        fi

        [ ! -f "$SSH_LOG" ] && { $SUDO touch "$SSH_LOG"; svc_enable rsyslog 2>/dev/null; svc_start rsyslog 2>/dev/null; }

        # 先生成配置檔案（含遞增參數 + 資料庫配置），保證後續 restart 能讀到完整配置
        [ ! -f "$JAIL_CONF" ] && generate_default_jail_conf | $SUDO tee "$JAIL_CONF" > /dev/null

        # 確保資料庫目錄存在（指數遞增依賴資料庫持久化 IP 歷史封禁次數）
        [ ! -d "/var/lib/fail2ban" ] && { $SUDO mkdir -p /var/lib/fail2ban; $SUDO chmod 755 /var/lib/fail2ban; }

        [ "$INIT_SYS" = "systemd" ] && $SUDO systemctl unmask fail2ban &>/dev/null || true
        svc_enable fail2ban
        # 關鍵修復：套件管理器安裝時可能已經自動啟動 fail2ban（讀的是預設 jail.conf），
        # 此時若用 svc_start 就是空操作，導致剛寫入的 jail.local 不被載入。
        # 必須用 svc_restart 強制重讀配置，否則指數遞增不生效，直到 reboot 才行。
        svc_restart fail2ban

        # 輪詢確認服務真正就緒（首次啟動可能稍慢）
        local f2b_up=0
        for i in {1..5}; do
            if fail2ban-client ping >/dev/null 2>&1; then f2b_up=1; break; fi
            sleep 1
        done
        if [ "$f2b_up" -eq 1 ]; then
            echo -e "${INFO} ${GREEN}Fail2Ban 安裝並啟動完成！${RESET}"
        else
            echo -e "${WARN} Fail2Ban 已安裝，但服務尚未就緒，請稍後手動檢查。"
        fi
        sleep 1; return 0
    fi

    # 已安裝 fail2ban-client，但 /etc/fail2ban 目錄缺失 = 殘缺安裝
    if [ ! -d "/etc/fail2ban" ]; then
        echo -e "\n${ERROR} Fail2Ban 處於殘缺狀態：命令存在但 /etc/fail2ban 目錄缺失。${RESET}"
        echo -e "${YELLOW}可能是之前的解除安裝操作沒有清理乾淨。${RESET}\n"
        echo -e "  ${GREEN}1.${RESET} 嘗試修復（重新安裝 Fail2Ban 以重建配置目錄）"
        echo -e "  ${GREEN}2.${RESET} 強制解除安裝 Fail2Ban 殘留"
        echo -e "  ${GREEN}0.${RESET} 返回"
        read -rp "請選擇 [0-2]: " f2b_fix_opt
        case "$f2b_fix_opt" in
            1)
                echo -e "${INFO} 正在重新安裝 Fail2Ban..."
                local f2b_pkgs=()
                case "$PKG_MGR" in
                    apt) f2b_pkgs=("fail2ban" "python3-systemd" "rsyslog");;
                    dnf|yum) f2b_pkgs=("fail2ban" "rsyslog");;
                    zypper) f2b_pkgs=("fail2ban" "rsyslog");;
                    pacman) f2b_pkgs=("fail2ban");;
                    apk) f2b_pkgs=("fail2ban");;
                esac
                pkg_reinstall "${f2b_pkgs[@]}"
                if [ -d "/etc/fail2ban" ]; then
                    echo -e "${INFO} ${GREEN}修復成功！${RESET}"
                    sleep 1
                else
                    echo -e "${ERROR} 修復失敗，請手動處理：dpkg -l | grep fail2ban${RESET}"
                    read -rp "按 Enter 鍵返回..."
                    return 1
                fi
                ;;
            2)
                echo -e "${WARN} 正在強制解除安裝 Fail2Ban..."
                svc_stop fail2ban 2>/dev/null
                svc_disable fail2ban 2>/dev/null
                pkg_remove fail2ban
                # 兜底：apt 失敗時直接用 dpkg 清（dpkg 資料庫損壞場景）
                hash -r 2>/dev/null
                if command -v fail2ban-client &>/dev/null; then
                    echo -e "${WARN} 偵測到殘留，嘗試 dpkg 強制清除..."
                    $SUDO dpkg --purge --force-all fail2ban 2>/dev/null || true
                    $SUDO rm -rf /var/lib/dpkg/info/fail2ban.* 2>/dev/null
                    hash -r 2>/dev/null
                fi
                $SUDO rm -rf /etc/fail2ban
                $SUDO rm -f /usr/bin/fail2ban-client /usr/bin/fail2ban-server /usr/local/bin/fail2ban-* 2>/dev/null
                echo -e "${INFO} ${GREEN}Fail2Ban 已強制解除安裝。${RESET}"
                read -rp "按 Enter 鍵返回..."
                return 1
                ;;
            *)
                return 1
                ;;
        esac
    fi

    # 記錄配置修改前的雜湊（md5sum 更高效，避免大檔案全文對比）
    local conf_hash_before=""
    [ -f "$JAIL_CONF" ] && conf_hash_before=$(md5sum "$JAIL_CONF" 2>/dev/null | awk '{print $1}')

    if [ ! -f "$JAIL_CONF" ]; then
        generate_default_jail_conf | $SUDO tee "$JAIL_CONF" > /dev/null
    else
        if ! grep -q "^\[DEFAULT\]" "$JAIL_CONF"; then
            local be="auto"; [ "$INIT_SYS" = "systemd" ] && be="systemd"
            $SUDO sed -i "1i [DEFAULT]\nbackend = ${be}" "$JAIL_CONF"
        fi
        # 遷移老配置：把 [sshd] 段錯放的遞增參數挪到 [DEFAULT] + 確保資料庫配置存在
        migrate_f2b_increment
        if ! grep -q "^\[${TARGET_JAIL}\]" "$JAIL_CONF"; then
            generate_default_jail_conf | grep -A99 "^\[${TARGET_JAIL}\]" | $SUDO tee -a "$JAIL_CONF" > /dev/null
        else
            # 保證 [sshd] 段基本參數齊全（不含遞增參數，那些歸 [DEFAULT]）
            local current_port
            current_port=$(get_sshd_config_val "Port" "22")
            [ -z "$current_port" ] && current_port="22"
            local defaults=(
                "enabled=true" "port=${current_port}" "filter=sshd" "maxretry=5"
                "bantime=600" "findtime=3600"
            )
            for item in "${defaults[@]}"; do
                local k="${item%%=*}" v="${item#*=}"
                [ -n "$(get_f2b_conf "$k")" ] || set_f2b_conf "$k" "$v"
            done
        fi
    fi

    # 關鍵修復：上面可能有遷移/補全動作改動了 jail.local，
    # 用雜湊對比判斷配置是否真變化，避免每次進選單都觸發 Restore Ban 刷屏。
    local conf_hash_after=""
    [ -f "$JAIL_CONF" ] && conf_hash_after=$(md5sum "$JAIL_CONF" 2>/dev/null | awk '{print $1}')

    if [ "$conf_hash_before" != "$conf_hash_after" ]; then
        # 配置有變化：重新載入或啟動服務讓新配置生效
        if fail2ban-client ping >/dev/null 2>&1; then
            restart_f2b
        else
            echo -e "${INFO} 偵測到配置變更，正在啟動 Fail2Ban..."
            svc_start fail2ban
            local f2b_up=0
            for i in {1..5}; do
                if fail2ban-client ping >/dev/null 2>&1; then f2b_up=1; break; fi
                sleep 1
            done
            if [ "$f2b_up" -eq 1 ]; then
                echo -e "${INFO} ${GREEN}Fail2Ban 已啟動並載入新配置。${RESET}"
            else
                echo -e "${ERROR} Fail2Ban 啟動超時或失敗。"
                echo -e "${YELLOW}請手動執行 'journalctl -u fail2ban -n 50' 排查錯誤。${RESET}"
            fi
        fi
    else
        # 配置未變化：僅做服務狀態兜底，避免每次進選單重啟導致 Restore Ban 刷屏
        if ! fail2ban-client ping >/dev/null 2>&1; then
            echo -e "${WARN} Fail2Ban 服務未執行，正在嘗試啟動..."
            svc_start fail2ban
            local f2b_up=0
            for i in {1..5}; do
                if fail2ban-client ping >/dev/null 2>&1; then f2b_up=1; break; fi
                sleep 1
            done
            if [ "$f2b_up" -eq 1 ]; then
                echo -e "${INFO} ${GREEN}Fail2Ban 已啟動。${RESET}"
            else
                echo -e "${ERROR} Fail2Ban 啟動超時或失敗。"
                echo -e "${YELLOW}請手動執行 'journalctl -u fail2ban -n 50' 排查錯誤。${RESET}"
            fi
        fi
    fi

    return 0
}

uninstall_f2b() {
    echo -e "\n${RED}${BOLD}警告：即將解除安裝 Fail2Ban 及其配置！${RESET}"
    read -rp "確認解除安裝嗎？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "${INFO} 已取消解除安裝。"; read -rp "按 Enter 鍵繼續..."; return 1; }
    svc_stop fail2ban; svc_disable fail2ban
    pkg_remove fail2ban
    # 清 bash 命令快取：否則 command -v 仍返回已刪除的舊路徑，
    # 導致解除安裝後狀態仍顯示"已安裝 / 已停止"。
    hash -r 2>/dev/null
    # 兜底：apt 解除安裝失敗時用 dpkg 強制清除（dpkg 資料庫損壞 / 靜默失敗場景）
    if command -v fail2ban-client &>/dev/null; then
        echo -e "${WARN} 偵測到殘留，嘗試 dpkg 強制清除..."
        $SUDO dpkg --purge --force-all fail2ban 2>/dev/null || true
        $SUDO rm -rf /var/lib/dpkg/info/fail2ban.* 2>/dev/null
    fi
    # 再兜底：物理刪除可能的二進位制殘留
    $SUDO rm -f /usr/bin/fail2ban-client /usr/bin/fail2ban-server /usr/local/bin/fail2ban-* 2>/dev/null
    hash -r 2>/dev/null
    read -rp "是否同時刪除配置目錄 /etc/fail2ban ？(y/N): " del_conf
    [[ "$del_conf" =~ ^[Yy]$ ]] && { $SUDO rm -rf /etc/fail2ban; echo -e "${INFO} 已刪除 /etc/fail2ban"; }
    echo -e "${INFO} ${GREEN}Fail2Ban 解除安裝完成。${RESET}"; read -rp "按 Enter 鍵繼續..."
    return 0
}

change_f2b_param() {
    local name=$1 key=$2 type=$3
    local current; current=$(get_f2b_conf "$key")
    echo -e "\n${INFO} 正在修改: ${CYAN}${name}${RESET}"
    echo -e "目前值: ${GREEN}$(fmt_f2b_unit "$current" "$type")${RESET}"
    [ "$type" == "time" ] && echo -e "${GRAY}(支援字尾: s=秒, m=分, h=小時, d=天)${RESET}"
    while true; do
        read -rp "請輸入新值 (留空取消): " new_val
        [ -z "$new_val" ] && return
        if [ "$type" == "time" ] && validate_time "$new_val"; then break; fi
        if [ "$type" == "int" ] && validate_int "$new_val"; then break; fi
        if [ "$type" == "factor" ] && validate_int "$new_val"; then break; fi
        echo -e "${ERROR} 格式錯誤，請重試。"
    done
    set_f2b_conf "$key" "$new_val"; restart_f2b
}

toggle_f2b_service() {
    echo -e "\n${CYAN}------------------- 服務開關 -------------------${RESET}"
    if fail2ban-client ping >/dev/null 2>&1; then
        read -rp "是否停止並禁用 Fail2Ban? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && { svc_stop fail2ban; svc_disable fail2ban; echo -e "${WARN} 服務已停止。${RESET}"; }
    else
        read -rp "是否啟用並啟動 Fail2Ban? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            svc_enable fail2ban; svc_start fail2ban
            for i in {1..5}; do
                if fail2ban-client ping >/dev/null 2>&1; then echo -e "${INFO} ${GREEN}服務已成功啟動。${RESET}"; read -rp "按 Enter 鍵繼續..."; return; fi; sleep 1
            done
            echo -e "${ERROR} 啟動失敗或超時。"
        fi
    fi
    read -rp "按 Enter 鍵繼續..."
}

unban_f2b_ip() {
    echo -e "\n${CYAN}------------------ 手動解封 IP ------------------${RESET}"
    local banned_list
    banned_list=$(fail2ban-client status "$TARGET_JAIL" 2>/dev/null | grep "Banned IP list" | awk -F':' '{print $2}' | sed 's/^[ \t]*//')
    [ -z "$banned_list" ] && banned_list="無"
    echo -e "目前被封禁列表: ${YELLOW}${banned_list}${RESET}"
    read -rp "輸入要解封的 IP (留空取消): " target_ip; [ -z "$target_ip" ] && return
    $SUDO fail2ban-client set "$TARGET_JAIL" unbanip "$target_ip"
    [ $? -eq 0 ] && echo -e "${INFO} ${GREEN}解封成功: $target_ip${RESET}" || echo -e "${ERROR} 操作失敗。"
    read -rp "按 Enter 鍵繼續..."
}

add_f2b_whitelist() {
    echo -e "\n${CYAN}------------------ 白名單管理 ------------------${RESET}"
    local current_list; current_list=$(get_f2b_conf "ignoreip")
    echo -e "目前白名單: ${YELLOW}${current_list:-繼承全域或無}${RESET}"
    local current_ip; current_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
    read -rp "輸入要放行的 IP (回車預設目前連線 IP: ${current_ip:-無}): " input_ip
    [ -z "$input_ip" ] && input_ip="$current_ip"
    [ -z "$input_ip" ] && echo -e "${ERROR} 無法取得 IP。" && return
    if echo "$current_list" | grep -Fq "$input_ip"; then
        echo -e "${WARN} 該 IP 已在白名單中。"
    else
        if [ -z "$current_list" ]; then set_f2b_conf "ignoreip" "$input_ip"
        else set_f2b_conf "ignoreip" "$current_list $input_ip"; fi
        restart_f2b
    fi
    read -rp "按 Enter 鍵繼續..."
}

view_f2b_logs() {
    clear
    echo -e "${CYAN}============================================================${RESET}"
    echo -e "${BOLD}${PURPLE}                 Fail2Ban 審計日誌 (最近 20 條)${RESET}"
    echo -e "${CYAN}============================================================${RESET}"
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${WARN} 日誌檔案不存在: $LOG_FILE"
    else
        local out
        out=$(grep -E "(Ban|Unban)" "$LOG_FILE" 2>/dev/null | tail -n 20)
        if [ -z "$out" ]; then
            echo -e "${WARN} 暫無封禁/解封記錄${RESET}"
        else
            echo "$out" | awk '{
                gsub(/Unban/, "\033[32m&\033[0m");
                gsub(/Ban/, "\033[31m&\033[0m");
                print
            }'
        fi
    fi
    echo -e "${CYAN}============================================================${RESET}"
    read -rp "按 Enter 鍵返回..."
}

menu_f2b_exponential() {
    while true; do
        clear
        local inc fac max
        inc=$(get_f2b_conf "bantime.increment")
        fac=$(get_f2b_conf "bantime.factor")
        max=$(get_f2b_conf "bantime.maxtime")
        local S_INC; [ "$inc" == "true" ] && S_INC="${GREEN}啟用${RESET}" || S_INC="${YELLOW}禁用${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}${PURPLE}            進階: 指數封禁設定 (針對 sshd)${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e " 說明: 對重複犯錯的惡意 IP，封禁時間按設定係數成倍遞增"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}1.${RESET} 遞增模式開關   [${S_INC}]"
        echo -e "  ${GREEN}2.${RESET} 增長係數       [${YELLOW}${fac:-未設定}${RESET}]$(fmt_f2b_unit "$fac" "factor")"
        echo -e "  ${GREEN}3.${RESET} 封禁上限       [${YELLOW}${max:-未設定}${RESET}]$(fmt_f2b_unit "$max" "time")"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}0.${RESET} 返回上級"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${GRAY}提示: 輸入對應序號後可自訂該參數${RESET}"
        read -rp "請選擇 [0-3]: " sc
        case "$sc" in
            1) [ "$inc" == "true" ] && ns="false" || ns="true"; set_f2b_conf "bantime.increment" "$ns"; restart_f2b ;;
            2) change_f2b_param "增長係數 (倍數)" "bantime.factor" "factor" ;;
            3) change_f2b_param "封禁上限 (時間)" "bantime.maxtime" "time" ;;
            0) return ;;
            *) echo -e "${ERROR} 無效選項！"; sleep 1 ;;
        esac
    done
}

manage_fail2ban_menu() {
    if ! check_f2b_install; then read -rp "按 Enter 鍵返回主選單..."; return; fi
    while true; do
        clear
        VAL_MAX=$(get_f2b_conf "maxretry"); VAL_BAN=$(get_f2b_conf "bantime"); VAL_FIND=$(get_f2b_conf "findtime")
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}${PURPLE}                     Fail2Ban 防護管理${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "  服務狀態: $(get_fail2ban_status)"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}1.${RESET} 最大重試次數     [${YELLOW}${VAL_MAX:-預設}${RESET}]"
        echo -e "  ${GREEN}2.${RESET} 初始封禁時長     [${YELLOW}${VAL_BAN:-預設}${RESET}]$(fmt_f2b_unit "$VAL_BAN" "time")"
        echo -e "  ${GREEN}3.${RESET} 監測時間視窗     [${YELLOW}${VAL_FIND:-預設}${RESET}]$(fmt_f2b_unit "$VAL_FIND" "time")"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}4.${RESET} 手動解封 IP"
        echo -e "  ${GREEN}5.${RESET} 新增 IP 白名單"
        echo -e "  ${GREEN}6.${RESET} 檢視封禁日誌 (最近20條)"
        echo -e "  ${GREEN}7.${RESET} 指數遞增封禁設定 ->"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}8.${RESET} 啟用 / 停止 服務"
        echo -e "  ${GREEN}9.${RESET} 解除安裝 Fail2Ban"
        echo -e "  ${GREEN}0.${RESET} 返回主選單"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "請選擇 [0-9]: " choice
        case "$choice" in
            1) change_f2b_param "最大重試次數" "maxretry" "int" ;;
            2) change_f2b_param "初始封禁時長" "bantime" "time" ;;
            3) change_f2b_param "監測時間視窗" "findtime" "time" ;;
            4) unban_f2b_ip ;;
            5) add_f2b_whitelist ;;
            6) view_f2b_logs ;;
            7) menu_f2b_exponential ;;
            8) toggle_f2b_service ;;
            9) # 解除安裝後根據返回值決定是否返回主選單：
               #   uninstall_f2b 返回 0 = 解除安裝完成 → 返回主選單
               #   uninstall_f2b 返回 1 = 使用者取消 → 留在本選單
               if uninstall_f2b; then
                   return
               fi
               ;;
            0) return ;;
            *) echo -e "${ERROR} 無效選項！"; sleep 1 ;;
        esac
    done
}

# ============ 狀態面板 ============
show_status() {
    local port; port=$(get_sshd_config_val "Port" "22")
    local pwd_auth; pwd_auth=$(get_sshd_config_val "PasswordAuthentication" "yes")
    local pubkey_auth; pubkey_auth=$(get_sshd_config_val "PubkeyAuthentication" "yes")
    local f2b_stat; f2b_stat=$(get_fail2ban_status)
    local key_count; key_count=$(count_authorized_keys)

    echo -e "${CYAN}============================================================${RESET}"
    echo -e "${BOLD}${PURPLE}                     SSH 安全配置工具${RESET}"
    echo -e "${CYAN}============================================================${RESET}"
    echo -e " 系統架構 : ${GREEN}${OS_SHORT} ${OS_VER}${RESET}"
    if [[ "${pubkey_auth,,}" == "yes" ]]; then
        if [ "$key_count" -gt 0 ]; then
            echo -e " 金鑰登入 : ${GREEN}已啟用 (${key_count} 把公鑰)${RESET}"
        else
            echo -e " 金鑰登入 : ${YELLOW}已啟用 (但無公鑰，無法金鑰登入)${RESET}"
        fi
    else
        echo -e " 金鑰登入 : ${YELLOW}已禁用${RESET}"
    fi
    if [[ "${pwd_auth,,}" == "no" ]]; then
        echo -e " 密碼登入 : ${GREEN}已禁用 (PasswordAuthentication no)${RESET}"
    else
        echo -e " 密碼登入 : ${YELLOW}已啟用 (推薦配置金鑰後禁用)${RESET}"
    fi
    echo -e " Fail2Ban : ${f2b_stat}"
    echo -e " SSH 埠號 : ${CYAN}${port}${RESET}"
    echo -e "${CYAN}============================================================${RESET}"
}

# ============ 金鑰生成 ============
generate_vps_keypair() {
    echo -e "\n${INFO} 準備在 VPS 上生成新的 ED25519 金鑰..."
    local key_file="${HOME}/.ssh/PrivateKey.pem"
    local pub_file="${HOME}/.ssh/PublicKey.pub"

    if [ -f "$key_file" ] || [ -f "$pub_file" ] || [ -f "${key_file}.pub" ]; then
        echo -e "${WARN} 偵測到已有舊同名金鑰，即將覆蓋清理..."
        rm -f "$key_file" "$pub_file" "${key_file}.pub"
    fi

    # -C "" 保證生成的金鑰無字尾標識資訊
    ssh-keygen -t ed25519 -C "" -f "$key_file" -N "" -q
    if [ ! -f "${key_file}.pub" ]; then
        echo -e "${ERROR} 金鑰生成失敗！請檢查 $HOME/.ssh 是否可寫或磁碟空間是否充足。"
        read -rp "按 Enter 鍵返回..."
        return 1
    fi
    mv "${key_file}.pub" "$pub_file"

    local pub_content
    pub_content=$(cat "$pub_file")

    append_key_with_meta "$pub_content" "VPS本地生成"

    echo -e "\n${GREEN}====================== 金鑰生成成功 ======================${RESET}"
    echo -e " VPS 上的私鑰路徑 : ${CYAN}${key_file}${RESET}"
    echo -e " VPS 上的公鑰路徑 : ${CYAN}${pub_file}${RESET}"
    echo -e " 授權目標檔案     : 已將公鑰寫入 ${CYAN}${HOME}/.ssh/authorized_keys${RESET}"
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    echo -e "${YELLOW}${BOLD}[私鑰文字 (PrivateKey.pem)] - 用於登入此 VPS：${RESET}"
    echo -e "${YELLOW}"
    cat "$key_file"
    echo -e "${RESET}"
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    echo -e "${GREEN}${BOLD}[公鑰文字 (PublicKey.pub)] - 用於上傳至 GitHub：${RESET}"
    echo -e "${GREEN}${pub_content}${RESET}"
    echo -e "${CYAN}------------------------------------------------------------${RESET}"

    echo -e "${BOLD}${PURPLE}[💡 新手一勞永逸指南]${RESET}"
    echo -e " ${BOLD}一、儲存金鑰到本地電腦 (二選一)：${RESET}"
    echo -e "   ${GREEN}• 方式 A (推薦·直接下載)：${RESET}開啟 SSH 客戶端自帶的 ${CYAN}SFTP / 檔案傳輸${RESET} 功能 (如 FinalShell、Xshell、WinSCP、Termius 等)，"
    echo -e "     定位到伺服器目錄：${CYAN}${HOME}/.ssh/${RESET}"
    echo -e "     將 ${CYAN}PrivateKey.pem${RESET} (私鑰) 和 ${CYAN}PublicKey.pub${RESET} (公鑰) 直接下載儲存到本地電腦。"
    echo -e "   ${GREEN}• 方式 B (手動複製)：${RESET}"
    echo -e "     1. 複製上面的【私鑰文字】，在本地新建純文字檔案儲存為：${CYAN}PrivateKey.pem${RESET}"
    echo -e "     2. 複製上面的【公鑰文字】，在本地新建純文字檔案儲存為：${CYAN}PublicKey.pub${RESET}"
    echo -e "\n ${BOLD}二、繫結 GitHub 打通長期複用工作流(可選)：${RESET}"
    echo -e "   1. 開啟 ${CYAN}https://github.com/settings/keys${RESET} ，點選 \"New SSH key\"；"
    echo -e "   2. 將 ${CYAN}PublicKey.pub${RESET} 裡的【公鑰文字】貼上進去並儲存；"
    echo -e "   3. ${GREEN}以後在其他 VPS 上執行本腳本，只需選擇【選項 1】輸入 GitHub 使用者名稱即可快速拉取！${RESET}\n"

    read -rp "確認已儲存/下載金鑰，是否立即刪除 VPS 上的暫存金鑰檔案？(Y/n): " rm_confirm
    if [[ -z "$rm_confirm" || "$rm_confirm" =~ ^[Yy]$ ]]; then
        rm -f "$key_file" "$pub_file"
        echo -e "${INFO} ${GREEN}已成功刪除 VPS 上的暫存金鑰檔案。${RESET}"
    else
        echo -e "${WARN} 金鑰檔案仍保留在: ${key_file} 和 ${pub_file} (請務必防範私鑰洩露)"
    fi
}

# ============ 金鑰登入開關 ============
toggle_pubkey_login() {
    local current
    current=$(get_sshd_config_val "PubkeyAuthentication" "yes")

    if [[ "${current,,}" == "no" ]]; then
        echo -e "\n目前金鑰登入已${GREEN}禁用${RESET}。"
        local key_count; key_count=$(count_authorized_keys)
        if [ "$key_count" -eq 0 ]; then
            echo -e "${YELLOW}[提示] 目前 authorized_keys 中還沒有公鑰，啟用後仍需先新增公鑰才能透過金鑰登入。${RESET}"
        fi
        read -rp "是否要啟用金鑰登入？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            set_sshd_config "PubkeyAuthentication" "yes"
            restart_sshd
            echo -e "${INFO} ${GREEN}金鑰登入已成功啟用。${RESET}"
        fi
    else
        echo -e "\n${YELLOW}${BOLD}[警告] 禁用金鑰登入後，如果密碼登入也已禁用，你將無法登入 VPS！${RESET}"
        if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
            echo -e "${CYAN}${BOLD}[提示] 偵測到您正在使用 SSH 遠端會話，修改後切勿關閉目前視窗！${RESET}"
        fi

        local pwd_auth
        pwd_auth=$(get_sshd_config_val "PasswordAuthentication" "yes")
        if [[ "${pwd_auth,,}" == "no" ]]; then
            echo -e "${RED} 偵測到密碼登入已禁用，禁用金鑰登入後你將無法登入此 VPS！${RESET}"
            read -rp "確認仍然要禁用金鑰登入嗎？(y/N): " confirm_risky
            [[ ! "$confirm_risky" =~ ^[Yy]$ ]] && { echo -e "${INFO} 已取消操作。"; read -rp "按 Enter 鍵繼續..."; return; }
        else
            read -rp "確認禁用金鑰登入嗎？(y/N): " confirm
            [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "${INFO} 已取消操作。"; read -rp "按 Enter 鍵繼續..."; return; }
        fi

        set_sshd_config "PubkeyAuthentication" "no"
        restart_sshd
        echo -e "${INFO} ${GREEN}金鑰登入已禁用，現在只能透過密碼登入。${RESET}"
    fi
    read -rp "按 Enter 鍵繼續..."
}

# ============ 金鑰配置選單 ============
install_key_menu() {
    while true; do
        clear
        init_ssh_dir

        # 動態統計目前公鑰數量
        local key_count
        key_count=$(count_authorized_keys)
        local key_count_label
        if [ "$key_count" -gt 0 ]; then
            key_count_label=" (${GREEN}${key_count} 把公鑰${RESET})"
        else
            key_count_label=" (${YELLOW}無公鑰${RESET})"
        fi

        # 動態顯示目前金鑰登入開關狀態，避免新人困惑
        local pubkey_status
        pubkey_status=$(get_sshd_config_val "PubkeyAuthentication" "yes")
        local pubkey_label
        if [[ "${pubkey_status,,}" == "yes" ]]; then
            pubkey_label="[${GREEN}已啟用${RESET}]"
        else
            pubkey_label="[${YELLOW}已禁用${RESET}]"
        fi

        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}${PURPLE}                     SSH 金鑰登入管理${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}請選擇 SSH 金鑰配置方式：${RESET}"
        echo -e "  ${GREEN}1.${RESET} 從 GitHub 取得公鑰 (${CYAN}適合：已將公鑰上傳至 GitHub 的使用者${RESET})"
        echo -e "  ${GREEN}2.${RESET} 在 VPS 上全新生成金鑰 (${CYAN}適合：本地沒有金鑰的新手，生成後可傳 GitHub${RESET})"
        echo -e "  ${GREEN}3.${RESET} 從自訂 URL 取得公鑰 (${CYAN}適合：有公鑰直鏈的使用者${RESET})"
        echo -e "  ${GREEN}4.${RESET} 管理已存公鑰${key_count_label}"
        echo -e "  ${GREEN}5.${RESET} 金鑰登入開關 ${pubkey_label}"
        echo -e "  ${GREEN}0.${RESET} 返回主選單"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "請輸入選項 [0-5]: " key_opt

        local test_hint=""
        local do_restart=0

        case "$key_opt" in
            1)
                echo -e "\n${YELLOW}${BOLD}[使用前提]${RESET}"
                echo -e "需先將本地公鑰上傳至 GitHub: ${CYAN}https://github.com/settings/keys${RESET}\n"
                read -rp "請輸入您的 GitHub 使用者名稱: " gh_user
                if [ -z "$gh_user" ]; then
                    echo -e "${ERROR} 輸入不能為空！"
                    read -rp "按 Enter 鍵繼續..."
                    continue
                fi
                echo -e "${INFO} 正在從 GitHub 拉取公鑰..."
                local pub_key
                pub_key=$(curl -fsSL "https://github.com/${gh_user}.keys")
                if [ -z "$pub_key" ] || [[ "$pub_key" == "Not Found" ]]; then
                    echo -e "\n${ERROR} 取得公鑰失敗！可能是使用者名稱不正確，或該 GitHub 帳號未配置公鑰。"
                    echo -e "${CYAN}------------------------------------------------------------${RESET}"
                    read -rp "是否要在 VPS 上全新生成金鑰 (選項 2)？(y/N): " switch_opt2
                    if [[ "$switch_opt2" =~ ^[Yy]$ ]]; then
                        generate_vps_keypair
                        test_hint="請將已儲存的私鑰匯入本地 SSH 客戶端，新建終端測試連線。"
                        do_restart=1
                    else
                        read -rp "按 Enter 鍵繼續..."
                        continue
                    fi
                else
                    append_key_with_meta "$pub_key" "GitHub: ${gh_user}"
                    test_hint="請使用該 GitHub 公鑰對應的本地私鑰，新建終端測試連線。"
                    do_restart=1
                fi
                ;;
            2)
                generate_vps_keypair
                test_hint="請將已儲存的私鑰匯入本地 SSH 客戶端，新建終端測試連線。"
                do_restart=1
                ;;
            3)
                read -rp "請輸入公鑰 URL: " key_url
                if [ -z "$key_url" ]; then
                    echo -e "${ERROR} URL 不能為空！"
                    read -rp "按 Enter 鍵繼續..."
                    continue
                fi
                local pub_key
                pub_key=$(curl -fsSL "$key_url")
                if [ -z "$pub_key" ]; then
                    echo -e "${ERROR} 從 URL 取得公鑰失敗！"
                    read -rp "按 Enter 鍵繼續..."
                    continue
                fi
                append_key_with_meta "$pub_key" "自訂URL"
                test_hint="請使用該公鑰對應的本地私鑰，新建終端測試連線。"
                do_restart=1
                ;;
            4)
                manage_keys_menu
                continue
                ;;
            5)
                toggle_pubkey_login
                continue
                ;;
            0) return ;;
            *)
                echo -e "${ERROR} 無效選項！"
                sleep 1
                continue
                ;;
        esac

        if [ "$do_restart" == "1" ]; then
            set_sshd_config "PubkeyAuthentication" "yes"
            restart_sshd
            echo -e "\n${CYAN}------------------------------------------------------------${RESET}"
            echo -e "${YELLOW}${BOLD}[重點測試]${RESET} ${test_hint}"
            echo -e "測試成功後，再返回主選單【禁用密碼登入】！"
            echo -e "${CYAN}------------------------------------------------------------${RESET}"
            read -rp "按 Enter 鍵返回金鑰管理子選單..."
        fi
    done
}

# ============ 已存公鑰管理 ============
manage_keys_menu() {
    init_ssh_dir
    local auth_file="${HOME}/.ssh/authorized_keys"

    while true; do
        clear
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}${PURPLE}                     SSH 已存公鑰管理${RESET}"
        echo -e "${CYAN}============================================================${RESET}"

        local key_lines=()
        local key_contents=()
        local line_num=0

        if [ -f "$auth_file" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                ((line_num++))
                if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
                    continue
                fi
                key_lines+=("$line_num")
                key_contents+=("$line")
            done < "$auth_file"
        fi

        if [ ${#key_contents[@]} -eq 0 ]; then
            echo -e "\n${WARN} 目前 ${auth_file} 中沒有找到任何有效公鑰！"
            echo -e "${CYAN}============================================================${RESET}"
            read -rp "按 Enter 鍵返回..."
            return
        fi

        printf " %-4s | %-19s | %-8s | %-16s\n" "序號" "      新增時間" "公鑰類型" "    備註來源"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"

        local idx=1
        for key in "${key_contents[@]}"; do
            local add_time="歷史存量/未標記"
            local key_tag="未知/手動匯入"

            if [[ "$key" =~ \[([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\|([^\]]+)\] ]]; then
                add_time="${BASH_REMATCH[1]}"
                key_tag="${BASH_REMATCH[2]}"
            fi

            # 修正：帶選項字首的公鑰也能正確顯示金鑰類型
            local key_type
            key_type=$(echo "$key" | awk '{
                for(i=1;i<=NF;i++){
                    if($i ~ /^(ssh-|ecdsa-|sk-)/){ print $i; exit }
                }
                print "未知"
            }')

            printf " ${GREEN}[%2d]${RESET} | ${YELLOW}%19s${RESET} | ${CYAN}%-8s${RESET} | ${PURPLE}%-16s${RESET}\n" "$idx" "$add_time" "$key_type" "$key_tag"
            ((idx++))
        done

        echo -e "${CYAN}============================================================${RESET}"
        echo -e " 輸入 ${RED}[序號]${RESET} : 刪除指定公鑰"
        echo -e " 輸入 ${RED}[all]${RESET}  : 清空全部公鑰"
        echo -e " 輸入 ${GREEN}[0]${RESET}    : 返回上級選單"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "請輸入操作指令: " key_action

        if [ "$key_action" == "0" ]; then
            return
        elif [ "$key_action" == "all" ]; then
            # 危險檢查：密碼登入已禁用時清空全部公鑰會鎖死
            if [[ "$(get_sshd_config_val "PasswordAuthentication" "yes")" == "no" ]]; then
                echo -e "${RED}${BOLD}[危險] 密碼登入已禁用，清空全部公鑰後你將無法登入此 VPS！${RESET}"
                read -rp "確認仍然要清空嗎？(y/N): " risky_all
                [[ ! "$risky_all" =~ ^[Yy]$ ]] && continue
            fi
            read -rp "確認要清空所有公鑰嗎？(y/N): " confirm_all
            if [[ "$confirm_all" =~ ^[Yy]$ ]]; then
                > "$auth_file"
                echo -e "${INFO} 已清空所有公鑰！"
                sleep 1
                continue
            fi
        elif [[ "$key_action" =~ ^[0-9]+$ ]] && [ "$key_action" -ge 1 ] && [ "$key_action" -le "${#key_contents[@]}" ]; then
            local target_idx=$((key_action - 1))
            local target_line_num="${key_lines[$target_idx]}"

            # 危險檢查：密碼登入已禁用 + 只剩最後一個公鑰時刪除會鎖死
            if [[ "$(get_sshd_config_val "PasswordAuthentication" "yes")" == "no" ]] && [ "${#key_contents[@]}" -eq 1 ]; then
                echo -e "${RED}${BOLD}[危險] 密碼登入已禁用，刪除最後一個公鑰後你將無法登入此 VPS！${RESET}"
                read -rp "確認仍然要刪除嗎？(y/N): " risky_del
                [[ ! "$risky_del" =~ ^[Yy]$ ]] && continue
            fi

            read -rp "確認刪除序號 [${key_action}] 的公鑰嗎？(y/N): " confirm_del
            if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
                sed -i "${target_line_num}d" "$auth_file"
                chmod 600 "$auth_file"
                echo -e "${INFO} ${GREEN}序號 [${key_action}] 的公鑰已成功刪除！${RESET}"
                sleep 1
                continue
            fi
        else
            echo -e "${ERROR} 輸入無效，請重新輸入！"
            sleep 1
            continue
        fi
    done
}

# ============ 密碼登入開關 ============
toggle_password_login() {
    local current
    current=$(get_sshd_config_val "PasswordAuthentication" "yes")

    if [[ "${current,,}" == "no" ]]; then
        echo -e "\n目前密碼登入已${GREEN}禁用${RESET}。"
        read -rp "是否要啟用密碼登入？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            set_sshd_config "PasswordAuthentication" "yes"
            restart_sshd
            echo -e "${INFO} 已成功啟用密碼登入。"

            read -rp "是否需要為目前使用者 ($(whoami)) 設定新密碼？(y/N): " pwd_confirm
            if [[ "$pwd_confirm" =~ ^[Yy]$ ]]; then
                passwd "$(whoami)"
            fi
        fi
    else
        echo -e "\n${YELLOW}${BOLD}[警告] 禁用密碼登入前，請務必確認金鑰登入能夠成功！${RESET}"
        # 危險檢查：金鑰登入不可用時禁用密碼登入會鎖死
        local pubkey_auth; pubkey_auth=$(get_sshd_config_val "PubkeyAuthentication" "yes")
        local pubkey_ok=0
        if [[ "${pubkey_auth,,}" == "yes" ]] && has_valid_pubkey; then
            pubkey_ok=1
        fi
        if [ "$pubkey_ok" -eq 0 ]; then
            if [[ "${pubkey_auth,,}" != "yes" ]]; then
                echo -e "${RED}${BOLD}[危險] 金鑰登入已禁用，禁用密碼登入後你將無法登入此 VPS！${RESET}"
            else
                echo -e "${RED}${BOLD}[危險] authorized_keys 中沒有任何公鑰，禁用密碼登入後你將無法登入此 VPS！${RESET}"
            fi
            read -rp "確認仍然要禁用嗎？(y/N): " risky_confirm
            [[ ! "$risky_confirm" =~ ^[Yy]$ ]] && { echo -e "${INFO} 已取消操作。"; read -rp "按 Enter 鍵繼續..."; return; }
        fi
        if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
            echo -e "${CYAN}${BOLD}[提示] 偵測到您正在使用 SSH 遠端會話，修改後切勿關閉目前視窗，請先新建終端測試連線！${RESET}"
        fi
        read -rp "確認徹底禁用密碼登入嗎？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            set_sshd_config "PasswordAuthentication" "no"
            set_sshd_config "ChallengeResponseAuthentication" "no"
            set_sshd_config "KbdInteractiveAuthentication" "no"
            restart_sshd
            echo -e "${INFO} ${GREEN}密碼登入已成功禁用！現在只能透過金鑰登入。${RESET}"
        fi
    fi
    read -rp "按 Enter 鍵返回主選單..."
}

# ============ 修改 SSH 連接埠 ============
change_ssh_port() {
    local current_port
    current_port=$(get_sshd_config_val "Port" "22")
    echo -e "\n目前 SSH 連接埠為: ${CYAN}${current_port}${RESET}"
    if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
        echo -e "${YELLOW}${BOLD}[提示] 偵測到您正在使用 SSH 遠端會話，修改連接埠後請勿關閉目前視窗，請先新建終端驗證！${RESET}"
    fi
    read -rp "請輸入新的 SSH 連接埠 (1024-65535): " new_port

    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${ERROR} 連接埠格式不正確！"
        read -rp "按 Enter 鍵返回主選單..."
        return
    fi

    if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then
        echo -e "${INFO} 偵測到 SELinux 啟用，正在申請放行連接埠 ${new_port}..."
        if command -v semanage &>/dev/null; then
            $SUDO semanage port -a -t ssh_port_t -p tcp "$new_port" 2>/dev/null || \
            $SUDO semanage port -m -t ssh_port_t -p tcp "$new_port" 2>/dev/null
        else
            echo -e "${WARN} 未安裝 semanage，如使用 RHEL/CentOS 繫系統，可能需要手動配置 SELinux。"
        fi
    fi

    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        echo -e "${INFO} 正在向 ufw 防火牆放行連接埠 ${new_port}/tcp..."
        $SUDO ufw allow "$new_port"/tcp >/dev/null
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        echo -e "${INFO} 正在向 firewalld 防火牆放行連接埠 ${new_port}/tcp..."
        $SUDO firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null
        $SUDO firewall-cmd --reload >/dev/null
    fi

    set_sshd_config "Port" "$new_port"

    if restart_sshd; then
        echo -e "${INFO} ${GREEN}SSH 連接埠已順利修改為 ${new_port}${RESET}"

        # 同步更新 Fail2Ban 連接埠
        if [ -f "$JAIL_CONF" ] && grep -q "^\[${TARGET_JAIL}\]" "$JAIL_CONF"; then
            set_f2b_conf "port" "$new_port"
            if command -v fail2ban-client &>/dev/null && fail2ban-client ping >/dev/null 2>&1; then
                echo -e "${INFO} 正在同步更新 Fail2Ban 防護連接埠..."
                restart_f2b
            fi
        fi

        if command -v ss &>/dev/null; then
            echo -e "${INFO} 系統實際監聽服務連接埠狀態："
            ss -tulpn | grep ssh || true
        fi
        echo -e "${WARN} 注意：如使用的是阿里雲/騰訊雲/AWS等，請務必在【雲伺服器安全組】中開放 TCP ${new_port} 連接埠！"
    fi

    read -rp "按 Enter 鍵返回主選單..."
}

# ============ 主邏輯 ============
detect_os; detect_pkg_mgr; detect_init; detect_ssh_log
check_dependencies

# ============ 命令列參數解析 ============
# 先收集所有參數，迴圈結束後按依賴順序統一執行
OVERWRITE=0
CLI_GH_USER=""
CLI_KEY_URL=""
CLI_KEY_FILE=""
CLI_PORT=""
CLI_DISABLE_PWD=0

while getopts "og:u:f:p:d" OPT; do
    case $OPT in
        o) OVERWRITE=1 ;;
        g) CLI_GH_USER="$OPTARG" ;;
        u) CLI_KEY_URL="$OPTARG" ;;
        f) CLI_KEY_FILE="$OPTARG" ;;
        p) CLI_PORT="$OPTARG" ;;
        d) CLI_DISABLE_PWD=1 ;;
        *) exit 1 ;;
    esac
done

# -o 必須配合公鑰來源使用，否則會誤清空 authorized_keys
if [ "$OVERWRITE" -eq 1 ] && [ -z "$CLI_GH_USER" ] && [ -z "$CLI_KEY_URL" ] && [ -z "$CLI_KEY_FILE" ]; then
    echo -e "${ERROR} -o（覆蓋模式）必須與 -g、-u 或 -f 一起使用！"
    echo -e "${YELLOW}單獨執行 -o 會清空 authorized_keys 中所有公鑰，已阻止。${RESET}"
    exit 1
fi

# 有任意 CLI 參數就進入批次執行模式
if [ -n "$CLI_GH_USER" ] || [ -n "$CLI_KEY_URL" ] || [ -n "$CLI_KEY_FILE" ] || \
   [ -n "$CLI_PORT" ] || [ "$CLI_DISABLE_PWD" -eq 1 ]; then

    need_restart_sshd=0
    need_restart_f2b=0

    if [ -n "$CLI_GH_USER" ] || [ -n "$CLI_KEY_URL" ] || [ -n "$CLI_KEY_FILE" ]; then
        init_ssh_dir
        [ "$OVERWRITE" == "1" ] && > "${HOME}/.ssh/authorized_keys"
    fi

    # 1. 匯入公鑰
    if [ -n "$CLI_GH_USER" ]; then
        PUB_KEY=$(curl -fsSL "https://github.com/${CLI_GH_USER}.keys")
        [ -z "$PUB_KEY" ] && echo -e "${ERROR} 取得 GitHub 公鑰失敗" && exit 1
        append_key_with_meta "$PUB_KEY" "GitHub: ${CLI_GH_USER}"
        set_sshd_config "PubkeyAuthentication" "yes"
        need_restart_sshd=1
    fi

    if [ -n "$CLI_KEY_URL" ]; then
        PUB_KEY=$(curl -fsSL "${CLI_KEY_URL}")
        [ -z "$PUB_KEY" ] && echo -e "${ERROR} 從 URL 取得公鑰失敗" && exit 1
        append_key_with_meta "$PUB_KEY" "自訂URL"
        set_sshd_config "PubkeyAuthentication" "yes"
        need_restart_sshd=1
    fi

    if [ -n "$CLI_KEY_FILE" ]; then
        if [ -f "${CLI_KEY_FILE}" ]; then
            PUB_KEY=$(cat "${CLI_KEY_FILE}")
            append_key_with_meta "$PUB_KEY" "本地檔案匯入"
            set_sshd_config "PubkeyAuthentication" "yes"
            need_restart_sshd=1
        else
            echo -e "${ERROR} 找不到公鑰檔案 ${CLI_KEY_FILE}" && exit 1
        fi
    fi

    # 2. 修改連接埠
    if [ -n "$CLI_PORT" ]; then
        if [[ ! "$CLI_PORT" =~ ^[0-9]+$ ]] || [ "$CLI_PORT" -lt 1 ] || [ "$CLI_PORT" -gt 65535 ]; then
            echo -e "${ERROR} 連接埠格式不正確！" && exit 1
        fi

        if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then
            echo -e "${INFO} 偵測到 SELinux 啟用，正在申請放行連接埠 ${CLI_PORT}..."
            if command -v semanage &>/dev/null; then
                $SUDO semanage port -a -t ssh_port_t -p tcp "$CLI_PORT" 2>/dev/null || \
                $SUDO semanage port -m -t ssh_port_t -p tcp "$CLI_PORT" 2>/dev/null
            else
                echo -e "${WARN} 未安裝 semanage，如使用 RHEL/CentOS 繫系統，可能需要手動配置 SELinux。"
            fi
        fi

        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            echo -e "${INFO} 正在向 ufw 防火牆放行連接埠 ${CLI_PORT}/tcp..."
            $SUDO ufw allow "$CLI_PORT"/tcp >/dev/null
        elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
            echo -e "${INFO} 正在向 firewalld 防火牆放行連接埠 ${CLI_PORT}/tcp..."
            $SUDO firewall-cmd --permanent --add-port="${CLI_PORT}/tcp" >/dev/null
            $SUDO firewall-cmd --reload >/dev/null
        fi

        # 先刪除主檔案裡的舊 Port（避免同時監聽多個連接埠）
        $SUDO sed -i -E '/^[[:space:]]*Port[[:space:]=]/d' /etc/ssh/sshd_config
        set_sshd_config "Port" "$CLI_PORT"
        need_restart_sshd=1

        if [ -f "$JAIL_CONF" ] && grep -q "^\[${TARGET_JAIL}\]" "$JAIL_CONF"; then
            set_f2b_conf "port" "$CLI_PORT"
            need_restart_f2b=1
        fi
    fi

    # 3. 禁用密碼登入（危險檢查）
    if [ "$CLI_DISABLE_PWD" -eq 1 ]; then
        if ! has_valid_pubkey || \
           [[ "$(get_sshd_config_val "PubkeyAuthentication" "yes")" != "yes" ]]; then
            echo -e "${ERROR} 金鑰登入不可用（未啟用或無公鑰），禁用密碼登入將導致你無法登入！"
            read -rp "確認仍然執行？(y/N): " confirm
            [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
        fi
        set_sshd_config "PasswordAuthentication" "no"
        set_sshd_config "ChallengeResponseAuthentication" "no"
        set_sshd_config "KbdInteractiveAuthentication" "no"
        need_restart_sshd=1
    fi

    # 統一重啟 SSH 服務
    if [ "$need_restart_sshd" -eq 1 ]; then
        if restart_sshd; then
            if [ -n "$CLI_PORT" ]; then
                if command -v ss &>/dev/null; then
                    echo -e "${INFO} 系統實際監聽服務連接埠狀態："
                    ss -tulpn | grep ssh || true
                fi
                echo -e "${WARN} 注意：如使用的是阿里雲/騰訊雲/AWS等，請務必在【雲伺服器安全組】中開放 TCP ${CLI_PORT} 連接埠！"
            fi
        fi
    fi

    # 同步重啟 Fail2Ban
    if [ "$need_restart_f2b" -eq 1 ]; then
        if command -v fail2ban-client &>/dev/null && fail2ban-client ping >/dev/null 2>&1; then
            echo -e "${INFO} 正在同步更新 Fail2Ban 防護連接埠..."
            restart_f2b
        fi
    fi

    exit 0
fi

# ============ 互動式主選單 ============
while true; do
    clear
    show_status
    echo -e " ${GREEN}1.${RESET} 金鑰登入管理"
    echo -e " ${GREEN}2.${RESET} 密碼登入開關"
    echo -e " ${GREEN}3.${RESET} Fail2Ban防護"
    echo -e " ${GREEN}4.${RESET} SSH 連接埠修改"
    echo -e " ${GREEN}0.${RESET} 退出腳本"
    echo -e "${CYAN}============================================================${RESET}"
    read -rp "請輸入選項 [0-4]: " choice

    case "$choice" in
        1) install_key_menu ;;
        2) toggle_password_login ;;
        3) manage_fail2ban_menu ;;
        4) change_ssh_port ;;
        0) echo -e "\n感謝使用！"; exit 0 ;;
        *) echo -e "${ERROR} 無效選項，請重新選擇！"; sleep 1 ;;
    esac
done