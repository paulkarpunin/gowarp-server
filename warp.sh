#!/bin/bash
set -o pipefail

# ══════════════════════════════════════════════════════════════
#  WARP Manager v1.1 — Unified 3X-UI + AmneziaWG
#  Cloudflare WARP · Telegram Bot · Auto-detect mode
# ══════════════════════════════════════════════════════════════

WARP_VERSION="1.1"
SCRIPT_URL="https://raw.githubusercontent.com/paulkarpunin/gowarp-server/main/warp.sh"
WARP_DIR="/etc/warp-manager"
WARP_CONF="$WARP_DIR/config"
WARP_LOG="/var/log/warp-manager.log"
BOT_PID_FILE="/var/run/warp_bot.pid"
DEFAULT_PORT=40000

WGCF_VERSION="2.2.30"
WGCF_BIN="/root/wgcf"
WGCF_ACCOUNT="/root/wgcf-account.toml"
WGCF_PROFILE="/root/wgcf-profile.conf"

AWG_WARP_DIR="/opt/warp"
AWG_WARP_CONF="$AWG_WARP_DIR/warp.conf"
AWG_WARP_CLIENTS="$AWG_WARP_DIR/clients.list"
AWG_MARKER_BEGIN="# --- WARP-MANAGER BEGIN ---"
AWG_MARKER_END="# --- WARP-MANAGER END ---"


RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'
BLUE='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'

SOCKS_PORT=""
MY_IP=""
BOT_TOKEN=""
BOT_CHAT_ID=""
MODE=""

CONTAINER=""
AWG_VPN_CONF=""
AWG_VPN_IF=""
AWG_VPN_QUICK_CMD=""
AWG_CLIENTS_TABLE=""
AWG_START_SH=""
AWG_SUBNET=""
AWG_WARP_EXIT_IP=""
declare -a AWG_SELECTED_IPS=()
declare -a AWG_CLIENT_IPS=()
declare -A AWG_CLIENT_NAMES=()

# ═══════════════════════════════════════════════════════════════
#  CONFIG
# ═══════════════════════════════════════════════════════════════

init_config() {
    mkdir -p "$WARP_DIR"
    if [ ! -f "$WARP_CONF" ]; then
        cat > "$WARP_CONF" <<'CONF'
SOCKS_PORT="40000"
BOT_TOKEN=""
BOT_CHAT_ID=""
MODE=""
CONTAINER=""
CONF
    fi
    source "$WARP_CONF"
    SOCKS_PORT="${SOCKS_PORT:-$DEFAULT_PORT}"
}

save_config_val() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$WARP_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$WARP_CONF"
    else
        echo "${key}=\"${value}\"" >> "$WARP_CONF"
    fi
    source "$WARP_CONF"
}

# ═══════════════════════════════════════════════════════════════
#  MODE DETECTION
# ═══════════════════════════════════════════════════════════════

has_3xui_mode() { [[ "$MODE" == "3xui" || "$MODE" == "both" ]]; }
has_awg_mode()  { [[ "$MODE" == "amnezia" || "$MODE" == "both" ]]; }

detect_mode() {
    source "$WARP_CONF" 2>/dev/null
    if [ -n "${MODE:-}" ] && [[ "$MODE" == "3xui" || "$MODE" == "amnezia" || "$MODE" == "both" ]]; then
        return 0
    fi

    local has_docker=0 has_amnezia=0 has_3xui=0
    command -v docker &>/dev/null && has_docker=1
    if [ "$has_docker" -eq 1 ]; then
        local awg_ct
        awg_ct=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^amnezia-awg2$|^amnezia-awg$' | head -1)
        [ -z "$awg_ct" ] && awg_ct=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "amnezia" | head -1)
        [ -n "$awg_ct" ] && has_amnezia=1
    fi
    systemctl is-active x-ui &>/dev/null 2>&1 && has_3xui=1
    [ "$has_3xui" -eq 0 ] && command -v x-ui &>/dev/null && has_3xui=1

    if [ "$has_amnezia" -eq 1 ] && [ "$has_3xui" -eq 1 ]; then
        MODE="both"
    elif [ "$has_amnezia" -eq 1 ]; then
        MODE="amnezia"
    elif [ "$has_3xui" -eq 1 ]; then
        MODE="3xui"
    else
        echo -e "\n${YELLOW}Не обнаружено ни 3X-UI, ни AmneziaWG Docker.${NC}"
        echo -e "  ${GREEN}1)${NC} 3X-UI (SOCKS5-прокси для Xray)"
        echo -e "  ${GREEN}2)${NC} AmneziaWG (Docker WireGuard)"
        echo -e "  ${GREEN}3)${NC} Оба режима"
        while true; do
            read -p "Выберите режим (1/2/3): " choice
            case "$choice" in
                1) MODE="3xui"; break ;;
                2) MODE="amnezia"; break ;;
                3) MODE="both"; break ;;
            esac
        done
    fi

    save_config_val "MODE" "$MODE"
}


# ═══════════════════════════════════════════════════════════════
#  LOGGING / SYSTEM
# ═══════════════════════════════════════════════════════════════

log_action() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WARP_LOG"; }

check_root() {
    [ "$EUID" -ne 0 ] && { echo -e "${RED}[ERROR] Запустите от root!${NC}"; exit 1; }
}

check_deps() {
    for cmd in jq curl; do
        if ! command -v "$cmd" &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y > /dev/null 2>&1
            apt-get install -y jq curl > /dev/null 2>&1
            break
        fi
    done
}

get_my_ip() {
    MY_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "N/A")
}

get_system_stats() {
    local cpu_line load_avg mem_info disk_info uptime_str cpu_usage
    cpu_line=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "?")
    load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    mem_info=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d/%dMB (%.1f%%)", $3, $2, $3/$2*100}')
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')
    uptime_str=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*load.*//')
    cpu_usage=$(awk '/^cpu / {u=$2+$4; t=$2+$3+$4+$5+$6+$7+$8; if(t>0) printf "%.1f", u/t*100; else print "0"}' /proc/stat 2>/dev/null)
    local r=""
    r+="<b>📊 Системная информация</b>\n\n"
    r+="<b>Uptime:</b> ${uptime_str}\n"
    r+="<b>CPU:</b> ${cpu_line} ядер | ${cpu_usage}%\n"
    r+="<b>Load:</b> ${load_avg}\n"
    r+="<b>RAM:</b> ${mem_info}\n"
    r+="<b>Disk /:</b> ${disk_info}\n"
    echo "$r"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release; OS_ID="$ID"; OS_VERSION="$VERSION_ID"; OS_CODENAME="$VERSION_CODENAME"
    else
        OS_ID="unknown"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  3X-UI BACKEND — WARP via warp-cli (SOCKS5)
# ═══════════════════════════════════════════════════════════════

is_warp_installed_3xui() { command -v warp-cli &>/dev/null; }

is_warp_running_3xui() {
    local st; st=$(warp-cli --accept-tos status 2>/dev/null)
    echo "$st" | grep -qi "status.*connected" && ! echo "$st" | grep -qi "disconnected"
}

get_warp_status_3xui() {
    if ! is_warp_installed_3xui; then echo "Не установлен"; return; fi
    local s; s=$(warp-cli --accept-tos status 2>/dev/null | head -5)
    if echo "$s" | grep -qi "disconnected"; then echo "Отключён"
    elif echo "$s" | grep -qi "connected"; then echo "Подключён"
    elif echo "$s" | grep -qi "registration missing"; then echo "Нет регистрации"
    else echo "Неизвестно"; fi
}

get_warp_ip_3xui() {
    curl -s4 --max-time 5 --proxy socks5h://127.0.0.1:${SOCKS_PORT} ifconfig.me 2>/dev/null || echo "N/A"
}

install_warp_3xui() {
    clear; echo -e "\n${CYAN}━━━ Установка Cloudflare WARP (3X-UI) ━━━${NC}\n"
    if is_warp_installed_3xui; then
        echo -e "${YELLOW}WARP уже установлен.${NC}"; read -p "Enter..."; return
    fi
    detect_os
    if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
        echo -e "${RED}Поддерживаются только Ubuntu и Debian (ваша: ${OS_ID}).${NC}"; read -p "Enter..."; return
    fi
    echo -e "${YELLOW}[1/6]${NC} GPG-ключ Cloudflare..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null \
        || { echo -e "${RED}Ошибка GPG.${NC}"; read -p "Enter..."; return; }
    echo -e "${GREEN}  ✓${NC}"

    echo -e "${YELLOW}[2/6]${NC} Репозиторий..."
    local codename="${OS_CODENAME:-$(lsb_release -cs 2>/dev/null || echo focal)}"
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
    echo -e "${GREEN}  ✓ (${codename})${NC}"

    echo -e "${YELLOW}[3/6]${NC} Установка cloudflare-warp..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y > /dev/null 2>&1; apt-get install -y cloudflare-warp > /dev/null 2>&1
    command -v warp-cli &>/dev/null || { echo -e "${RED}Не удалось установить.${NC}"; read -p "Enter..."; return; }
    echo -e "${GREEN}  ✓${NC}"

    echo -e "${YELLOW}[4/6]${NC} Регистрация..."
    warp-cli --accept-tos registration new > /dev/null 2>&1 || { echo -e "${RED}Ошибка регистрации.${NC}"; read -p "Enter..."; return; }
    echo -e "${GREEN}  ✓${NC}"

    echo -e "${YELLOW}[5/6]${NC} SOCKS5-прокси..."
    warp-cli --accept-tos mode proxy > /dev/null 2>&1
    warp-cli --accept-tos proxy port "${SOCKS_PORT}" > /dev/null 2>&1
    echo -e "${GREEN}  ✓ 127.0.0.1:${SOCKS_PORT}${NC}"

    echo -e "${YELLOW}[6/6]${NC} Подключение..."
    warp-cli --accept-tos connect > /dev/null 2>&1; sleep 3
    if is_warp_running_3xui; then
        local wip; wip=$(get_warp_ip_3xui)
        echo -e "${GREEN}  ✓ WARP IP: ${wip}${NC}"
        log_action "3XUI INSTALL: port=${SOCKS_PORT}, warp_ip=${wip}"
    else
        echo -e "${YELLOW}  ⚠ Подключение не подтверждено.${NC}"
    fi
    echo -e "\n${WHITE}Настройка 3X-UI: п.${YELLOW}6${WHITE} (JSON, инструкция, порт)${NC}"
    read -p "Enter..."
}

start_warp_3xui() {
    is_warp_installed_3xui || { echo -e "\n${RED}WARP не установлен.${NC}"; read -p "Enter..."; return; }
    is_warp_running_3xui && { echo -e "\n${YELLOW}Уже подключён.${NC}"; read -p "Enter..."; return; }
    echo -e "\n${YELLOW}Подключение...${NC}"
    warp-cli --accept-tos connect > /dev/null 2>&1; sleep 3
    if is_warp_running_3xui; then
        echo -e "${GREEN}[OK] Подключён.${NC}"; log_action "3XUI START"
    else
        echo -e "${RED}Ошибка подключения.${NC}"
    fi
    read -p "Enter..."
}

stop_warp_3xui() {
    is_warp_installed_3xui || { echo -e "\n${RED}WARP не установлен.${NC}"; read -p "Enter..."; return; }
    is_warp_running_3xui || { echo -e "\n${YELLOW}Уже отключён.${NC}"; read -p "Enter..."; return; }
    warp-cli --accept-tos disconnect > /dev/null 2>&1
    echo -e "${GREEN}[OK] Отключён.${NC}"; log_action "3XUI STOP"
    read -p "Enter..."
}

rekey_warp_3xui() {
    is_warp_installed_3xui || { echo -e "\n${RED}WARP не установлен.${NC}"; read -p "Enter..."; return; }
    echo -e "\n${CYAN}━━━ Перевыпуск ключа WARP ━━━${NC}\n"
    read -p "Продолжить? (y/n): " c; [[ "$c" != "y" ]] && return
    echo -e "${YELLOW}[1/4]${NC} Отключение..."; warp-cli --accept-tos disconnect > /dev/null 2>&1; echo -e "${GREEN}  ✓${NC}"
    echo -e "${YELLOW}[2/4]${NC} Удаление регистрации..."; warp-cli --accept-tos registration delete > /dev/null 2>&1; echo -e "${GREEN}  ✓${NC}"
    echo -e "${YELLOW}[3/4]${NC} Новая регистрация..."; warp-cli --accept-tos registration new > /dev/null 2>&1 || { echo -e "${RED}Ошибка.${NC}"; read -p "Enter..."; return; }; echo -e "${GREEN}  ✓${NC}"
    echo -e "${YELLOW}[4/4]${NC} Подключение..."
    warp-cli --accept-tos mode proxy > /dev/null 2>&1; warp-cli --accept-tos proxy port "${SOCKS_PORT}" > /dev/null 2>&1
    warp-cli --accept-tos connect > /dev/null 2>&1; sleep 3
    if is_warp_running_3xui; then
        local wip; wip=$(get_warp_ip_3xui)
        echo -e "${GREEN}  ✓ Новый WARP IP: ${wip}${NC}"; log_action "3XUI REKEY: warp_ip=${wip}"
    else echo -e "${YELLOW}  ⚠ Подключение не подтверждено.${NC}"; fi
    read -p "Enter..."
}

change_port_3xui() {
    is_warp_installed_3xui || { echo -e "\n${RED}WARP не установлен.${NC}"; read -p "Enter..."; return; }
    echo -e "\n${CYAN}━━━ Изменение порта ━━━${NC}\n"
    echo -e "${WHITE}Текущий: ${GREEN}${SOCKS_PORT}${NC}\n"
    local np
    while true; do
        read -p "Новый порт (1024-65535): " np
        [[ "$np" =~ ^[0-9]+$ ]] && (( np >= 1024 && np <= 65535 )) && break
        echo -e "${RED}Ошибка.${NC}"
    done
    warp-cli --accept-tos proxy port "$np" > /dev/null 2>&1
    save_config_val "SOCKS_PORT" "$np"; SOCKS_PORT="$np"
    echo -e "\n${GREEN}[OK] Порт: ${np}${NC}\n${YELLOW}Обновите порт в 3X-UI!${NC}"
    log_action "3XUI PORT: ${np}"; read -p "Enter..."
}

show_3xui_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Настройки SOCKS5 для 3X-UI ━━━${NC}\n"
        echo -e "  ${WHITE}SOCKS5-прокси:${NC} ${GREEN}127.0.0.1:${SOCKS_PORT}${NC}"
        if is_warp_running_3xui; then
            echo -e "  ${WHITE}WARP IP:${NC}       ${GREEN}$(get_warp_ip_3xui)${NC}"
        fi
        echo -e "\n  1) 📋 Показать JSON Outbound и Routing"
        echo -e "  2) 📖 Пошаговая инструкция для 3X-UI"
        echo -e "  3) 🔧 Изменить порт SOCKS5 (сейчас: ${SOCKS_PORT})"
        echo -e "  0) ⬅️  Назад"
        echo ""
        read -p "  Выбор: " ch
        case $ch in
            1) show_3xui_json ;;
            2) show_3xui_guide ;;
            3) change_port_3xui ;;
            0) return ;;
        esac
    done
}

show_3xui_json() {
    clear; echo -e "\n${CYAN}━━━ JSON для 3X-UI ━━━${NC}\n"
    echo -e "${WHITE}Добавьте в ${YELLOW}Xray Settings → Outbounds${WHITE} (JSON):${NC}\n"
    echo -e "${GREEN}── 1. Outbound (добавить в массив outbounds) ──${NC}\n"
    cat <<EOF
{
  "tag": "warp",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": ${SOCKS_PORT}
      }
    ]
  }
}
EOF

    echo -e "\n${GREEN}── 2. Routing Rule (маршруты через WARP) ──${NC}\n"
    echo -e "${WHITE}Только определённые сайты через WARP:${NC}\n"
    cat <<EOF
{
  "outboundTag": "warp",
  "domain": [
    "geosite:openai",
    "geosite:netflix",
    "geosite:disney",
    "geosite:spotify",
    "domain:chat.openai.com",
    "domain:claude.ai"
  ]
}
EOF

    echo -e "\n${WHITE}Весь трафик через WARP:${NC}\n"
    cat <<EOF
{
  "outboundTag": "warp",
  "network": "tcp,udp"
}
EOF

    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}SOCKS5:${NC}  ${GREEN}127.0.0.1:${SOCKS_PORT}${NC}"
    if is_warp_running_3xui; then
        echo -e "  ${WHITE}WARP IP:${NC} ${GREEN}$(get_warp_ip_3xui)${NC}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""; read -p "Enter..."
}

show_3xui_guide() {
    clear; echo -e "\n${CYAN}━━━ Пошаговая настройка 3X-UI ━━━${NC}\n"

    echo -e "${YELLOW}═══ ДОБАВЛЕНИЕ OUTBOUND ═══${NC}\n"
    echo -e "${YELLOW}Шаг 1.${NC} Откройте панель 3X-UI в браузере"
    echo -e "${YELLOW}Шаг 2.${NC} Перейдите в ${WHITE}Настройки Xray${NC} → ${WHITE}Outbounds${NC}"
    echo -e "${YELLOW}Шаг 3.${NC} Нажмите ${GREEN}+ Добавить Outbound${NC}"
    echo -e "${YELLOW}Шаг 4.${NC} Заполните поля в форме:"
    echo -e ""
    echo -e "  ${WHITE}Тег (Tag):${NC}      ${GREEN}warp${NC}"
    echo -e "  ${WHITE}Протокол:${NC}       ${GREEN}SOCKS${NC}"
    echo -e "  ${WHITE}Адрес сервера:${NC}  ${GREEN}127.0.0.1${NC}"
    echo -e "  ${WHITE}Порт:${NC}           ${GREEN}${SOCKS_PORT}${NC}"
    echo -e ""
    echo -e "  ${DIM}Если панель требует JSON, вставьте в редактор:${NC}"
    echo -e "  ${CYAN}(пункт 1 основного подменю показывает полный JSON)${NC}"
    echo -e ""

    echo -e "${YELLOW}═══ МАРШРУТИЗАЦИЯ (по желанию) ═══${NC}\n"
    echo -e "  ${DIM}По умолчанию WARP не используется пока нет маршрутизации.${NC}"
    echo -e "  ${DIM}Добавьте правило, чтобы указать какие сайты идут через WARP:${NC}\n"
    echo -e "${YELLOW}Шаг 5.${NC} Перейдите в ${WHITE}Настройки Xray${NC} → ${WHITE}Routing Rules${NC}"
    echo -e "${YELLOW}Шаг 6.${NC} Нажмите ${GREEN}+ Добавить правило${NC}"
    echo -e "${YELLOW}Шаг 7.${NC} Заполните:"
    echo -e ""
    echo -e "  ${WHITE}Outbound Tag:${NC}   ${GREEN}warp${NC}"
    echo -e "  ${WHITE}Domain:${NC}"
    echo -e "    ${GREEN}geosite:openai${NC}"
    echo -e "    ${GREEN}geosite:netflix${NC}"
    echo -e "    ${GREEN}geosite:disney${NC}"
    echo -e "    ${GREEN}geosite:spotify${NC}"
    echo -e "    ${GREEN}domain:chat.openai.com${NC}"
    echo -e "    ${GREEN}domain:claude.ai${NC}"
    echo -e ""
    echo -e "  ${DIM}Каждый домен на отдельной строке.${NC}"
    echo -e "  ${DIM}Можно добавить свои домены или использовать network: tcp,udp для всего трафика.${NC}"
    echo -e ""

    echo -e "${YELLOW}═══ ПРИМЕНЕНИЕ ═══${NC}\n"
    echo -e "${YELLOW}Шаг 8.${NC} Нажмите ${WHITE}Сохранить${NC}"
    echo -e "${YELLOW}Шаг 9.${NC} Нажмите ${WHITE}Перезапустить Xray${NC} (или в SSH: ${GREEN}x-ui restart${NC})"
    echo -e ""

    echo -e "${YELLOW}═══ ПРОВЕРКА ═══${NC}\n"
    echo -e "  1. Подключитесь к VPN через клиент"
    echo -e "  2. Откройте ${CYAN}https://whoer.net${NC} или ${CYAN}https://ifconfig.me${NC}"
    echo -e "  3. Сайты из списка → ${GREEN}IP Cloudflare${NC}"
    echo -e "     Остальные сайты → ${WHITE}IP вашего сервера${NC}"
    echo -e ""
    echo -e "  ${WHITE}Проверка через SSH:${NC}"
    echo -e "  ${GREEN}curl -s --proxy socks5h://127.0.0.1:${SOCKS_PORT} ifconfig.me${NC}"
    echo ""; read -p "Enter..."
}

show_status_3xui() {
    clear; echo -e "\n${CYAN}━━━ Статус WARP (3X-UI) ━━━${NC}\n"
    if ! is_warp_installed_3xui; then
        echo -e "  ${RED}Не установлен.${NC} Установите через п.1."; echo ""; read -p "Enter..."; return
    fi
    local st; st=$(get_warp_status_3xui)
    local sc="$RED"; [[ "$st" == "Подключён" ]] && sc="$GREEN"; [[ "$st" == "Отключён" ]] && sc="$YELLOW"
    echo -e "  ${WHITE}Статус:      ${sc}${st}${NC}"
    echo -e "  ${WHITE}Реальный IP: ${GREEN}${MY_IP}${NC}"
    is_warp_running_3xui && echo -e "  ${WHITE}WARP IP:     ${GREEN}$(get_warp_ip_3xui)${NC}"

    echo -e "\n${CYAN}── Настройки SOCKS5-прокси ──${NC}\n"
    echo -e "  ${WHITE}Адрес:${NC}  ${GREEN}127.0.0.1${NC}"
    echo -e "  ${WHITE}Порт:${NC}   ${GREEN}${SOCKS_PORT}${NC}"
    echo -e "  ${WHITE}Прокси:${NC} ${CYAN}socks5h://127.0.0.1:${SOCKS_PORT}${NC}"

    echo -e "\n${CYAN}── JSON Outbound для 3X-UI (скопируйте в панель) ──${NC}\n"
    echo -e "${GREEN}"
    cat <<EOF
{
  "tag": "warp",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": ${SOCKS_PORT}
      }
    ]
  }
}
EOF
    echo -e "${NC}"

    echo -e "${CYAN}── warp-cli status ──${NC}"
    warp-cli --accept-tos status 2>/dev/null | while IFS= read -r l; do echo -e "  ${WHITE}$l${NC}"; done
    echo ""; read -p "Enter..."
}

uninstall_3xui() {
    echo -e "\n${YELLOW}Удаление WARP (3X-UI)...${NC}\n"
    systemctl stop warp-bot 2>/dev/null; systemctl disable warp-bot 2>/dev/null
    rm -f /etc/systemd/system/warp-bot.service; systemctl daemon-reload 2>/dev/null
    [ -f "$BOT_PID_FILE" ] && { kill "$(cat "$BOT_PID_FILE")" 2>/dev/null; rm -f "$BOT_PID_FILE"; }
    echo -e "  ${GREEN}✓${NC}  Бот остановлен"
    warp-cli --accept-tos disconnect > /dev/null 2>&1; echo -e "  ${GREEN}✓${NC}  WARP отключён"
    warp-cli --accept-tos registration delete > /dev/null 2>&1; echo -e "  ${GREEN}✓${NC}  Регистрация удалена"
    apt-get remove -y cloudflare-warp > /dev/null 2>&1; apt-get autoremove -y > /dev/null 2>&1; echo -e "  ${GREEN}✓${NC}  Пакет удалён"
    rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo -e "  ${GREEN}✓${NC}  Репозиторий удалён"
}

# ═══════════════════════════════════════════════════════════════
#  AMNEZIA BACKEND — WARP via wgcf (WireGuard inside Docker)
# ═══════════════════════════════════════════════════════════════

awg_pick_container() {
    if [ -n "${CONTAINER:-}" ]; then
        docker exec "$CONTAINER" sh -c "true" 2>/dev/null && return 0
        CONTAINER=""
    fi

    local -a containers=()
    mapfile -t containers < <(docker ps --format '{{.Names}}' | grep -E '^amnezia-awg2$|^amnezia-awg$' 2>/dev/null || true)

    if [ ${#containers[@]} -eq 0 ]; then
        mapfile -t containers < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "amnezia" || true)
    fi

    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "${RED}Контейнеры amnezia-awg / amnezia-awg2 не найдены.${NC}"
        echo -e "${WHITE}Убедитесь, что AmneziaWG запущен через Docker.${NC}"
        return 1
    elif [ ${#containers[@]} -eq 1 ]; then
        CONTAINER="${containers[0]}"
    else
        echo -e "\n${CYAN}Доступные контейнеры:${NC}"
        local i=1
        for c in "${containers[@]}"; do echo -e "  ${GREEN}$i)${NC} $c"; ((i++)); done
        echo -e "  ${DIM}0) Отмена${NC}"
        while true; do
            read -p "Выберите контейнер: " ch
            [ "$ch" = "0" ] && return 1
            [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#containers[@]} )) && { CONTAINER="${containers[$((ch-1))]}"; break; }
        done
    fi
    save_config_val "CONTAINER" "$CONTAINER"
    return 0
}

awg_load_container_data() {
    if [ "$CONTAINER" = "amnezia-awg2" ]; then
        AWG_VPN_CONF="/opt/amnezia/awg/awg0.conf"
        AWG_VPN_IF="awg0"
        AWG_VPN_QUICK_CMD="awg-quick"
    else
        AWG_VPN_CONF="/opt/amnezia/awg/wg0.conf"
        AWG_VPN_IF="wg0"
        AWG_VPN_QUICK_CMD="wg-quick"
    fi

    AWG_CLIENTS_TABLE="/opt/amnezia/awg/clientsTable"
    AWG_START_SH="/opt/amnezia/start.sh"

    docker exec "$CONTAINER" sh -c "[ -f '$AWG_VPN_CONF' ]" 2>/dev/null || {
        for f in /opt/amnezia/awg/wg0.conf /opt/amnezia/awg/awg0.conf /etc/wireguard/wg0.conf; do
            if docker exec "$CONTAINER" sh -c "[ -f '$f' ]" 2>/dev/null; then
                AWG_VPN_CONF="$f"
                break
            fi
        done
    }

    docker exec "$CONTAINER" sh -c "[ -f '$AWG_VPN_CONF' ]" 2>/dev/null || {
        echo -e "${RED}Не найден конфиг VPN в контейнере: $AWG_VPN_CONF${NC}"
        return 1
    }

    AWG_SUBNET=$(docker exec "$CONTAINER" sh -c "sed -n 's/^Address = \(.*\)$/\1/p' '$AWG_VPN_CONF' | head -n1 | cut -d',' -f1" 2>/dev/null | tr -d '\r')
    return 0
}

awg_detect_warp_exit_ip() {
    AWG_WARP_EXIT_IP=""
    if docker exec "$CONTAINER" sh -c "ip addr show warp >/dev/null 2>&1" 2>/dev/null; then
        AWG_WARP_EXIT_IP=$(docker exec "$CONTAINER" sh -c \
            "curl -s --interface warp --connect-timeout 3 https://ifconfig.me 2>/dev/null || true" | tr -d '\r\n')
    fi
}

is_warp_installed_awg() {
    docker exec "$CONTAINER" sh -c "[ -f '$AWG_WARP_CONF' ]" 2>/dev/null
}

is_warp_running_awg() {
    docker exec "$CONTAINER" sh -c "ip addr show warp >/dev/null 2>&1" 2>/dev/null
}

get_warp_status_awg() {
    if ! is_warp_installed_awg; then echo "Не установлен"; return; fi
    is_warp_running_awg && echo "Подключён" || echo "Отключён"
}

awg_backup() {
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    docker exec "$CONTAINER" sh -c "
        [ -f '$AWG_VPN_CONF' ] && cp '$AWG_VPN_CONF' '${AWG_VPN_CONF}.bak-${ts}'
        [ -f '$AWG_CLIENTS_TABLE' ] && cp '$AWG_CLIENTS_TABLE' '${AWG_CLIENTS_TABLE}.bak-${ts}'
        [ -f '$AWG_START_SH' ] && cp '$AWG_START_SH' '${AWG_START_SH}.bak-${ts}'
        [ -f '$AWG_START_SH' ] && [ ! -f /opt/amnezia/start.sh.final-backup ] && cp '$AWG_START_SH' /opt/amnezia/start.sh.final-backup
    " >/dev/null 2>&1
    log_action "AWG BACKUP: $ts"
}

awg_install_wgcf() {
    if [ -x "$WGCF_BIN" ]; then return 0; fi
    local arch; arch=$(uname -m)
    local wa=""
    case "$arch" in
        x86_64) wa="amd64" ;; aarch64) wa="arm64" ;; armv7l) wa="armv7" ;;
        *) echo -e "${RED}Архитектура не поддерживается: $arch${NC}"; return 1 ;;
    esac
    wget -q -O "$WGCF_BIN" "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wa}" \
        || { echo -e "${RED}Не удалось скачать wgcf.${NC}"; return 1; }
    chmod +x "$WGCF_BIN"
}

awg_ensure_account() {
    if [ ! -f "$WGCF_ACCOUNT" ]; then
        echo -e "${YELLOW}Регистрация WARP через wgcf...${NC}"
        (cd /root && yes | ./wgcf register 2>/dev/null)
    fi
    [ -f "$WGCF_ACCOUNT" ] || { echo -e "${RED}Не создан $WGCF_ACCOUNT${NC}"; return 1; }
}

awg_generate_profile() {
    (cd /root && yes | ./wgcf generate 2>/dev/null)
    [ -f "$WGCF_PROFILE" ] || { echo -e "${RED}Не создан профиль.${NC}"; return 1; }
}

awg_resolve_endpoint() {
    local ep; ep=$(getent ahostsv4 engage.cloudflareclient.com 2>/dev/null | awk 'NR==1{print $1}')
    [ -z "$ep" ] && { echo -e "${RED}Не удалось определить IP endpoint.${NC}"; return 1; }
    echo "$ep"
}

awg_build_warp_conf() {
    local endpoint_ip="$1"
    local pk pub addr
    pk=$(awk -F' = ' '/^PrivateKey = /{print $2}' "$WGCF_PROFILE")
    pub=$(awk -F' = ' '/^PublicKey = /{print $2}' "$WGCF_PROFILE")
    addr=$(awk -F' = ' '/^Address = /{print $2}' "$WGCF_PROFILE" | cut -d',' -f1)

    docker exec "$CONTAINER" sh -c "mkdir -p '$AWG_WARP_DIR'"
    docker cp "$WGCF_PROFILE" "${CONTAINER}:${AWG_WARP_DIR}/wgcf-profile.conf" 2>/dev/null
    docker exec "$CONTAINER" sh -c "cat > '$AWG_WARP_CONF' <<'WARPEOF'
[Interface]
PrivateKey = ${pk}
Address = ${addr}
MTU = 1280
Table = off

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0
Endpoint = ${endpoint_ip}:2408
PersistentKeepalive = 25
WARPEOF
chmod 600 '$AWG_WARP_CONF'"
}

awg_warp_up() {
    docker exec "$CONTAINER" sh -c "wg-quick down '$AWG_WARP_CONF' >/dev/null 2>&1 || true"
    docker exec "$CONTAINER" sh -c "wg-quick up '$AWG_WARP_CONF'" || { echo -e "${RED}wg-quick up не удался.${NC}"; return 1; }
    docker exec "$CONTAINER" sh -c "ip addr show warp >/dev/null 2>&1" || { echo -e "${RED}Интерфейс warp не поднялся.${NC}"; return 1; }
}

install_warp_awg() {
    clear; echo -e "\n${CYAN}━━━ Установка WARP (AmneziaWG) ━━━${NC}\n"
    if is_warp_installed_awg && is_warp_running_awg; then
        echo -e "${YELLOW}WARP уже установлен и работает.${NC}"; read -p "Enter..."; return
    fi
    if is_warp_installed_awg && ! is_warp_running_awg; then
        echo -e "${YELLOW}[*] WARP установлен, поднимаю интерфейс...${NC}"
        awg_warp_up && echo -e "${GREEN}  ✓ warp поднят${NC}" || echo -e "${RED}  Ошибка${NC}"
        read -p "Enter..."; return
    fi

    echo -e "${YELLOW}[1/7]${NC} Бэкап контейнера..."
    awg_backup; echo -e "${GREEN}  ✓${NC}"

    echo -e "${YELLOW}[2/7]${NC} Скачиваю wgcf..."
    awg_install_wgcf || { read -p "Enter..."; return; }; echo -e "${GREEN}  ✓${NC}"

    echo -e "${YELLOW}[3/7]${NC} Регистрация WARP..."
    awg_ensure_account || { read -p "Enter..."; return; }; echo -e "${GREEN}  ✓${NC}"

    echo -e "${YELLOW}[4/7]${NC} Генерация профиля..."
    awg_generate_profile || { read -p "Enter..."; return; }; echo -e "${GREEN}  ✓${NC}"

    echo -e "${YELLOW}[5/7]${NC} Определение endpoint..."
    local ep; ep=$(awg_resolve_endpoint) || { read -p "Enter..."; return; }; echo -e "${GREEN}  ✓ ${ep}${NC}"

    echo -e "${YELLOW}[6/7]${NC} Сборка warp.conf в контейнере..."
    awg_build_warp_conf "$ep"; echo -e "${GREEN}  ✓${NC}"

    echo -e "${YELLOW}[7/7]${NC} Поднимаю warp-интерфейс..."
    awg_warp_up || { read -p "Enter..."; return; }; echo -e "${GREEN}  ✓${NC}"

    awg_detect_warp_exit_ip
    [ -n "$AWG_WARP_EXIT_IP" ] && echo -e "\n  ${WHITE}WARP IP: ${GREEN}${AWG_WARP_EXIT_IP}${NC}"
    echo -e "\n${GREEN}WARP установлен! Управление клиентами — п.6.${NC}"
    log_action "AWG INSTALL: endpoint=${ep}, warp_ip=${AWG_WARP_EXIT_IP}"
    read -p "Enter..."
}

start_warp_awg() {
    is_warp_installed_awg || { echo -e "\n${RED}WARP не установлен (п.1).${NC}"; read -p "Enter..."; return; }
    is_warp_running_awg && { echo -e "\n${YELLOW}Уже работает.${NC}"; read -p "Enter..."; return; }
    echo -e "\n${YELLOW}Поднимаю warp...${NC}"
    if awg_warp_up; then
        echo -e "${GREEN}[OK] WARP подключён.${NC}"; log_action "AWG START"
    else
        echo -e "${RED}Ошибка.${NC}"
    fi
    read -p "Enter..."
}

stop_warp_awg() {
    is_warp_running_awg || { echo -e "\n${YELLOW}Уже остановлен.${NC}"; read -p "Enter..."; return; }
    docker exec "$CONTAINER" sh -c "wg-quick down '$AWG_WARP_CONF' 2>/dev/null || true"
    echo -e "${GREEN}[OK] WARP остановлен.${NC}"; log_action "AWG STOP"
    read -p "Enter..."
}

rekey_warp_awg() {
    is_warp_installed_awg || { echo -e "\n${RED}WARP не установлен.${NC}"; read -p "Enter..."; return; }
    echo -e "\n${CYAN}━━━ Перевыпуск ключа WARP (AmneziaWG) ━━━${NC}\n"
    read -p "Продолжить? (y/n): " c; [[ "$c" != "y" ]] && return
    echo -e "${YELLOW}[1/5]${NC} Остановка warp..."; docker exec "$CONTAINER" sh -c "wg-quick down '$AWG_WARP_CONF' 2>/dev/null || true"; echo -e "${GREEN}  ✓${NC}"
    echo -e "${YELLOW}[2/5]${NC} Удаление аккаунта..."; rm -f "$WGCF_ACCOUNT"; echo -e "${GREEN}  ✓${NC}"
    echo -e "${YELLOW}[3/5]${NC} Новая регистрация..."; awg_ensure_account || { read -p "Enter..."; return; }; echo -e "${GREEN}  ✓${NC}"
    echo -e "${YELLOW}[4/5]${NC} Генерация профиля..."; awg_generate_profile || { read -p "Enter..."; return; }; echo -e "${GREEN}  ✓${NC}"
    echo -e "${YELLOW}[5/5]${NC} Пересборка и запуск..."
    local ep; ep=$(awg_resolve_endpoint) || { read -p "Enter..."; return; }
    awg_build_warp_conf "$ep"
    awg_warp_up || { read -p "Enter..."; return; }
    awg_apply_rules
    awg_patch_start_sh
    awg_detect_warp_exit_ip
    echo -e "${GREEN}  ✓ Готово!${NC}"
    [ -n "$AWG_WARP_EXIT_IP" ] && echo -e "  ${WHITE}Новый WARP IP: ${GREEN}${AWG_WARP_EXIT_IP}${NC}"
    log_action "AWG REKEY: warp_ip=${AWG_WARP_EXIT_IP}"
    read -p "Enter..."
}

show_status_awg() {
    clear; echo -e "\n${CYAN}━━━ Статус WARP (AmneziaWG) ━━━${NC}\n"
    echo -e "  ${WHITE}Контейнер: ${CYAN}${CONTAINER}${NC}"
    echo -e "  ${WHITE}Подсеть:   ${CYAN}${AWG_SUBNET:-N/A}${NC}"
    local st; st=$(get_warp_status_awg)
    local sc="$RED"; [[ "$st" == "Подключён" ]] && sc="$GREEN"; [[ "$st" == "Отключён" ]] && sc="$YELLOW"
    echo -e "  ${WHITE}WARP:      ${sc}${st}${NC}"
    echo -e "  ${WHITE}Реальный IP: ${GREEN}${MY_IP}${NC}"
    awg_detect_warp_exit_ip
    [ -n "$AWG_WARP_EXIT_IP" ] && echo -e "  ${WHITE}WARP IP:   ${GREEN}${AWG_WARP_EXIT_IP}${NC}"

    awg_load_clients
    echo -e "\n  ${WHITE}Клиентов в WARP: ${CYAN}${#AWG_SELECTED_IPS[@]}${NC}"
    if [ ${#AWG_SELECTED_IPS[@]} -gt 0 ]; then
        awg_parse_clients_table
        for ip in "${AWG_SELECTED_IPS[@]}"; do
            echo -e "    ${GREEN}●${NC} $(awg_format_label "$ip")"
        done
    fi

    if is_warp_running_awg; then
        echo -e "\n  ${CYAN}── wg show warp ──${NC}"
        docker exec "$CONTAINER" sh -c "wg show warp 2>/dev/null" | while IFS= read -r l; do echo -e "  ${WHITE}$l${NC}"; done
    fi
    echo ""; read -p "Enter..."
}

uninstall_awg() {
    echo -e "\n${YELLOW}Удаление WARP (AmneziaWG)...${NC}\n"
    systemctl stop warp-bot 2>/dev/null; systemctl disable warp-bot 2>/dev/null
    rm -f /etc/systemd/system/warp-bot.service; systemctl daemon-reload 2>/dev/null
    [ -f "$BOT_PID_FILE" ] && { kill "$(cat "$BOT_PID_FILE")" 2>/dev/null; rm -f "$BOT_PID_FILE"; }
    echo -e "  ${GREEN}✓${NC}  Бот остановлен"

    awg_cleanup_rules
    docker exec "$CONTAINER" sh -c "
        wg-quick down '$AWG_WARP_CONF' 2>/dev/null || true
        ip link del warp 2>/dev/null || true
        rm -rf '$AWG_WARP_DIR'
    " >/dev/null 2>&1
    echo -e "  ${GREEN}✓${NC}  WARP удалён из контейнера"

    awg_remove_from_start_sh
    if docker exec "$CONTAINER" sh -c '[ -f /opt/amnezia/start.sh.final-backup ]' 2>/dev/null; then
        docker exec "$CONTAINER" sh -c "
            cp /opt/amnezia/start.sh.final-backup '$AWG_START_SH' 2>/dev/null
            chmod +x '$AWG_START_SH' 2>/dev/null
            rm -f /opt/amnezia/start.sh.final-backup
        " 2>/dev/null
        echo -e "  ${GREEN}✓${NC}  start.sh восстановлен"
    fi

    rm -f "$WGCF_BIN" "$WGCF_ACCOUNT" "$WGCF_PROFILE"
    echo -e "  ${GREEN}✓${NC}  wgcf и профили удалены"
}

awg_restart_container() {
    echo -e "\n${YELLOW}Перезапуск контейнера ${CONTAINER}...${NC}"
    docker restart "$CONTAINER" >/dev/null
    local a=0
    while [ "$a" -lt 10 ]; do
        docker exec "$CONTAINER" sh -c "true" 2>/dev/null && { echo -e "${GREEN}[OK] Перезапущен.${NC}"; log_action "AWG RESTART"; read -p "Enter..."; return; }
        sleep 1; ((a++))
    done
    echo -e "${RED}Не удалось за 10с.${NC}"; read -p "Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  AMNEZIA CLIENT MANAGEMENT
# ═══════════════════════════════════════════════════════════════

awg_load_clients() {
    AWG_SELECTED_IPS=()
    local raw; raw=$(docker exec "$CONTAINER" sh -c "cat '$AWG_WARP_CLIENTS' 2>/dev/null || true" | tr -d '\r')
    if [ -n "$raw" ]; then
        while IFS= read -r line; do
            line=$(echo "$line" | xargs)
            [ -n "$line" ] && AWG_SELECTED_IPS+=("$line")
        done <<< "$raw"
    fi
}

awg_save_clients() {
    local content=""
    for ip in "${AWG_SELECTED_IPS[@]}"; do
        content="${content}${ip}"$'\n'
    done
    docker exec "$CONTAINER" sh -c "mkdir -p '$AWG_WARP_DIR' && cat > '$AWG_WARP_CLIENTS' <<'CLEOF'
${content}CLEOF
"
}

awg_parse_clients_table() {
    AWG_CLIENT_NAMES=()

    local raw
    raw=$(docker exec "$CONTAINER" sh -c "cat '$AWG_CLIENTS_TABLE' 2>/dev/null || true" | tr -d '\r')
    [ -z "$raw" ] && return 0

    declare -A key_to_name=()
    local id_name_pairs
    id_name_pairs=$(echo "$raw" | awk '
        /"clientId"/ {
            s = $0
            gsub(/.*"clientId"[[:space:]]*:[[:space:]]*"/, "", s)
            gsub(/".*/, "", s)
            cid = s
        }
        /"clientName"/ {
            s = $0
            gsub(/.*"clientName"[[:space:]]*:[[:space:]]*"/, "", s)
            gsub(/".*/, "", s)
            name = s
            if (cid != "" && name != "") {
                print cid "|" name
            }
        }')

    if [ -n "$id_name_pairs" ]; then
        while IFS='|' read -r cid name; do
            [ -n "$cid" ] && [ -n "$name" ] && key_to_name["$cid"]="$name"
        done <<< "$id_name_pairs"
    fi

    local conf_peers
    conf_peers=$(docker exec "$CONTAINER" sh -c "cat '$AWG_VPN_CONF' 2>/dev/null || true" | tr -d '\r' | awk '
        /^\[Peer\]/ { pubkey=""; ip="" }
        /^PublicKey/ {
            s = $0
            sub(/^[^=]*= */, "", s)
            pubkey = s
        }
        /^AllowedIPs/ {
            s = $0
            sub(/^[^=]*= */, "", s)
            ip = s
            if (pubkey != "" && ip != "") {
                print pubkey "|" ip
            }
        }')

    if [ -n "$conf_peers" ]; then
        while IFS='|' read -r pubkey ip; do
            if [ -n "$pubkey" ] && [ -n "$ip" ] && [ -n "${key_to_name[$pubkey]+_}" ]; then
                local name="${key_to_name[$pubkey]}"
                AWG_CLIENT_NAMES["$ip"]="$name"
                local bare="${ip%/32}"
                AWG_CLIENT_NAMES["$bare"]="$name"
            fi
        done <<< "$conf_peers"
    fi

    return 0
}

awg_get_name() {
    local ip="$1" bare="${1%/32}"
    [ -n "${AWG_CLIENT_NAMES[$bare]+_}" ] && { echo "${AWG_CLIENT_NAMES[$bare]}"; return; }
    [ -n "${AWG_CLIENT_NAMES[$ip]+_}" ] && { echo "${AWG_CLIENT_NAMES[$ip]}"; return; }
    [ -n "${AWG_CLIENT_NAMES[${bare}/32]+_}" ] && { echo "${AWG_CLIENT_NAMES[${bare}/32]}"; return; }
}

awg_format_label() {
    local ip="$1" name; name=$(awg_get_name "$ip")
    [ -n "$name" ] && echo "$ip ($name)" || echo "$ip"
}

awg_get_client_ips() {
    AWG_CLIENT_IPS=()
    mapfile -t AWG_CLIENT_IPS < <(docker exec "$CONTAINER" sh -c "sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*\(.*\/32\)[[:space:]]*$/\1/p' '$AWG_VPN_CONF'" 2>/dev/null | tr -d '\r')
    if [ "${#AWG_CLIENT_IPS[@]}" -eq 0 ]; then
        mapfile -t AWG_CLIENT_IPS < <(docker exec "$CONTAINER" sh -c "awk '/^\[Peer\]/,/^$/' '$AWG_VPN_CONF' | sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*//p'" 2>/dev/null | tr -d '\r' | grep '/32')
    fi
}

awg_toggle_clients_ssh() {
    awg_get_client_ips; awg_parse_clients_table; awg_load_clients

    if [ ${#AWG_CLIENT_IPS[@]} -eq 0 ]; then
        echo -e "\n  ${RED}Нет клиентов в конфиге VPN.${NC}"
        read -p "Enter..."; return
    fi

    local -a pending_ips=()
    for ip in "${AWG_SELECTED_IPS[@]}"; do pending_ips+=("$ip"); done

    while true; do
        local pending_set=" ${pending_ips[*]+"${pending_ips[*]}"} "
        clear; echo -e "\n${CYAN}━━━ Управление клиентами WARP ━━━${NC}\n"
        echo -e "  ${DIM}Нажмите номер чтобы вкл/выкл WARP для клиента${NC}\n"

        local i=1 warp_count=0
        for ip in "${AWG_CLIENT_IPS[@]}"; do
            local label; label=$(awg_format_label "$ip")
            if [[ "$pending_set" == *" $ip "* ]]; then
                echo -e "  ${GREEN} $i) ✅  $label${NC}"
                ((warp_count++))
            else
                echo -e "  ${WHITE} $i)${NC} ☐   $label"
            fi
            ((i++))
        done

        echo ""
        echo -e "  ${WHITE}Через WARP: ${CYAN}${warp_count}${NC} из ${#AWG_CLIENT_IPS[@]}"
        echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}all${NC}) Включить всех   ${YELLOW}none${NC}) Выключить всех"
        echo -e "  ${GREEN}ok${NC})  Применить        ${DIM}0${NC})    Отмена (без изменений)"
        echo ""
        read -p "  > " answer

        case "$answer" in
            0|"")
                return ;;
            all)
                pending_ips=("${AWG_CLIENT_IPS[@]}") ;;
            none)
                pending_ips=() ;;
            ok)
                AWG_SELECTED_IPS=("${pending_ips[@]+"${pending_ips[@]}"}")
                echo -e "\n${YELLOW}  Применяю правила...${NC}"
                awg_save_clients; awg_apply_rules; awg_patch_start_sh
                echo -e "${GREEN}  ✓ Правила сохранены${NC}"
                echo -e "\n${YELLOW}  Перезапуск контейнера ${CONTAINER}...${NC}"
                docker restart "$CONTAINER" >/dev/null 2>&1
                local a=0
                while [ "$a" -lt 15 ]; do
                    docker exec "$CONTAINER" sh -c "true" 2>/dev/null && break
                    sleep 1; ((a++))
                done
                if docker exec "$CONTAINER" sh -c "true" 2>/dev/null; then
                    echo -e "${GREEN}  ✓ Контейнер перезапущен${NC}"
                else
                    echo -e "${RED}  ⚠ Контейнер не отвечает${NC}"
                fi
                log_action "AWG CLIENTS APPLIED: ${#AWG_SELECTED_IPS[@]} in WARP, container restarted"
                read -p "  Enter..."; return ;;
            *)
                IFS=',' read -ra parts <<< "$answer"
                for p in "${parts[@]}"; do
                    p=$(echo "$p" | xargs)
                    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#AWG_CLIENT_IPS[@]} )); then
                        local ip="${AWG_CLIENT_IPS[$((p-1))]}"
                        if [[ "$pending_set" == *" $ip "* ]]; then
                            local -a tmp=()
                            for eip in "${pending_ips[@]}"; do
                                [ "$eip" != "$ip" ] && tmp+=("$eip")
                            done
                            pending_ips=("${tmp[@]+"${tmp[@]}"}")
                        else
                            pending_ips+=("$ip")
                        fi
                    fi
                done ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  AMNEZIA RUNTIME RULES & PERSISTENCE
# ═══════════════════════════════════════════════════════════════

awg_cleanup_rules() {
    docker exec "$CONTAINER" sh -c '
        ip rule | awk "/lookup 100/ {print \$1}" | sed "s/://g" | sort -rn | while read -r pr; do
            ip rule del priority "$pr" 2>/dev/null || true
        done
        iptables -t nat -S POSTROUTING | grep "\-o warp -j MASQUERADE" | while read -r line; do
            rule=$(echo "$line" | sed "s/^-A /-D /")
            iptables -t nat $rule || true
        done
        ip route flush table 100 2>/dev/null || true
    ' >/dev/null 2>&1 || true
}

awg_apply_rules() {
    awg_cleanup_rules
    [ ${#AWG_SELECTED_IPS[@]} -eq 0 ] && return 0
    docker exec "$CONTAINER" sh -c "ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100 2>/dev/null || true"
    local prio=100
    for ip in "${AWG_SELECTED_IPS[@]}"; do
        docker exec "$CONTAINER" sh -c "
            ip rule add from ${ip} table 100 priority ${prio} 2>/dev/null || true
            iptables -t nat -C POSTROUTING -s ${ip} -o warp -j MASQUERADE 2>/dev/null || \
            iptables -t nat -I POSTROUTING 1 -s ${ip} -o warp -j MASQUERADE
        "
        ((prio++))
    done
}

awg_patch_start_sh() {
    [ -z "${AWG_START_SH:-}" ] && return
    docker exec "$CONTAINER" sh -c "[ -f /opt/amnezia/start.sh.final-backup ] || cp '$AWG_START_SH' /opt/amnezia/start.sh.final-backup" 2>/dev/null

    local warp_block=""
    warp_block+="${AWG_MARKER_BEGIN}"$'\n'
    warp_block+=""$'\n'
    warp_block+="if [ -f '${AWG_WARP_CONF}' ]; then"$'\n'
    warp_block+="  wg-quick up '${AWG_WARP_CONF}' || true"$'\n'
    warp_block+="  sleep 3"$'\n'
    warp_block+="fi"$'\n'
    warp_block+=""$'\n'

    if [ ${#AWG_SELECTED_IPS[@]} -gt 0 ]; then
        warp_block+="ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100 2>/dev/null || true"$'\n'
        warp_block+=""$'\n'
        local prio=100
        for ip in "${AWG_SELECTED_IPS[@]}"; do
            warp_block+="ip rule add from ${ip} table 100 priority ${prio} 2>/dev/null || true"$'\n'
            warp_block+="iptables -t nat -C POSTROUTING -s ${ip} -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s ${ip} -o warp -j MASQUERADE"$'\n'
            ((prio++))
        done
    fi

    warp_block+=""$'\n'
    warp_block+="${AWG_MARKER_END}"

    docker exec "$CONTAINER" sh -c "
        if grep -qF '${AWG_MARKER_BEGIN}' '$AWG_START_SH'; then
            sed -i '/# --- WARP-MANAGER BEGIN ---/,/# --- WARP-MANAGER END ---/d' '$AWG_START_SH'
        fi
    " 2>/dev/null

    docker exec "$CONTAINER" sh -c "
        if grep -qF 'tail -f /dev/null' '$AWG_START_SH'; then
            tmpfile=\$(mktemp)
            while IFS= read -r line; do
                if echo \"\$line\" | grep -qF 'tail -f /dev/null'; then
                    cat <<'WARPBLOCK'
${warp_block}
WARPBLOCK
                fi
                echo \"\$line\"
            done < '$AWG_START_SH' > \"\$tmpfile\"
            mv \"\$tmpfile\" '$AWG_START_SH'
            chmod +x '$AWG_START_SH'
        else
            cat >> '$AWG_START_SH' <<'WARPBLOCK'

${warp_block}
WARPBLOCK
            chmod +x '$AWG_START_SH'
        fi
    " 2>/dev/null
}

awg_remove_from_start_sh() {
    [ -z "${AWG_START_SH:-}" ] && return
    docker exec "$CONTAINER" sh -c "
        if grep -qF '${AWG_MARKER_BEGIN}' '$AWG_START_SH' 2>/dev/null; then
            sed -i '/# --- WARP-MANAGER BEGIN ---/,/# --- WARP-MANAGER END ---/d' '$AWG_START_SH'
        fi
    " 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
#  UNIFIED WRAPPERS
# ═══════════════════════════════════════════════════════════════

get_warp_status() {
    if [ "$MODE" = "both" ]; then
        local s3 sa
        s3=$(get_warp_status_3xui); sa=$(get_warp_status_awg)
        echo "3X-UI: ${s3} | AWG: ${sa}"
    elif [ "$MODE" = "3xui" ]; then
        get_warp_status_3xui
    else
        get_warp_status_awg
    fi
}

get_warp_ip() {
    if [ "$MODE" = "both" ]; then
        local ip3 ipa
        ip3=$(get_warp_ip_3xui)
        awg_detect_warp_exit_ip; ipa="${AWG_WARP_EXIT_IP:-N/A}"
        echo "3X-UI: ${ip3} | AWG: ${ipa}"
    elif [ "$MODE" = "3xui" ]; then
        get_warp_ip_3xui
    else
        awg_detect_warp_exit_ip; echo "${AWG_WARP_EXIT_IP:-N/A}"
    fi
}

is_warp_running() {
    if [ "$MODE" = "both" ]; then
        is_warp_running_3xui 2>/dev/null || is_warp_running_awg 2>/dev/null
    elif [ "$MODE" = "3xui" ]; then
        is_warp_running_3xui
    else
        is_warp_running_awg
    fi
}

# ═══════════════════════════════════════════════════════════════
#  TELEGRAM BOT
# ═══════════════════════════════════════════════════════════════

tg_api() {
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/$1" \
        -H "Content-Type: application/json" -d "$2" 2>/dev/null
}

tg_send() {
    local chat_id="$1" text keyboard="${3:-}"
    text=$(printf '%b' "$2")
    local payload
    if [ -n "$keyboard" ]; then
        payload=$(jq -n --arg c "$chat_id" --arg t "$text" --argjson k "$keyboard" \
            '{chat_id:$c, text:$t, parse_mode:"HTML", reply_markup:{inline_keyboard:$k}}')
    else
        payload=$(jq -n --arg c "$chat_id" --arg t "$text" \
            '{chat_id:$c, text:$t, parse_mode:"HTML"}')
    fi
    tg_api "sendMessage" "$payload"
}

tg_edit() {
    local chat_id="$1" msg_id="$2" text keyboard="${4:-}"
    text=$(printf '%b' "$3")
    local payload
    if [ -n "$keyboard" ]; then
        payload=$(jq -n --arg c "$chat_id" --argjson m "$msg_id" --arg t "$text" --argjson k "$keyboard" \
            '{chat_id:$c, message_id:$m, text:$t, parse_mode:"HTML", reply_markup:{inline_keyboard:$k}}')
    else
        payload=$(jq -n --arg c "$chat_id" --argjson m "$msg_id" --arg t "$text" \
            '{chat_id:$c, message_id:$m, text:$t, parse_mode:"HTML"}')
    fi
    tg_api "editMessageText" "$payload"
}

tg_answer_cb() {
    tg_api "answerCallbackQuery" "{\"callback_query_id\":\"$1\",\"text\":\"${2:-}\"}"
}

# ─── Bot keyboards ───────────────────────────────────────────

kbd_main_3xui() {
    cat <<'JSON'
[
  [{"text":"📊 Статус","callback_data":"st"},{"text":"🌐 IP","callback_data":"ip"}],
  [{"text":"▶️ Запустить","callback_data":"on"},{"text":"⏹ Остановить","callback_data":"off"}],
  [{"text":"🔑 Перевыпуск","callback_data":"rk"}],
  [{"text":"📋 JSON 3X-UI","callback_data":"js"}],
  [{"text":"💻 Система","callback_data":"sys"}]
]
JSON
}

kbd_main_awg() {
    cat <<'JSON'
[
  [{"text":"📊 Статус","callback_data":"st"},{"text":"🌐 IP","callback_data":"ip"}],
  [{"text":"▶️ Запустить","callback_data":"on"},{"text":"⏹ Остановить","callback_data":"off"}],
  [{"text":"🔑 Перевыпуск","callback_data":"rk"}],
  [{"text":"👥 Клиенты WARP","callback_data":"cl"},{"text":"🔄 Контейнер","callback_data":"rc"}],
  [{"text":"💻 Система","callback_data":"sys"}]
]
JSON
}

kbd_main_both() {
    cat <<'JSON'
[
  [{"text":"📊 Статус","callback_data":"st"},{"text":"🌐 IP","callback_data":"ip"}],
  [{"text":"▶️ Запустить","callback_data":"on"},{"text":"⏹ Остановить","callback_data":"off"}],
  [{"text":"🔑 Перевыпуск","callback_data":"rk"}],
  [{"text":"📋 JSON 3X-UI","callback_data":"js"},{"text":"👥 Клиенты AWG","callback_data":"cl"}],
  [{"text":"🔄 Контейнер","callback_data":"rc"}],
  [{"text":"💻 Система","callback_data":"sys"}]
]
JSON
}

kbd_main() {
    if [ "$MODE" = "both" ]; then kbd_main_both
    elif [ "$MODE" = "3xui" ]; then kbd_main_3xui
    else kbd_main_awg; fi
}

kbd_back() { echo '[[{"text":"⬅️ Меню","callback_data":"m"}]]'; }
kbd_rekey_confirm() { echo '[[{"text":"✅ Да","callback_data":"rk_y"}],[{"text":"⬅️ Отмена","callback_data":"m"}]]'; }

# ─── Bot main menu ───────────────────────────────────────────

bot_main_menu() {
    local chat_id="$1" msg_id="${2:-}"
    local ws wip="" extra=""
    ws=$(get_warp_status)
    is_warp_running && wip=" | WARP IP: $(get_warp_ip)"
    if has_3xui_mode; then extra+="\nSOCKS5: <code>127.0.0.1:${SOCKS_PORT}</code>"; fi
    if has_awg_mode; then extra+="\nКонтейнер: <code>${CONTAINER:-N/A}</code>"; fi
    local mode_label="3X-UI"
    [ "$MODE" = "amnezia" ] && mode_label="AmneziaWG"
    [ "$MODE" = "both" ] && mode_label="3X-UI + AWG"
    local text="<b>WARP Manager v${WARP_VERSION}</b> (${mode_label})\nСервер: <code>${MY_IP:-N/A}</code>\nСтатус: <b>${ws}</b>${wip}${extra}\n\nВыберите:"
    local kbd; kbd=$(kbd_main)
    if [ -n "$msg_id" ]; then
        tg_edit "$chat_id" "$msg_id" "$text" "$kbd"
    else
        tg_send "$chat_id" "$text" "$kbd"
    fi
}

# ─── Bot handlers ────────────────────────────────────────────

bot_handle_callback() {
    local chat_id="$1" msg_id="$2" cb_id="$3" data="$4"
    [ -n "$cb_id" ] && tg_answer_cb "$cb_id" > /dev/null

    case "$data" in
        m) bot_main_menu "$chat_id" "$msg_id" ;;

        st)
            local ws wip="" extra=""
            ws=$(get_warp_status)
            is_warp_running && wip="\nWARP IP: <code>$(get_warp_ip)</code>"
            if has_3xui_mode; then
                extra+="\nSOCKS5: <code>127.0.0.1:${SOCKS_PORT}</code>"
                local raw; raw=$(warp-cli --accept-tos status 2>/dev/null | head -3)
                [ -n "$raw" ] && extra+="\n\n<pre>${raw}</pre>"
            fi
            if has_awg_mode; then
                extra+="\nКонтейнер: <code>${CONTAINER:-N/A}</code>\nПодсеть: <code>${AWG_SUBNET:-N/A}</code>"
                awg_load_clients
                extra+="\nКлиентов в WARP: <b>${#AWG_SELECTED_IPS[@]}</b>"
            fi
            tg_edit "$chat_id" "$msg_id" "📊 <b>Статус WARP</b>\n\nСтатус: <b>${ws}</b>\nСервер: <code>${MY_IP:-N/A}</code>${wip}${extra}" "$(kbd_back)" ;;

        ip)
            local wip="N/A"; is_warp_running && wip=$(get_warp_ip)
            local t="🌐 <b>IP адреса</b>\n\n<b>Реальный:</b> <code>${MY_IP:-N/A}</code>\n<b>WARP:</b> <code>${wip}</code>"
            if has_3xui_mode; then t+="\n<b>SOCKS5:</b> <code>127.0.0.1:${SOCKS_PORT}</code>"; fi
            tg_edit "$chat_id" "$msg_id" "$t" "$(kbd_back)" ;;

        on)
            tg_edit "$chat_id" "$msg_id" "⏳ Запуск..." ""
            local result=""
            if has_3xui_mode && is_warp_installed_3xui; then
                warp-cli --accept-tos connect > /dev/null 2>&1; sleep 3
                if is_warp_running_3xui; then
                    result+="✅ 3X-UI: $(get_warp_ip_3xui)\n"; log_action "BOT 3XUI ON"
                else result+="❌ 3X-UI: ошибка\n"; fi
            fi
            if has_awg_mode && is_warp_installed_awg; then
                awg_warp_up 2>/dev/null
                if is_warp_running_awg; then
                    awg_detect_warp_exit_ip
                    result+="✅ AWG: ${AWG_WARP_EXIT_IP:-?}\n"; log_action "BOT AWG ON"
                else result+="❌ AWG: ошибка\n"; fi
            fi
            [ -z "$result" ] && result="❌ WARP не установлен."
            tg_edit "$chat_id" "$msg_id" "<b>Запуск WARP</b>\n\n${result}" "$(kbd_back)" ;;

        off)
            local result=""
            if has_3xui_mode && is_warp_running_3xui 2>/dev/null; then
                warp-cli --accept-tos disconnect > /dev/null 2>&1
                result+="⏹ 3X-UI отключён\n"; log_action "BOT 3XUI OFF"
            fi
            if has_awg_mode && is_warp_running_awg 2>/dev/null; then
                docker exec "$CONTAINER" sh -c "wg-quick down '$AWG_WARP_CONF' 2>/dev/null || true"
                result+="⏹ AWG остановлен\n"; log_action "BOT AWG OFF"
            fi
            [ -z "$result" ] && result="ℹ️ Уже отключён."
            tg_edit "$chat_id" "$msg_id" "<b>Остановка WARP</b>\n\n${result}" "$(kbd_back)" ;;

        rk)
            tg_edit "$chat_id" "$msg_id" "🔑 <b>Перевыпуск ключа</b>\n\nПродолжить?" "$(kbd_rekey_confirm)" ;;

        rk_y)
            tg_edit "$chat_id" "$msg_id" "⏳ Перевыпуск..." ""
            local result=""
            if has_3xui_mode; then
                warp-cli --accept-tos disconnect > /dev/null 2>&1
                warp-cli --accept-tos registration delete > /dev/null 2>&1
                warp-cli --accept-tos registration new > /dev/null 2>&1
                warp-cli --accept-tos mode proxy > /dev/null 2>&1
                warp-cli --accept-tos proxy port "${SOCKS_PORT}" > /dev/null 2>&1
                warp-cli --accept-tos connect > /dev/null 2>&1; sleep 3
                if is_warp_running_3xui; then
                    local w; w=$(get_warp_ip_3xui)
                    result+="✅ 3X-UI: <code>${w}</code>\n"; log_action "BOT 3XUI REKEY: ${w}"
                else result+="⚠️ 3X-UI: не подтверждено\n"; fi
            fi
            if has_awg_mode; then
                docker exec "$CONTAINER" sh -c "wg-quick down '$AWG_WARP_CONF' 2>/dev/null || true"
                rm -f "$WGCF_ACCOUNT"
                (cd /root && yes | ./wgcf register 2>/dev/null && yes | ./wgcf generate 2>/dev/null)
                if [ -f "$WGCF_PROFILE" ]; then
                    local ep; ep=$(awg_resolve_endpoint 2>/dev/null)
                    if [ -n "$ep" ]; then
                        awg_build_warp_conf "$ep"
                        awg_warp_up 2>/dev/null
                        awg_load_clients; awg_apply_rules; awg_patch_start_sh
                        awg_detect_warp_exit_ip
                        result+="✅ AWG: <code>${AWG_WARP_EXIT_IP:-?}</code>\n"; log_action "BOT AWG REKEY"
                    else result+="❌ AWG: ошибка endpoint\n"; fi
                else result+="❌ AWG: ошибка профиля\n"; fi
            fi
            tg_edit "$chat_id" "$msg_id" "🔑 <b>Перевыпуск ключа</b>\n\n${result}" "$(kbd_back)" ;;

        js)
            if has_3xui_mode; then
                local t="📋 <b>Конфигурация для 3X-UI</b>\n\n<b>Outbound:</b>\n<pre>{\n  \"tag\": \"warp\",\n  \"protocol\": \"socks\",\n  \"settings\": {\n    \"servers\": [{\"address\": \"127.0.0.1\", \"port\": ${SOCKS_PORT}}]\n  }\n}</pre>\n\n<b>Routing:</b>\n<pre>{\"outboundTag\": \"warp\", \"domain\": [\"geosite:openai\",\"geosite:netflix\"]}</pre>"
                tg_edit "$chat_id" "$msg_id" "$t" "$(kbd_back)"
            else
                tg_edit "$chat_id" "$msg_id" "ℹ️ JSON не требуется для AmneziaWG." "$(kbd_back)"
            fi ;;

        cl)
            awg_get_client_ips; awg_parse_clients_table; awg_load_clients
            local warp_set=" ${AWG_SELECTED_IPS[*]+"${AWG_SELECTED_IPS[*]}"} "
            local t="👥 <b>Клиенты WARP</b> (${#AWG_SELECTED_IPS[@]} из ${#AWG_CLIENT_IPS[@]})\n\n"
            local kbd=""
            if [ ${#AWG_CLIENT_IPS[@]} -eq 0 ]; then
                t+="<i>Нет клиентов в конфиге VPN.</i>"
                kbd='[[{"text":"⬅️ Меню","callback_data":"m"}]]'
            else
                kbd="["
                local first=1
                for i in "${!AWG_CLIENT_IPS[@]}"; do
                    local ip="${AWG_CLIENT_IPS[$i]}"
                    local name; name=$(awg_get_name "$ip")
                    local label="${ip}"
                    [ -n "$name" ] && label="$name"
                    if [[ "$warp_set" == *" $ip "* ]]; then
                        t+="✅ <code>${ip}</code>"
                        [ -n "$name" ] && t+=" ($name)"
                        label="✅ ${label}"
                    else
                        t+="☐ <code>${ip}</code>"
                        [ -n "$name" ] && t+=" ($name)"
                        label="☐ ${label}"
                    fi
                    t+="\n"
                    local safe_label; safe_label=$(echo "$label" | sed 's/["\\]/\\&/g; s/\n//g')
                    [ "$first" -eq 0 ] && kbd+=","
                    kbd+="[{\"text\":\"${safe_label}\",\"callback_data\":\"ct:${i}\"}]"
                    first=0
                done
                kbd+=",[{\"text\":\"✅ Все\",\"callback_data\":\"ct:all\"},{\"text\":\"☐ Никого\",\"callback_data\":\"ct:none\"}]"
                kbd+=",[{\"text\":\"⬅️ Меню\",\"callback_data\":\"m\"}]]"
            fi
            tg_edit "$chat_id" "$msg_id" "$t" "$kbd" ;;

        ct:*)
            local idx="${data#ct:}"
            awg_get_client_ips; awg_load_clients
            if [ "$idx" = "all" ]; then
                AWG_SELECTED_IPS=("${AWG_CLIENT_IPS[@]}")
            elif [ "$idx" = "none" ]; then
                AWG_SELECTED_IPS=()
            else
                [[ "$idx" =~ ^[0-9]+$ ]] && (( idx < ${#AWG_CLIENT_IPS[@]} )) || { tg_edit "$chat_id" "$msg_id" "❌ Ошибка." "$(kbd_back)"; return; }
                local ip="${AWG_CLIENT_IPS[$idx]}"
                local warp_set=" ${AWG_SELECTED_IPS[*]+"${AWG_SELECTED_IPS[*]}"} "
                if [[ "$warp_set" == *" $ip "* ]]; then
                    local -a tmp=()
                    for eip in "${AWG_SELECTED_IPS[@]}"; do
                        [ "$eip" != "$ip" ] && tmp+=("$eip")
                    done
                    AWG_SELECTED_IPS=("${tmp[@]+"${tmp[@]}"}")
                else
                    AWG_SELECTED_IPS+=("$ip")
                fi
            fi
            awg_save_clients; awg_apply_rules; awg_patch_start_sh
            tg_edit "$chat_id" "$msg_id" "⏳ Применяю и перезапускаю контейнер..." ""
            docker restart "$CONTAINER" >/dev/null 2>&1
            local _a=0; while [ "$_a" -lt 15 ]; do docker exec "$CONTAINER" sh -c "true" 2>/dev/null && break; sleep 1; ((_a++)); done
            log_action "BOT AWG TOGGLE: ${#AWG_SELECTED_IPS[@]}, container restarted"
            bot_handle_callback "$chat_id" "$msg_id" "" "cl" ;;

        rc)
            if ! has_awg_mode; then
                tg_edit "$chat_id" "$msg_id" "ℹ️ Только для AmneziaWG." "$(kbd_back)"; return
            fi
            tg_edit "$chat_id" "$msg_id" "🔄 Перезапуск контейнера..." ""
            docker restart "$CONTAINER" >/dev/null 2>&1; sleep 5
            if docker exec "$CONTAINER" sh -c "true" 2>/dev/null; then
                tg_edit "$chat_id" "$msg_id" "✅ Контейнер перезапущен." "$(kbd_back)"; log_action "BOT AWG RESTART"
            else
                tg_edit "$chat_id" "$msg_id" "⚠️ Контейнер не отвечает." "$(kbd_back)"
            fi ;;

        sys)
            local s; s=$(get_system_stats)
            local ws; ws=$(get_warp_status)
            s+="\n<b>WARP:</b> ${ws}"
            s+="\n<b>Режим:</b> ${MODE}"
            if has_3xui_mode; then s+="\n<b>SOCKS5:</b> 127.0.0.1:${SOCKS_PORT}"; fi
            if has_awg_mode; then s+="\n<b>Контейнер:</b> ${CONTAINER:-N/A}"; fi
            tg_edit "$chat_id" "$msg_id" "$s" "$(kbd_back)" ;;

    esac
}

# ─── Bot daemon ───────────────────────────────────────────────

bot_daemon() {
    log_action "Bot daemon started (PID $$)"; echo $$ > "$BOT_PID_FILE"
    source "$WARP_CONF"
    [ -z "$BOT_TOKEN" ] && { log_action "BOT ERROR: no token"; exit 1; }
    get_my_ip
    if has_awg_mode && [ -n "$CONTAINER" ]; then awg_load_container_data 2>/dev/null; fi
    local offset=0
    while true; do
        local response
        response=$(curl -s --max-time 35 \
            "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${offset}&timeout=30" 2>/dev/null)
        [ -z "$response" ] && sleep 2 && continue
        local ok; ok=$(echo "$response" | jq -r '.ok // "false"')
        [ "$ok" != "true" ] && sleep 5 && continue
        local cnt; cnt=$(echo "$response" | jq '.result | length')
        for (( i=0; i<cnt; i++ )); do
            local upd; upd=$(echo "$response" | jq ".result[$i]")
            local uid; uid=$(echo "$upd" | jq -r '.update_id')
            offset=$((uid + 1))
            local cbd; cbd=$(echo "$upd" | jq -r '.callback_query.data // empty')
            if [ -n "$cbd" ]; then
                local cbi cci cmi
                cbi=$(echo "$upd" | jq -r '.callback_query.id')
                cci=$(echo "$upd" | jq -r '.callback_query.message.chat.id')
                cmi=$(echo "$upd" | jq -r '.callback_query.message.message_id')
                [ -n "$BOT_CHAT_ID" ] && [ "$cci" != "$BOT_CHAT_ID" ] && { tg_answer_cb "$cbi" "Нет доступа" > /dev/null; continue; }
                bot_handle_callback "$cci" "$cmi" "$cbi" "$cbd"
            else
                local mci mtx
                mci=$(echo "$upd" | jq -r '.message.chat.id // empty')
                mtx=$(echo "$upd" | jq -r '.message.text // empty')
                if [ -n "$mci" ] && [ -n "$mtx" ]; then
                    [ -n "$BOT_CHAT_ID" ] && [ "$mci" != "$BOT_CHAT_ID" ] && { tg_send "$mci" "⛔ Нет доступа.\nChat ID: <code>$mci</code>" "" > /dev/null; continue; }
                    if [[ "$mtx" == "/start" || "$mtx" == "/menu" ]]; then
                        bot_main_menu "$mci"
                    else
                        tg_send "$mci" "Используйте /start или /menu" "" > /dev/null
                    fi
                fi
            fi
        done
    done
}

# ─── Bot menu (SSH) ──────────────────────────────────────────

start_bot() {
    source "$WARP_CONF"
    [ -z "$BOT_TOKEN" ] && { echo -e "${RED}Задайте BOT_TOKEN!${NC}"; return; }
    [ -f "$BOT_PID_FILE" ] && kill -0 "$(cat "$BOT_PID_FILE")" 2>/dev/null && { echo -e "${YELLOW}Уже запущен.${NC}"; return; }
    cat > /etc/systemd/system/warp-bot.service <<EOF
[Unit]
Description=WARP Manager Telegram Bot
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/gowarp --bot-daemon
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable warp-bot > /dev/null 2>&1; systemctl start warp-bot; sleep 1
    if systemctl is-active warp-bot &>/dev/null; then
        echo -e "${GREEN}[OK] Бот запущен.${NC}"; log_action "Bot started"
    else
        echo -e "${RED}[ERROR] journalctl -u warp-bot${NC}"
    fi
}

stop_bot() {
    systemctl stop warp-bot 2>/dev/null; systemctl disable warp-bot 2>/dev/null; rm -f "$BOT_PID_FILE"
    echo -e "${GREEN}[OK] Бот остановлен.${NC}"; log_action "Bot stopped"
}

bot_auto_chatid() {
    echo -e "${YELLOW}  Отправьте боту любое сообщение в Telegram, затем нажмите Enter.${NC}"
    read -p "  > " _
    local c; c=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?limit=1&offset=-1" | jq -r '.result[0].message.chat.id // empty')
    if [ -n "$c" ]; then
        save_config_val "BOT_CHAT_ID" "$c"; BOT_CHAT_ID="$c"
        echo -e "  ${GREEN}✓ Chat ID: $c${NC}"
        return 0
    else
        echo -e "  ${RED}✗ Не удалось определить Chat ID.${NC}"
        return 1
    fi
}

bot_wizard() {
    clear
    echo -e "\n${CYAN}━━━ Настройка Telegram-бота (быстрый старт) ━━━${NC}\n"

    echo -e "${YELLOW}Шаг 1/3.${NC} Введите токен бота"
    echo -e "${DIM}  Получить: @BotFather → /newbot → скопировать токен${NC}\n"
    read -p "  Токен: " t
    if [ -z "$t" ]; then echo -e "  ${RED}Отменено.${NC}"; read -p "Enter..."; return; fi
    save_config_val "BOT_TOKEN" "$t"; BOT_TOKEN="$t"
    echo -e "  ${GREEN}✓ Токен сохранён${NC}\n"

    echo -e "${YELLOW}Шаг 2/3.${NC} Определение Chat ID (авто)"
    if ! bot_auto_chatid; then
        echo -e "\n  ${YELLOW}Chat ID не определён — бот будет доступен всем.${NC}"
        echo -e "  ${WHITE}Можно задать вручную позже через меню бота (п.3).${NC}"
    fi
    echo ""

    echo -e "${YELLOW}Шаг 3/3.${NC} Запуск бота"
    start_bot
    echo ""

    if systemctl is-active warp-bot &>/dev/null; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  ✅ Бот настроен и запущен!${NC}"
        echo -e "${GREEN}  Откройте бота в Telegram и нажмите /start${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${YELLOW}  ⚠ Бот может не запуститься. Проверьте:${NC}"
        echo -e "  ${WHITE}journalctl -u warp-bot --no-pager -n 10${NC}"
    fi
    read -p "  Enter..."
}

bot_menu() {
    source "$WARP_CONF" 2>/dev/null
    if [ -z "${BOT_TOKEN:-}" ]; then
        bot_wizard
        return
    fi

    while true; do
        clear; source "$WARP_CONF" 2>/dev/null
        local bs="${RED}Выкл${NC}"
        systemctl is-active warp-bot &>/dev/null && bs="${GREEN}Вкл${NC}"
        local td="***${BOT_TOKEN: -6}"
        echo -e "\n${CYAN}━━━ Telegram Bot ━━━${NC}\n"
        echo -e "  Статус:  $bs"
        echo -e "  Токен:   ${YELLOW}$td${NC}"
        echo -e "  Chat ID: ${YELLOW}${BOT_CHAT_ID:-нет}${NC}\n"
        echo -e "  1) Изменить токен"
        echo -e "  2) Chat ID (авто)"
        echo -e "  3) Chat ID (вручную)"
        echo -e "  4) ${GREEN}Запустить${NC}"
        echo -e "  5) ${RED}Остановить${NC}"
        echo -e "  0) Назад"
        echo ""
        read -p "  Выбор: " ch
        case $ch in
            1) echo "  Токен:"; read -p "  > " t
               [ -n "$t" ] && save_config_val "BOT_TOKEN" "$t" && BOT_TOKEN="$t" && echo -e "  ${GREEN}OK${NC}"
               read -p "  Enter..." ;;
            2) bot_auto_chatid; read -p "  Enter..." ;;
            3) echo "  Chat ID:"; read -p "  > " c
               [ -n "$c" ] && save_config_val "BOT_CHAT_ID" "$c" && BOT_CHAT_ID="$c" && echo -e "  ${GREEN}OK${NC}"
               read -p "  Enter..." ;;
            4) start_bot; read -p "  Enter..." ;;
            5) stop_bot; read -p "  Enter..." ;;
            0) return ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  INFO
# ═══════════════════════════════════════════════════════════════

show_info() {
    clear; echo ""
    echo -e "${MAGENTA}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  📚 WARP Manager v${WARP_VERSION}                             ${NC}"
    echo -e "${MAGENTA}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    if has_3xui_mode; then
        echo -e "${CYAN}═══ 3X-UI ═══${NC}\n"
        echo -e "${WHITE}  Клиент → 3X-UI (Xray) → SOCKS5 (WARP) → Cloudflare → Интернет${NC}\n"
        echo -e "${GREEN}  1.${NC} cloudflare-warp установлен нативно"
        echo -e "${GREEN}  2.${NC} SOCKS5-прокси на 127.0.0.1:${SOCKS_PORT}"
        echo -e "${GREEN}  3.${NC} В 3X-UI: outbound SOCKS → warp"
        echo -e "${GREEN}  4.${NC} Маршрутизация по доменам в Xray"
        echo ""
    fi
    if has_awg_mode; then
        echo -e "${CYAN}═══ AmneziaWG ═══${NC}\n"
        echo -e "${WHITE}  Клиент → AmneziaWG Docker → warp WG → Cloudflare → Интернет${NC}\n"
        echo -e "${GREEN}  1.${NC} wgcf генерирует WireGuard-профиль WARP"
        echo -e "${GREEN}  2.${NC} WG-интерфейс warp внутри Docker-контейнера"
        echo -e "${GREEN}  3.${NC} Маршрутизация per-client через ip rule"
        echo -e "${GREEN}  4.${NC} Персистентность через start.sh контейнера"
    fi
    echo -e "\n${GREEN}  ✓${NC}  Разблокировка ChatGPT, Netflix, Disney+, Spotify"
    echo -e "${GREEN}  ✓${NC}  Чистый IP от Cloudflare"
    echo -e "${GREEN}  ✓${NC}  Telegram-бот"
    echo -e "${GREEN}  ✓${NC}  Бесплатно (Cloudflare WARP)"
    echo ""; read -p "Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  FULL UNINSTALL
# ═══════════════════════════════════════════════════════════════

full_uninstall() {
    clear
    echo -e "\n${RED}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}            ⚠  ПОЛНОЕ УДАЛЕНИЕ WARP MANAGER  ⚠                  ${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}\n"
    echo -e "${WHITE}Режим: ${CYAN}${MODE}${NC}\n"
    read -p "$(echo -e "${RED}Удалить полностью? (y/n): ${NC}")" c1
    [[ "$c1" != "y" ]] && return

    if has_3xui_mode; then uninstall_3xui; fi
    if has_awg_mode; then uninstall_awg; fi

    rm -rf "$WARP_DIR" "$WARP_LOG"
    echo -e "  ${GREEN}✓${NC}  Конфигурация и логи"
    rm -f /usr/local/bin/gowarp
    echo -e "  ${GREEN}✓${NC}  Команда gowarp"

    echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  WARP Manager полностью удалён.${NC}"
    has_3xui_mode && echo -e "${WHITE}  Уберите outbound \"warp\" из 3X-UI!${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    log_action "UNINSTALL: full removal ($MODE)"
    read -p "Enter..."
    exit 0
}

# ═══════════════════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════════════════

show_menu() {
    while true; do
        clear
        local st sc
        st=$(get_warp_status)
        sc="$RED"; [[ "$st" == *"Подключён"* ]] && sc="$GREEN"; [[ "$st" == *"Отключён"* && "$st" != *"Подключён"* ]] && sc="$YELLOW"
        local mode_label="3X-UI"
        [ "$MODE" = "amnezia" ] && mode_label="AmneziaWG"
        [ "$MODE" = "both" ] && mode_label="3X-UI + AmneziaWG"

        echo -e "${MAGENTA}══════════════════════════════════════════════════════${NC}"
        echo -e "${MAGENTA}  gowarp-server  ·  WARP Manager v${WARP_VERSION}     ${NC}"
        echo -e "${MAGENTA}══════════════════════════════════════════════════════${NC}"
        echo -e "  ${WHITE}IP сервера:${NC} ${GREEN}${MY_IP}${NC}   ${WHITE}Режим:${NC} ${CYAN}${mode_label}${NC}"
        echo -e "  ${WHITE}WARP:${NC} ${sc}${st}${NC}"
        if has_3xui_mode && is_warp_running_3xui 2>/dev/null; then
            echo -e "  ${WHITE}SOCKS5:${NC} ${CYAN}127.0.0.1:${SOCKS_PORT}${NC}"
        fi
        if has_awg_mode && [ -n "${CONTAINER:-}" ]; then
            echo -e "  ${WHITE}Контейнер:${NC} ${CYAN}${CONTAINER}${NC}"
        fi

        echo -e "\n${CYAN}── WARP-ключ ──────────────────────────────────────────${NC}"
        echo -e "  1) ${GREEN}Установить WARP${NC}"
        echo -e "  2) ${CYAN}Запустить WARP${NC}"
        echo -e "  3) ${YELLOW}Остановить WARP${NC}"
        echo -e "  4) 📊 Статус"
        echo -e "  5) 🔑 ${YELLOW}Перевыпуск ключа${NC}"

        if has_3xui_mode; then
            echo -e "\n${CYAN}── 3X-UI ──────────────────────────────────────────────${NC}"
            echo -e "  6) 📋 ${CYAN}Настройки SOCKS5 / JSON / Инструкция${NC}"
        fi

        if has_awg_mode; then
            echo -e "\n${CYAN}── AmneziaWG ──────────────────────────────────────────${NC}"
            echo -e "  7) 👥 ${GREEN}Управление клиентами WARP${NC}"
        fi

        echo -e "\n${CYAN}── Telegram-бот ───────────────────────────────────────${NC}"
        echo -e "  8) 🤖 ${CYAN}Настройка и управление ботом${NC}"

        echo -e "\n${CYAN}── Прочее ─────────────────────────────────────────────${NC}"
        echo -e "  9) ${MAGENTA}📚 Инструкция${NC}"
        echo -e " 10) ${RED}⚠  Полное удаление${NC}"
        echo -e "  0) Выход"
        echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"
        read -p "  Выбор: " ch

        case $ch in
            1)  if has_3xui_mode; then install_warp_3xui; fi
                if has_awg_mode; then install_warp_awg; fi ;;
            2)  if has_3xui_mode; then start_warp_3xui; fi
                if has_awg_mode; then start_warp_awg; fi ;;
            3)  if has_3xui_mode; then stop_warp_3xui; fi
                if has_awg_mode; then stop_warp_awg; fi ;;
            4)  if has_3xui_mode; then show_status_3xui; fi
                if has_awg_mode; then show_status_awg; fi ;;
            5)  if has_3xui_mode; then rekey_warp_3xui; fi
                if has_awg_mode; then rekey_warp_awg; fi ;;
            6)  has_3xui_mode && show_3xui_menu ;;
            7)  has_awg_mode && awg_toggle_clients_ssh ;;
            8)  bot_menu ;;
            9)  show_info ;;
            10) full_uninstall ;;
            0)  exit 0 ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  STARTUP
# ═══════════════════════════════════════════════════════════════

run_startup() {
    local total=6 s=0

    clear; echo ""
    echo -e "${MAGENTA}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}            WARP Manager v${WARP_VERSION} — Загрузка          ${NC}"
    echo -e "${MAGENTA}══════════════════════════════════════════════════════════════${NC}"
    echo ""

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Проверка root..." "$s" "$total"
    check_root
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   root OK                                    \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Лицензия..." "$s" "$total"
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Лицензия активна                           \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Зависимости..." "$s" "$total"
    check_deps
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Зависимости OK                             \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Установка gowarp..." "$s" "$total"
    local upgrade_msg="установлена"
    [ -f "/usr/local/bin/gowarp" ] && upgrade_msg="обновлена (v${WARP_VERSION})"
    if [ "$(readlink -f "$0" 2>/dev/null)" != "/usr/local/bin/gowarp" ]; then
        curl -fsSL "$SCRIPT_URL" -o "/usr/local/bin/gowarp" && chmod +x "/usr/local/bin/gowarp" \
            || { cp -f "$0" "/usr/local/bin/gowarp" 2>/dev/null && chmod +x "/usr/local/bin/gowarp"; }
    fi
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Команда gowarp %s                    \n" "$s" "$total" "$upgrade_msg"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Определение IP..." "$s" "$total"
    get_my_ip
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   IP: %-25s             \n" "$s" "$total" "$MY_IP"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Определение режима..." "$s" "$total"
    detect_mode
    local mode_label="3X-UI"
    [ "$MODE" = "amnezia" ] && mode_label="AmneziaWG"
    [ "$MODE" = "both" ] && mode_label="3X-UI + AmneziaWG"
    has_awg_mode && ((total++))
    has_3xui_mode && ((total++))
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Режим: %-25s           \n" "$s" "$total" "$mode_label"

    if has_awg_mode; then
        ((s++))
        printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Docker контейнер..." "$s" "$total"
        if awg_pick_container 2>/dev/null; then
            awg_load_container_data 2>/dev/null
            printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Контейнер: %-20s        \n" "$s" "$total" "$CONTAINER"
        else
            printf "\r  ${CYAN}[%d/%d]${NC}  ${YELLOW}⚠${NC}   Контейнер не найден                     \n" "$s" "$total"
        fi
    fi
    if has_3xui_mode; then
        ((s++))
        printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Проверка WARP (3X-UI)..." "$s" "$total"
        local ws; ws=$(get_warp_status_3xui)
        printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   3X-UI WARP: %-20s        \n" "$s" "$total" "$ws"
    fi

    echo ""
    local w=40 bar=""
    for ((i=0; i<w; i++)); do bar+="█"; done
    echo -e "  ${CYAN}[${GREEN}${bar}${CYAN}]${NC} ${GREEN}100%${NC}"
    echo -e "\n  ${GREEN}✅  WARP Manager v${WARP_VERSION} (${mode_label}) готов!${NC}\n"
    sleep 2

    show_info
    show_menu
}

# ═══════════════════════════════════════════════════════════════
#  ENTRY POINT
# ═══════════════════════════════════════════════════════════════

case "${1:-}" in
    --bot-daemon) init_config; bot_daemon ;;
    *) init_config; run_startup ;;
esac
