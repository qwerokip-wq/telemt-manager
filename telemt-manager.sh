#!/bin/bash
# telemt-manager.sh — менеджер установки и управления Telemt + Telemt Panel
#
# Режимы:
#   Интерактивный: запуск без аргументов
#   Неинтерактивный: --install, --remove, --links и т.д.
#
# Примеры:
#   bash telemt-manager.sh --install --domain www.cloudflare.com --port 8443
#   bash telemt-manager.sh --install-panel --panel-port 8444 --panel-user admin --panel-pass secret
#   bash telemt-manager.sh --add-client myuser
#   bash telemt-manager.sh --del-client myuser
#   bash telemt-manager.sh --links
#   bash telemt-manager.sh --update --version 3.3.29
#   bash telemt-manager.sh --autoupdate on

set -o pipefail

readonly TELEMT_MANAGER_VERSION="2.0.0"
readonly TELEMT_MANAGER_CONFIG_DIR="/etc/telemt-manager"
readonly TELEMT_MANAGER_CONFIG="${TELEMT_MANAGER_CONFIG_DIR}/manager.conf"
readonly TELEMT_MANAGER_LOCK="/var/lock/telemt-manager.lock"
readonly TELEMT_AUTOUPDATE_SCRIPT="/usr/local/bin/telemt-autoupdate.sh"
readonly TELEMT_AUTOUPDATE_LOCK="/var/lock/telemt-autoupdate.lock"
readonly TELEMT_AUTOUPDATE_LOG="/var/log/telemt-autoupdate.log"
readonly TELEMT_BIN="/usr/local/bin/telemt"
readonly TELEMT_PANEL_BIN="/usr/local/bin/telemt-panel"
readonly TELEMT_SERVICE="/etc/systemd/system/telemt.service"
readonly TELEMT_PANEL_SERVICE="/etc/systemd/system/telemt-panel.service"
readonly TELEMT_CONFIG="/etc/telemt/telemt.toml"
readonly TELEMT_PANEL_CONFIG="/etc/telemt-panel/config.toml"
readonly TELEMT_PANEL_TLS_DIR="/etc/telemt-panel/tls"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

LOCK_FD=-1
TEMP_DIRS=()

# ==============================================================
# УТИЛИТЫ
# ==============================================================

info()  { echo -e "${GREEN}[+]${NC} $1" >&2; }
warn()  { echo -e "${YELLOW}[!]${NC} $1" >&2; }
error() { echo -e "${RED}[x]${NC} $1" >&2; }

cleanup_all() {
    for d in "${TEMP_DIRS[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    TEMP_DIRS=()
}

make_temp() {
    local d
    d=$(mktemp -d) || { error "Не удалось создать временную директорию"; return 1; }
    TEMP_DIRS+=("$d")
    echo "$d"
}

cleanup_temp() {
    local d="$1"
    local new=()
    for t in "${TEMP_DIRS[@]}"; do
        if [[ "$t" == "$d" ]]; then
            [[ -d "$d" ]] && rm -rf "$d"
        else
            new+=("$t")
        fi
    done
    TEMP_DIRS=("${new[@]}")
}

acquire_lock() {
    exec 200>"${TELEMT_MANAGER_LOCK}"
    if ! flock -n 200; then
        error "Другой экземпляр менеджера уже запущен (${TELEMT_MANAGER_LOCK})"
        exit 1
    fi
    LOCK_FD=200
}

release_lock() {
    if [[ $LOCK_FD -ne -1 ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        eval "exec ${LOCK_FD}>&-"
        LOCK_FD=-1
    fi
}

is_interactive() {
    [[ -t 0 ]]
}

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Запусти от root"
        exit 1
    fi
}

ensure_debian() {
    if [[ ! -f /etc/debian_version ]]; then
        error "Этот менеджер рассчитан на Debian/Ubuntu"
        exit 1
    fi
}

ensure_telemt_installed() {
    if ! systemctl is-active --quiet telemt 2>/dev/null; then
        error "Telemt не запущен. Установи сначала (--install)"
        exit 1
    fi
}

detect_arch() {
    local a
    a=$(uname -m)
    case "$a" in
        x86_64|amd64)
            if [[ -r /proc/cpuinfo ]] && grep -q "avx2" /proc/cpuinfo 2>/dev/null \
                    && grep -q "bmi2" /proc/cpuinfo 2>/dev/null; then
                echo "x86_64-v3"
            else
                echo "x86_64"
            fi
            ;;
        aarch64|arm64) echo "aarch64" ;;
        *) echo ""; return 1 ;;
    esac
}

detect_libc() {
    local f
    for f in /lib/ld-musl-*.so.* /lib64/ld-musl-*.so.*; do
        [[ -e "$f" ]] && { echo "musl"; return 0; }
    done
    if grep -qE '^ID="?alpine"?' /etc/os-release 2>/dev/null; then
        echo "musl"; return 0
    fi
    if command -v ldd &>/dev/null && ldd --version 2>&1 | grep -qi musl; then
        echo "musl"; return 0
    fi
    echo "gnu"
}

normalize_version() {
    echo "${1#v}"
}

port_busy() {
    local p="$1"
    ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
}

get_public_ip() {
    local ip
    ip=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s -4 --max-time 5 api.ipify.org 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s -4 --max-time 5 ipinfo.io/ip 2>/dev/null)
    echo "$ip"
}

# Чтение API_PORT из конфига Telemt
detect_api_port() {
    local default_port="9091"
    if [[ -f "$TELEMT_CONFIG" ]]; then
        local cfg_port
        cfg_port=$(grep -oP 'listen\s*=\s*"127\.0\.0\.1:\K[0-9]+' "$TELEMT_CONFIG" 2>/dev/null || echo "")
        if [[ -n "$cfg_port" ]]; then
            echo "$cfg_port"
            return 0
        fi
    fi
    echo "$default_port"
}

# Сохранение конфига менеджера
save_manager_config() {
    local key="$1" value="$2"
    mkdir -p "$TELEMT_MANAGER_CONFIG_DIR"
    umask 077
    if [[ -f "$TELEMT_MANAGER_CONFIG" ]]; then
        if grep -q "^${key}=" "$TELEMT_MANAGER_CONFIG" 2>/dev/null; then
            sed -i "s/^${key}=.*/${key}=${value}/" "$TELEMT_MANAGER_CONFIG"
        else
            echo "${key}=${value}" >> "$TELEMT_MANAGER_CONFIG"
        fi
    else
        echo "${key}=${value}" > "$TELEMT_MANAGER_CONFIG"
    fi
}

load_manager_config() {
    local key="$1" default="$2"
    if [[ -f "$TELEMT_MANAGER_CONFIG" ]]; then
        local val
        val=$(grep "^${key}=" "$TELEMT_MANAGER_CONFIG" 2>/dev/null | cut -d= -f2-)
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

# Восстановить права на конфиг после любого редактирования
_fix_config_perm() {
    [[ -f "$TELEMT_CONFIG" ]] || return 0
    chown root:telemt "$TELEMT_CONFIG" 2>/dev/null \
        || chown telemt:telemt "$TELEMT_CONFIG" 2>/dev/null || true
    chmod 640 "$TELEMT_CONFIG" 2>/dev/null || true
}

# Валидация порта
validate_port() {
    local p="$1" name="$2"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
        error "Некорректный порт ${name}: ${p}"
        return 1
    fi
    if port_busy "$p"; then
        error "Порт ${p} (${name}) уже занят"
        return 1
    fi
    return 0
}

# Валидация домена
validate_domain() {
    local d="$1"
    if [[ ! "$d" =~ ^[A-Za-z0-9.-]+$ ]] || [[ -z "$d" ]]; then
        error "Некорректный домен: ${d}"
        return 1
    fi
    return 0
}

# Валидация имени пользователя
validate_username() {
    local u="$1"
    if [[ -z "$u" ]]; then
        error "Имя не может быть пустым"
        return 1
    fi
    if [[ ! "$u" =~ ^[A-Za-z0-9_.-]+$ ]] || (( ${#u} > 64 )); then
        error "Допустимы только A-Za-z0-9_.- длиной до 64 символов"
        return 1
    fi
    return 0
}

_ensure_deps() {
    local pkgs=()
    command -v curl    &>/dev/null || pkgs+=("curl")
    command -v jq      &>/dev/null || pkgs+=("jq")
    command -v openssl &>/dev/null || pkgs+=("openssl")
    command -v tar     &>/dev/null || pkgs+=("tar")
    command -v setcap  &>/dev/null || pkgs+=("libcap2-bin")
    command -v flock   &>/dev/null || pkgs+=("util-linux")
    if (( ${#pkgs[@]} > 0 )); then
        info "Устанавливаю зависимости: ${pkgs[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
    fi
}

_install_telemt_bin() {
    local src="$1"
    install -m 0755 "$src" "$TELEMT_BIN" || return 1
    if command -v setcap &>/dev/null; then
        setcap cap_net_bind_service,cap_net_admin=+ep "$TELEMT_BIN" 2>/dev/null || true
    fi
}

_download_telemt() {
    local version="$1"
    local tmp="$2"
    local arch libc url archive sum_url expected_sum actual_sum

    arch=$(detect_arch) || { error "Неподдерживаемая архитектура: $(uname -m)"; return 1; }
    libc=$(detect_libc)

    _build_url() {
        local a="$1"
        if [[ "$version" == "latest" ]]; then
            echo "https://github.com/telemt/telemt/releases/latest/download/telemt-${a}-linux-${libc}.tar.gz"
        else
            echo "https://github.com/telemt/telemt/releases/download/${version}/telemt-${a}-linux-${libc}.tar.gz"
        fi
    }

    archive="${tmp}/telemt.tar.gz"
    url=$(_build_url "$arch")

    info "Скачиваю: $url"
    if ! curl -fsSL "$url" -o "$archive"; then
        if [[ "$arch" == "x86_64-v3" ]]; then
            warn "Сборка x86_64-v3 не найдена, откат на x86_64..."
            arch="x86_64"
            url=$(_build_url "$arch")
            info "Скачиваю: $url"
            if ! curl -fsSL "$url" -o "$archive"; then
                error "Не удалось скачать бинарь telemt"
                return 1
            fi
        else
            error "Не удалось скачать бинарь telemt"
            return 1
        fi
    fi

    # SHA256 верификация
    sum_url="${url}.sha256"
    expected_sum=$(curl -fsSL --max-time 5 "$sum_url" 2>/dev/null | grep -oE '^[a-f0-9]{64}' || true)
    if [[ -n "$expected_sum" ]]; then
        actual_sum=$(sha256sum "$archive" | awk '{print $1}')
        if [[ "$expected_sum" != "$actual_sum" ]]; then
            error "SHA256 не совпадает! Ожидалось: ${expected_sum}, получено: ${actual_sum}"
            return 1
        fi
        info "SHA256: OK"
    else
        warn "SHA256-файл не найден (${sum_url}), пропускаю проверку"
    fi

    if ! tar -xzf "$archive" -C "$tmp"; then
        error "Не удалось распаковать архив telemt"
        return 1
    fi
    rm -f "$archive"

    local found
    found=$(find "$tmp" -type f -name "telemt" -print 2>/dev/null | head -1)
    if [[ -z "$found" ]]; then
        found=$(find "$tmp" -type f -executable ! -name "*.tar.gz" -print 2>/dev/null | head -1)
    fi
    if [[ -z "$found" ]]; then
        error "Бинарь telemt не найден после распаковки"
        return 1
    fi

    echo "$found"
}

# Удаление UFW-правил по тегу
_ufw_delete_by_tag() {
    local tag="$1"
    if ! command -v ufw &>/dev/null; then return 0; fi
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then return 0; fi

    local lines nums n
    lines=$(ufw status numbered 2>/dev/null | grep -F "# ${tag}" | grep -oE '^\[[ 0-9]+\]' | tr -d '[] ')
    nums=$(echo "$lines" | sort -rn)
    for n in $nums; do
        [[ -z "$n" ]] && continue
        info "Удаляю UFW правило #${n} (тег ${tag})..."
        yes | ufw delete "$n" >/dev/null 2>&1 || true
    done
}

# Установка logrotate для автообновления
_ensure_logrotate() {
    local lr="/etc/logrotate.d/telemt-autoupdate"
    if [[ ! -f "$lr" ]]; then
        cat > "$lr" << 'EOF'
/var/log/telemt-autoupdate.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
EOF
        chmod 644 "$lr"
    fi
}

# Backup конфига Telemt
_backup_telemt_config() {
    local backup_dir="/var/backups/telemt"
    mkdir -p "$backup_dir"
    local stamp
    stamp=$(date '+%Y%m%d_%H%M%S')
    if [[ -f "$TELEMT_CONFIG" ]]; then
        cp "$TELEMT_CONFIG" "${backup_dir}/telemt.toml.${stamp}"
        info "Конфиг сохранён: ${backup_dir}/telemt.toml.${stamp}"
        # Оставляем только 5 последних бэкапов
        ls -t "${backup_dir}/telemt.toml."* 2>/dev/null | tail -n +6 | xargs -r rm -f
    fi
}

# ==============================================================
# УСТАНОВКА TELEMT
# ==============================================================

do_install() {
    local tls_domain_l="${TLS_DOMAIN:-www.gosuslugi.ru}"
    local proxy_port_l="${PROXY_PORT:-443}"
    local username_l="${PROXY_USER:-tguser}"
    local secret_l=""
    local use_middle_proxy_l="${USE_MIDDLE_PROXY:-true}"
    local non_interactive=false

    # Определяем, есть ли флаги командной строки
    if [[ -n "$FLAG_DOMAIN" || -n "$FLAG_PORT" || -n "$FLAG_USER" || -n "$FLAG_SECRET" || -n "$FLAG_MIDDLE_PROXY" ]]; then
        non_interactive=true
        [[ -n "$FLAG_DOMAIN" ]] && tls_domain_l="$FLAG_DOMAIN"
        [[ -n "$FLAG_PORT" ]] && proxy_port_l="$FLAG_PORT"
        [[ -n "$FLAG_USER" ]] && username_l="$FLAG_USER"
        [[ -n "$FLAG_SECRET" ]] && secret_l="$FLAG_SECRET"
        [[ -n "$FLAG_MIDDLE_PROXY" ]] && use_middle_proxy_l="$FLAG_MIDDLE_PROXY"
    fi

    if systemctl is-active --quiet telemt 2>/dev/null; then
        warn "Telemt уже запущен. Сначала удали (--remove)."
        return
    fi

    if [[ -z "$secret_l" ]]; then
        secret_l=$(openssl rand -hex 16)
    fi

    # Интерактивный выбор домена
    if ! $non_interactive; then
        echo ""
        echo -e "${CYAN}Домены маскировки (TLS 1.3 + HTTP/2):${NC}"
        echo "  --- Россия ---"
        echo "  1.  www.gosuslugi.ru     (по умолчанию)"
        echo "  2.  www.sberbank.ru"
        echo "  3.  www.tinkoff.ru"
        echo "  4.  www.yandex.ru"
        echo "  5.  www.ozon.ru"
        echo "  6.  www.wildberries.ru"
        echo "  --- Европа ---"
        echo "  7.  www.cloudflare.com"
        echo "  8.  www.bbc.co.uk"
        echo "  9.  www.bild.de"
        echo "  10. www.lufthansa.com"
        echo "  --- Своё ---"
        echo "  11. Свой домен"
        echo -ne " Выбор [1-11]: "; read -r domain_choice
        case $domain_choice in
            2)  tls_domain_l="www.sberbank.ru" ;;
            3)  tls_domain_l="www.tinkoff.ru" ;;
            4)  tls_domain_l="www.yandex.ru" ;;
            5)  tls_domain_l="www.ozon.ru" ;;
            6)  tls_domain_l="www.wildberries.ru" ;;
            7)  tls_domain_l="www.cloudflare.com" ;;
            8)  tls_domain_l="www.bbc.co.uk" ;;
            9)  tls_domain_l="www.m.bild.de" ;;
            10) tls_domain_l="www.lufthansa.com" ;;
            11)
                echo -ne " Введи домен (например: example.ru): "; read -r custom_domain
                [[ -z "$custom_domain" ]] && { error "Домен не может быть пустым"; return; }
                if ! validate_domain "$custom_domain"; then return; fi
                tls_domain_l="$custom_domain"
                ;;
        esac
        info "Домен маскировки: ${tls_domain_l}"

        echo ""
        echo -e "${CYAN}Use middle proxy (рекламная статистика Telegram):${NC}"
        echo "  1. true  — по умолчанию (рекомендуется)"
        echo "  2. false — без middle proxy"
        echo -ne " Выбор [1-2, Enter=1]: "; read -r mp_choice
        [[ "$mp_choice" == "2" ]] && use_middle_proxy_l="false"

        echo ""
        local port_candidates=(443 8443 2053 2083 2087 8080)
        local suggested_port=""
        echo -e "${CYAN}Статус стандартных портов:${NC}"
        for p in "${port_candidates[@]}"; do
            if port_busy "$p"; then
                echo "  [занят]    $p"
            else
                echo "  [свободен] $p"
                [[ -z "$suggested_port" ]] && suggested_port="$p"
            fi
        done
        echo ""
        if [[ -n "$suggested_port" ]]; then
            echo -ne " Использовать порт ${suggested_port}? [Enter = да / введи другой]: "
        else
            echo -ne " Все стандартные порты заняты. Введи порт вручную: "
        fi
        read -r port_input
        if [[ -z "$port_input" && -n "$suggested_port" ]]; then
            proxy_port_l="$suggested_port"
        elif [[ -n "$port_input" ]]; then
            if ! validate_port "$port_input" "прокси"; then return; fi
            proxy_port_l="$port_input"
        fi
    else
        # Неинтерактивный: валидируем переданные параметры
        if ! validate_domain "$tls_domain_l"; then return; fi
        if ! validate_port "$proxy_port_l" "прокси"; then return; fi
        if [[ "$use_middle_proxy_l" != "true" && "$use_middle_proxy_l" != "false" ]]; then
            error "USE_MIDDLE_PROXY должен быть true или false"
            return
        fi
    fi

    _ensure_deps

    local tmp
    tmp=$(make_temp) || return

    local extracted
    if ! extracted=$(_download_telemt "latest" "$tmp"); then
        cleanup_temp "$tmp"
        return
    fi

    info "Устанавливаю бинарь..."
    if ! _install_telemt_bin "$extracted"; then
        error "Не удалось установить бинарь telemt"
        cleanup_temp "$tmp"
        return
    fi
    cleanup_temp "$tmp"

    info "Получаю публичный IP..."
    local public_ip
    public_ip=$(get_public_ip)
    [[ -z "$public_ip" ]] && { error "Не удалось определить публичный IP"; return; }

    info "Создаю пользователя telemt..."
    umask 077
    if ! getent group telemt &>/dev/null; then
        groupadd -r telemt
    fi
    if ! id telemt &>/dev/null; then
        useradd -r -g telemt -d /opt/telemt -s /bin/false -c "Telemt Proxy" telemt
    fi
    mkdir -p /opt/telemt /opt/telemt/tlsfront
    chown -R telemt:telemt /opt/telemt
    chmod 750 /opt/telemt
    chmod 750 /opt/telemt/tlsfront

    info "Создаю конфиг..."
    mkdir -p /etc/telemt
    local domain_esc
    domain_esc=$(printf '%s' "$tls_domain_l" | sed 's/\\/\\\\/g; s/"/\\"/g')

    cat > "$TELEMT_CONFIG" << EOF
[general]
use_middle_proxy = ${use_middle_proxy_l}

[general.modes]
classic = false
secure = false
tls = true

[general.links]
public_host = "${public_ip}"

[server]
port = ${proxy_port_l}

[server.api]
enabled = true
listen = "127.0.0.1:${API_PORT}"
whitelist = ["127.0.0.1/32"]

[censorship]
tls_domain = "${domain_esc}"
mask = true
tls_emulation = true
tls_front_dir = "/opt/telemt/tlsfront"

[access.users]
${username_l} = "${secret_l}"
EOF

    chown telemt:telemt /etc/telemt
    chmod 750 /etc/telemt
    _fix_config_perm

    info "Создаю systemd unit..."
    cat > "$TELEMT_SERVICE" << 'EOF'
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$TELEMT_SERVICE"

    systemctl daemon-reload
    systemctl enable --now telemt

    # --- UFW ---
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        info "Открываю порт ${proxy_port_l}/tcp в UFW..."
        ufw allow "${proxy_port_l}/tcp" comment "TELEMT_MGR_PROXY" >/dev/null
    else
        warn "UFW не активен — порт ${proxy_port_l} открой вручную"
    fi

    info "Жду запуск..."
    sleep 8

    if ! systemctl is-active --quiet telemt; then
        error "Сервис не запустился. Проверь: journalctl -u telemt -n 30"
        return
    fi

    local api_port
    api_port=$(detect_api_port)

    # Ждём API (с retry)
    local link=""
    local attempt
    for attempt in 1 2 3 4 5; do
        link=$(curl -s --max-time 5 "http://127.0.0.1:${api_port}/v1/users" \
            | jq -r '.data[0].links.tls[]? | select(test("server=[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"))' \
            2>/dev/null | head -1 || true)
        [[ -n "$link" ]] && break
        sleep 3
    done

    # Сохраняем конфиг менеджера
    save_manager_config "TLS_DOMAIN" "$tls_domain_l"
    save_manager_config "PROXY_PORT" "$proxy_port_l"
    save_manager_config "USERNAME" "$username_l"
    save_manager_config "MIDDLE_PROXY" "$use_middle_proxy_l"
    save_manager_config "PUBLIC_IP" "$public_ip"

    echo ""
    echo "========================================"
    echo " Telemt установлен и запущен!"
    echo "========================================"
    echo " Порт:      ${proxy_port_l}"
    echo " TLS домен: ${tls_domain_l}"
    echo " Пользов.:  ${username_l}"
    echo " Секрет:    ${secret_l}"
    echo " Ссылка:    ${link}"

    # --- Автообновление включаем по умолчанию ---
    if ! crontab -l 2>/dev/null | grep -q "telemt-autoupdate"; then
        info "Включаю автообновление по умолчанию..."
        do_autoupdate_internal enable
    fi
}

# ==============================================================
# ССЫЛКИ / СТАТИСТИКА
# ==============================================================

do_links() {
    ensure_telemt_installed

    local api_port
    api_port=$(detect_api_port)
    local raw
    raw=$(curl -s --max-time 5 "http://127.0.0.1:${api_port}/v1/users" 2>/dev/null)
    if [[ -z "$raw" ]] || ! echo "$raw" | jq -e '.ok' &>/dev/null; then
        error "API (порт ${api_port}) не ответил. Проверь: systemctl status telemt"
        return
    fi

    local web_domain
    web_domain=$(load_manager_config DOMAIN "")
    if [[ -z "$web_domain" && -f "$TELEMT_CONFIG" ]]; then
        web_domain=$(awk '
            /^\[\[web\.vhosts\]\]/ { inv=1; next }
            /^\[/ { inv=0 }
            inv && /^[[:space:]]*host[[:space:]]*=/ {
                gsub(/[ "]/,"",$0)
                split($0,a,"=")
                print a[2]
                exit
            }' "$TELEMT_CONFIG" 2>/dev/null)
    fi
    local web_users=""
    local web_legacy
    web_legacy=$(load_manager_config WEB_USER "")
    if [[ -f "$TELEMT_CONFIG" ]]; then
        web_users=$(awk '
            /^\[\[web\.vhosts\.profiles\]\]/ { inp=1; next }
            /^\[/ { inp=0 }
            inp && /^[[:space:]]*user[[:space:]]*=/ {
                gsub(/[ "]/,"",$0)
                split($0,a,"=")
                print a[2]
            }' "$TELEMT_CONFIG" 2>/dev/null)
    fi
    if [[ -n "$web_legacy" ]] && ! echo "$web_users" | grep -qx "$web_legacy" 2>/dev/null; then
        web_users=$(printf '%s\n%s' "$web_users" "$web_legacy")
    fi

    echo ""
    echo -e "${CYAN}========== Ссылки клиентов ==========${NC}"
    while IFS= read -r line; do
        local uname
        uname=$(echo "$line" | jq -r '.username' 2>/dev/null)
        echo "  [${uname}]"
        local showed_web=false
        if [[ -n "$web_domain" ]] && echo "$web_users" | grep -qx "$uname" 2>/dev/null; then
            local usr_secret
            usr_secret=$(awk -v u="$uname" '
                /^\[access\.users\]$/ { inusers=1; next }
                /^\[/ { inusers=0 }
                inusers && $0 ~ "^"u"[[:space:]]*=" {
                    gsub(/[ "\t]/, "", $0)
                    split($0, a, "=")
                    print a[2]
                    exit
                }' "$TELEMT_CONFIG" 2>/dev/null)
            if [[ -n "$usr_secret" ]]; then
                echo "tg://webproxy?server=${web_domain}&secret=dd${usr_secret}"
                showed_web=true
            fi
        fi
        if ! $showed_web; then
            echo "$line" | jq -r '.links.tls[]?' 2>/dev/null
        fi
        echo ""
    done < <(echo "$raw" | jq -c '.data[]' 2>/dev/null)

    local summary
    summary=$(curl -s --max-time 5 "http://127.0.0.1:${api_port}/v1/stats/summary" 2>/dev/null)
    if echo "$summary" | jq -e '.ok' &>/dev/null; then
        local uptime total bad
        uptime=$(echo "$summary" | jq -r '.data.uptime_seconds | floor | tostring + " сек"')
        total=$(echo "$summary" | jq -r '.data.connections_total | tostring')
        bad=$(echo "$summary" | jq -r '.data.connections_bad_total | tostring')
        echo -e "${CYAN}======= Сервер =======${NC}"
        echo "  uptime: ${uptime} | всего подключений: ${total} | плохих: ${bad}"
        echo ""
    fi

    echo -e "${CYAN}======= Статистика =======${NC}"
    echo "$raw" | jq -r '.data[] |
        "  " + .username +
        " | онлайн: " + (.current_connections|tostring) +
        " | за 24ч IP: " + (.recent_unique_ips|tostring) +
        " | трафик: " + ((.total_octets / 1048576 * 100 | round) / 100 | tostring) + " MB"' \
        2>/dev/null
    echo ""
}

# ==============================================================
# ПОЛНОЕ УДАЛЕНИЕ TELEMT
# ==============================================================

do_remove() {
    if ! is_interactive; then
        info "Удаляю telemt (неинтерактивный режим)..."
    else
        echo -ne "${RED}Удалить telemt полностью? [y/N]: ${NC}"
        read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
    fi

    info "Останавливаю сервис..."
    systemctl stop telemt 2>/dev/null || true
    systemctl disable telemt 2>/dev/null || true

    info "Удаляю файлы..."
    rm -f "$TELEMT_SERVICE"
    rm -rf /etc/telemt
    rm -rf /opt/telemt
    rm -f "$TELEMT_BIN"

    info "Удаляю пользователя telemt..."
    if id telemt &>/dev/null; then
        userdel telemt 2>/dev/null || true
    fi
    if getent group telemt &>/dev/null; then
        groupdel telemt 2>/dev/null || true
    fi

    # Отключаем автообновление
    if crontab -l 2>/dev/null | grep -q "telemt-autoupdate"; then
        info "Отключаю автообновление..."
        crontab -l 2>/dev/null | grep -v "telemt-autoupdate" | crontab -
        rm -f "$TELEMT_AUTOUPDATE_SCRIPT"
        rm -f "$TELEMT_AUTOUPDATE_LOCK"
    fi

    systemctl daemon-reload
    _ufw_delete_by_tag "TELEMT_MGR_PROXY"

    info "Удаляю конфиг менеджера..."
    rm -f /etc/telemt-manager/manager.conf
    rm -f /var/log/telemt-autoupdate.log
    rmdir /etc/telemt-manager 2>/dev/null || true

    echo -e "${GREEN}[+] Telemt полностью удалён.${NC}"
}

# ==============================================================
# ДОБАВИТЬ / УДАЛИТЬ КЛИЕНТА
# ==============================================================

do_add_client() {
    ensure_telemt_installed

    local new_user=""
    if is_interactive && [[ -z "$FLAG_ADD_CLIENT" ]]; then
        echo -ne " Имя клиента [A-Za-z0-9_.-]: "; read -r new_user
    else
        new_user="$FLAG_ADD_CLIENT"
    fi

    if ! validate_username "$new_user"; then return; fi

    # Определяем тип прокси: mtproto (по умолчанию) или web
    local client_type="${FLAG_CLIENT_TYPE:-mtproto}"
    if is_interactive && [[ -z "$FLAG_CLIENT_TYPE" ]]; then
        echo ""
        echo -e "${CYAN} Тип прокси:${NC}"
        echo "   1) MTProto (tg://proxy, стандартный)"
        echo "   2) WEB (tg://webproxy, для Telegram Desktop)"
        echo -ne " Выбор [1/2]: "; read -r ctype
        case "$ctype" in
            2|web|WEB) client_type="web" ;;
            *)         client_type="mtproto" ;;
        esac
    fi
    if [[ "$client_type" != "mtproto" && "$client_type" != "web" ]]; then
        error "Неверный тип прокси: ${client_type} (допустимо: mtproto, web)"
        return
    fi

    if [[ "$client_type" == "web" ]]; then
        if ! grep -q '^\[web\]$' "$TELEMT_CONFIG" 2>/dev/null; then
            error "WEB-прокси не настроен. Сначала выполни --web-proxy"
            return
        fi
    fi

    local api_port
    api_port=$(detect_api_port)
    local resp
    resp=$(curl -s --max-time 5 -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${new_user}\"}" \
        "http://127.0.0.1:${api_port}/v1/users")

    if ! echo "$resp" | jq -e '.ok' &>/dev/null; then
        local err
        err=$(echo "$resp" | jq -r '.error.message // "неизвестная ошибка"' 2>/dev/null)
        error "Ошибка API: ${err}"
        return
    fi

    local new_secret link
    new_secret=$(echo "$resp" | jq -r '.data.secret // empty')

    # Для WEB-клиента: добавить профиль в [[web.vhosts.profiles]] и перезагрузить telemt
    if [[ "$client_type" == "web" ]]; then
        if ! grep -q "^user = \"${new_user}\"$" "$TELEMT_CONFIG" 2>/dev/null; then
            cat >> "$TELEMT_CONFIG" << EOF

[[web.vhosts.profiles]]
user = "${new_user}"
secret_mode = "dd"
max_sessions = 8
max_streams = 512
max_streams_per_session = 64
EOF
            _fix_config_perm
            systemctl reload telemt 2>/dev/null || systemctl restart telemt 2>/dev/null || true
            sleep 2
        else
            info "Профиль ${new_user} уже существует в WEB-конфиге"
        fi

        local web_domain
        web_domain=$(load_manager_config "DOMAIN" "")
        [[ -z "$web_domain" ]] && web_domain=$(load_manager_config "SETUP_DOMAIN" "")
        if [[ -n "$new_secret" ]]; then
            link="tg://webproxy?server=${web_domain}&secret=dd${new_secret}"
        else
            local cfg_secret
            cfg_secret=$(grep -oP "^${new_user}\s*=\s*\"\K[0-9a-fA-F]{32}" "$TELEMT_CONFIG" | head -1)
            [[ -n "$cfg_secret" ]] && link="tg://webproxy?server=${web_domain}&secret=dd${cfg_secret}"
        fi
    else
        link=$(echo "$resp" | jq -r '.data.user.links.tls[]?' 2>/dev/null | head -1)
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Клиент добавлен!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e " Имя:    ${new_user}"
    echo -e " Тип:    ${client_type}"
    [[ -n "$new_secret" ]] && echo -e " Секрет: ${new_secret}"
    echo ""
    if [[ -n "$link" ]]; then
        echo -e " Ссылка TG:"
        echo -e " ${GREEN}${link}${NC}"
    else
        warn "Ссылка не получена — проверь --links"
    fi
    echo ""
}

do_del_client() {
    ensure_telemt_installed

    local del_user=""
    if is_interactive && [[ -z "$FLAG_DEL_CLIENT" ]]; then
        local api_port
        api_port=$(detect_api_port)
        echo ""
        echo -e "${CYAN}Текущие клиенты:${NC}"
        local users_raw
        users_raw=$(curl -s --max-time 5 "http://127.0.0.1:${api_port}/v1/users" 2>/dev/null)
        if ! echo "$users_raw" | jq -e '.ok' &>/dev/null; then
            error "API не ответил"
            return
        fi
        local -a user_list
        mapfile -t user_list < <(echo "$users_raw" | jq -r '.data[].username' 2>/dev/null)
        if [[ ${#user_list[@]} -eq 0 ]]; then
            warn "Клиентов нет."
            return
        fi
        for i in "${!user_list[@]}"; do
            echo "  $((i+1))) ${user_list[$i]}"
        done
        echo ""
        echo -ne " Номер клиента для удаления: "; read -r num_choice
        if ! [[ "$num_choice" =~ ^[0-9]+$ ]] \
                || [[ "$num_choice" -lt 1 ]] \
                || [[ "$num_choice" -gt "${#user_list[@]}" ]]; then
            error "Некорректный номер."
            return
        fi
        del_user="${user_list[$((num_choice-1))]}"
    else
        del_user="$FLAG_DEL_CLIENT"
    fi

    [[ -z "$del_user" ]] && { error "Имя не может быть пустым"; return; }

    if is_interactive && [[ -z "$FLAG_DEL_CLIENT" ]]; then
        echo -ne "${RED}Удалить '${del_user}'? [y/N]: ${NC}"
        read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
    fi

    local api_port
    api_port=$(detect_api_port)

    local is_web_del=false
    if [[ -f "$TELEMT_CONFIG" ]] && \
            grep -q '^\[\[web\.vhosts\.profiles\]\]' "$TELEMT_CONFIG" 2>/dev/null; then
        is_web_del=$(python3 - "$del_user" "$TELEMT_CONFIG" <<'PYEOF'
import re, sys
user, path = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
out, i, removed = [], 0, False
while i < len(lines):
    line = lines[i]
    if line.startswith('[[web.vhosts.profiles]]'):
        block, j = [line], i + 1
        while j < len(lines) and not lines[j].startswith('['):
            block.append(lines[j]); j += 1
        if any(re.match(r'^user\s*=\s*"' + re.escape(user) + r'"\s*$', b) for b in block):
            i = j; removed = True
            continue
    out.append(line); i += 1
open(path, 'w').write('\n'.join(out) + ('\n' if out else ''))
print('true' if removed else 'false')
PYEOF
)
    fi

    if [[ "$is_web_del" == "true" ]]; then
        _fix_config_perm
        info "Удаляю WEB-профиль '${del_user}' из конфига..."
    fi

    local resp
    resp=$(curl -s --max-time 5 -X DELETE \
        "http://127.0.0.1:${api_port}/v1/users/${del_user}")

    if echo "$resp" | jq -e '.ok' &>/dev/null; then
        info "Клиент '${del_user}' удалён."
        if $is_web_del; then
            systemctl reload telemt 2>/dev/null || systemctl restart telemt 2>/dev/null || true
        fi
    else
        local err
        err=$(echo "$resp" | jq -r '.error.message // "неизвестная ошибка"' 2>/dev/null)
        error "Ошибка API: ${err}"
    fi
}

# ==============================================================
# УСТАНОВКА ПАНЕЛИ
# ==============================================================

do_install_panel() {
    local panel_port="${FLAG_PANEL_PORT:-8080}"
    local panel_user="${FLAG_PANEL_USER:-admin}"
    local panel_pass="$FLAG_PANEL_PASS"
    local non_interactive=false

    if [[ -n "$FLAG_PANEL_PORT" || -n "$FLAG_PANEL_USER" || -n "$FLAG_PANEL_PASS" ]]; then
        non_interactive=true
    fi

    if systemctl is-active --quiet telemt-panel 2>/dev/null; then
        warn "Панель уже запущена."
        return
    fi

    # Интерактивный ввод
    if ! $non_interactive; then
        echo ""
        echo -ne " Порт панели [по умолчанию 8080]: "; read -r panel_port_input
        panel_port="${panel_port_input:-8080}"
        echo -ne " Логин администратора [по умолчанию admin]: "; read -r panel_user_input
        panel_user="${panel_user_input:-admin}"

        if ! is_interactive; then
            error "Нет TTY — пароль ввести нельзя. Используй --panel-pass"
            return
        fi
        echo -ne " Пароль администратора: "; read -rs panel_pass < /dev/tty; echo ""
        [[ -z "$panel_pass" ]] && { error "Пароль не может быть пустым"; return; }
    fi

    # Валидация
    if ! validate_port "$panel_port" "панели"; then return; fi
    # Проверка что порт панели не совпадает с портом прокси
    local proxy_port
    proxy_port=$(load_manager_config "PROXY_PORT" "443")
    if [[ "$panel_port" == "$proxy_port" ]]; then
        error "Порт панели (${panel_port}) совпадает с портом прокси (${proxy_port})"
        return
    fi
    # Проверка API_PORT
    local api_port
    api_port=$(detect_api_port)
    if [[ "$panel_port" == "$api_port" ]]; then
        error "Порт панели (${panel_port}) совпадает с портом API Telemt (${api_port})"
        return
    fi

    if [[ -z "$panel_pass" ]]; then
        error "Пароль администратора не задан. Используй --panel-pass"
        return
    fi

    _ensure_deps

    # bcrypt
    info "Готовлю bcrypt..."
    if ! python3 -c "import bcrypt" &>/dev/null; then
        if command -v pip3 &>/dev/null || command -v pip &>/dev/null; then
            (pip3 install bcrypt --break-system-packages -q 2>/dev/null \
                || pip install bcrypt --break-system-packages -q 2>/dev/null) || true
        fi
        if ! python3 -c "import bcrypt" &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-bcrypt 2>/dev/null || true
        fi
        if ! python3 -c "import bcrypt" &>/dev/null; then
            error "Не удалось установить модуль bcrypt"
            return
        fi
    fi

    local pass_hash
    pass_hash=$(printf '%s' "${panel_pass}" | python3 -c "
import bcrypt, sys
pw = sys.stdin.read().encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt(10)).decode())
" 2>/dev/null)
    [[ -z "$pass_hash" ]] && { error "Не удалось сгенерировать хеш пароля"; return; }

    # Очищаем пароль из переменной
    panel_pass=""

    local jwt_secret
    jwt_secret=$(openssl rand -hex 32)

    info "Определяю архитектуру..."
    local arch arch_suffix
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  arch_suffix="x86_64" ;;
        aarch64|arm64) arch_suffix="aarch64" ;;
        *) error "Неподдерживаемая архитектура: $arch"; return ;;
    esac
    local binary_name="telemt-panel-${arch_suffix}-linux-gnu.tar.gz"

    info "Получаю последний релиз панели..."
    local download_url
    download_url=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest" \
        | jq -r --arg bn "$binary_name" '.assets[]? | select(.name == $bn) | .browser_download_url')
    [[ -z "$download_url" ]] && { error "Не удалось найти бинарь ${binary_name} в релизе"; return; }

    local tmp
    tmp=$(make_temp) || return

    info "Скачиваю: $download_url"
    if ! curl -fsSL "$download_url" -o "${tmp}/panel.tar.gz"; then
        cleanup_temp "$tmp"
        error "Не удалось скачать архив"
        return
    fi

    # SHA256
    local sum_url expected_sum actual_sum
    sum_url="${download_url}.sha256"
    expected_sum=$(curl -fsSL --max-time 5 "$sum_url" 2>/dev/null | grep -oE '^[a-f0-9]{64}' || true)
    if [[ -n "$expected_sum" ]]; then
        actual_sum=$(sha256sum "${tmp}/panel.tar.gz" | awk '{print $1}')
        if [[ "$expected_sum" != "$actual_sum" ]]; then
            cleanup_temp "$tmp"
            error "SHA256 панели не совпадает!"
            return
        fi
        info "SHA256 панели: OK"
    else
        warn "SHA256-файл для панели не найден, пропускаю проверку"
    fi

    if ! tar -xzf "${tmp}/panel.tar.gz" -C "$tmp"; then
        cleanup_temp "$tmp"
        error "Не удалось распаковать архив панели"
        return
    fi
    rm -f "${tmp}/panel.tar.gz"

    local extracted_bin
    extracted_bin=$(find "$tmp" -type f -name "telemt-panel-*-linux" -print 2>/dev/null | head -1)
    if [[ -z "$extracted_bin" ]]; then
        extracted_bin=$(find "$tmp" -type f -executable -print 2>/dev/null | head -1)
    fi
    [[ -z "$extracted_bin" ]] && { cleanup_temp "$tmp"; error "Бинарь не найден после распаковки"; return; }
    install -m 0755 "$extracted_bin" "$TELEMT_PANEL_BIN"
    cleanup_temp "$tmp"

    info "Генерирую самоподписанный TLS сертификат..."
    warn "ВНИМАНИЕ: используется самоподписанный сертификат. Замени на Let's Encrypt для production."
    umask 077
    mkdir -p "$TELEMT_PANEL_TLS_DIR"
    local public_ip
    public_ip=$(get_public_ip)
    [[ -z "$public_ip" ]] && public_ip="127.0.0.1"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "${TELEMT_PANEL_TLS_DIR}/key.pem" \
        -out    "${TELEMT_PANEL_TLS_DIR}/cert.pem" \
        -subj   "/CN=${public_ip}" \
        -addext "subjectAltName=IP:${public_ip}" \
        2>/dev/null
    chmod 600 "${TELEMT_PANEL_TLS_DIR}/key.pem"
    chmod 644 "${TELEMT_PANEL_TLS_DIR}/cert.pem"

    info "Создаю конфиг панели..."
    cat > "$TELEMT_PANEL_CONFIG" << EOF
listen = "0.0.0.0:${panel_port}"

[telemt]
url = "http://127.0.0.1:${api_port}"
auth_header = ""
binary_path = "${TELEMT_BIN}"
service_name = "telemt"
github_repo = "telemt/telemt"

[panel]
binary_path = "${TELEMT_PANEL_BIN}"
service_name = "telemt-panel"
github_repo = "amirotin/telemt_panel"

[auth]
username = "${panel_user}"
password_hash = "${pass_hash}"
jwt_secret = "${jwt_secret}"
session_ttl = "24h"

[tls]
cert_file = "${TELEMT_PANEL_TLS_DIR}/cert.pem"
key_file  = "${TELEMT_PANEL_TLS_DIR}/key.pem"
EOF
    chmod 600 "$TELEMT_PANEL_CONFIG"

    info "Создаю systemd unit..."
    cat > "$TELEMT_PANEL_SERVICE" << EOF
[Unit]
Description=Telemt Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${TELEMT_PANEL_BIN} --config ${TELEMT_PANEL_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$TELEMT_PANEL_SERVICE"

    systemctl daemon-reload
    systemctl enable --now telemt-panel

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        info "Открываю порт ${panel_port}/tcp в UFW..."
        ufw allow "${panel_port}/tcp" comment "TELEMT_MGR_PANEL" >/dev/null
    else
        warn "UFW не активен — порт ${panel_port} открой вручную"
    fi

    info "Жду запуск..."
    sleep 3

    if ! systemctl is-active --quiet telemt-panel; then
        error "Панель не запустилась. Проверь: journalctl -u telemt-panel -n 30"
        return
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Telemt Panel установлена!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e " URL:    ${GREEN}https://${public_ip}:${panel_port}${NC}"
    echo -e " Логин:  ${panel_user}"
    echo -e " ВНИМАНИЕ: сертификат самоподписанный — прими в браузере"
    echo ""
}

# ==============================================================
# УДАЛЕНИЕ ПАНЕЛИ
# ==============================================================

do_remove_panel() {
    if ! is_interactive; then
        info "Удаляю панель (неинтерактивный режим)..."
    else
        echo -ne "${RED}Удалить панель полностью? [y/N]: ${NC}"
        read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
    fi

    info "Останавливаю панель..."
    systemctl stop telemt-panel 2>/dev/null || true
    systemctl disable telemt-panel 2>/dev/null || true

    info "Удаляю файлы..."
    rm -f "$TELEMT_PANEL_SERVICE"
    rm -rf /etc/telemt-panel
    rm -f "$TELEMT_PANEL_BIN"

    systemctl daemon-reload
    _ufw_delete_by_tag "TELEMT_MGR_PANEL"

    echo -e "${GREEN}[+] Панель полностью удалена.${NC}"
}

# ==============================================================
# ОБНОВЛЕНИЕ TELEMT
# ==============================================================

do_update_telemt() {
    if [[ ! -f "$TELEMT_SERVICE" ]] && [[ ! -x "$TELEMT_BIN" ]]; then
        error "Telemt не установлен"
        return
    fi

    local api_port current latest_raw latest
    api_port=$(detect_api_port)
    current=$(curl -s --max-time 5 "http://127.0.0.1:${api_port}/v1/system/info" \
        | jq -r '.data.version // "unknown"' 2>/dev/null)
    current=$(normalize_version "$current")

    local upd_choice=1
    local custom_ver=""

    if is_interactive; then
        latest_raw=$(curl -s --max-time 10 "https://api.github.com/repos/telemt/telemt/releases/latest" \
            | jq -r '.tag_name // "unknown"')
        latest=$(normalize_version "$latest_raw")

        echo ""
        echo -e " Установлена: ${CYAN}${current}${NC}"
        echo -e " Последняя стабильная: ${CYAN}${latest}${NC}"
        echo ""
        echo "  1. Обновить до последней стабильной (${latest})"
        echo "  2. Установить конкретную версию (pre-release)"
        echo "  0. Назад"
        echo -ne " Выбор: "; read -r upd_choice
    fi

    case $upd_choice in
        1)
            latest_raw=$(curl -s --max-time 10 "https://api.github.com/repos/telemt/telemt/releases/latest" \
                | jq -r '.tag_name // "unknown"')
            latest=$(normalize_version "$latest_raw")
            if [[ "$current" == "$latest" && "$latest" != "unknown" ]]; then
                info "Уже установлена последняя стабильная версия."
                return
            fi
            if is_interactive; then
                echo -ne " Обновить до ${latest}? [y/N]: "; read -r confirm
                [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
            fi
            _backup_telemt_config
            if _do_telemt_binary_update "latest"; then
                info "Telemt обновлён до ${latest}"
            fi
            ;;
        2)
            echo ""
            info "Ищу последний pre-release..."
            local prerelease_raw prerelease
            prerelease_raw=$(curl -s --max-time 10 \
                "https://api.github.com/repos/telemt/telemt/releases?per_page=10" \
                | jq -r '[.[] | select(.prerelease == true)] | first | .tag_name // ""')
            prerelease=$(normalize_version "$prerelease_raw")

            if [[ -n "$prerelease" ]]; then
                echo -e " Последний pre-release: ${YELLOW}${prerelease}${NC}"
            fi
            echo ""
            echo -e " Доступные релизы: ${CYAN}https://github.com/telemt/telemt/releases${NC}"
            echo -ne " Введи версию [Enter = ${prerelease:-вручную}]: "; read -r custom_ver
            [[ -z "$custom_ver" && -n "$prerelease" ]] && custom_ver="$prerelease"
            [[ -z "$custom_ver" ]] && { error "Версия не может быть пустой"; return; }
            custom_ver=$(normalize_version "$custom_ver")
            if [[ ! "$custom_ver" =~ ^[0-9A-Za-z._-]+$ ]]; then
                error "Некорректная версия: $custom_ver"
                return
            fi
            if is_interactive; then
                echo -ne " Установить версию ${custom_ver}? [y/N]: "; read -r confirm
                [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
            fi
            _backup_telemt_config
            if _do_telemt_binary_update "$custom_ver"; then
                info "Telemt ${custom_ver} установлен"
            fi
            ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
}

_do_telemt_binary_update() {
    local version="$1"
    local tmp
    tmp=$(make_temp) || return 1

    local extracted
    if ! extracted=$(_download_telemt "$version" "$tmp"); then
        cleanup_temp "$tmp"
        return 1
    fi

    info "Останавливаю сервис..."
    systemctl stop telemt 2>/dev/null || true

    if ! _install_telemt_bin "$extracted"; then
        error "Не удалось установить бинарь"
        systemctl start telemt 2>/dev/null || true
        cleanup_temp "$tmp"
        return 1
    fi
    cleanup_temp "$tmp"

    info "Запускаю сервис..."
    systemctl start telemt
    sleep 3

    if systemctl is-active --quiet telemt; then
        return 0
    else
        error "Сервис не запустился. Проверь: journalctl -u telemt -n 30"
        return 1
    fi
}

# ==============================================================
# ОБНОВЛЕНИЕ ПАНЕЛИ
# ==============================================================

do_update_panel() {
    if [[ ! -f "$TELEMT_PANEL_BIN" ]]; then
        error "Панель не установлена."
        return
    fi

    local arch arch_suffix
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  arch_suffix="x86_64" ;;
        aarch64|arm64) arch_suffix="aarch64" ;;
        *) error "Неподдерживаемая архитектура: $arch"; return ;;
    esac
    local binary_name="telemt-panel-${arch_suffix}-linux-gnu.tar.gz"

    local latest_raw latest
    latest_raw=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest" \
        | jq -r '.tag_name // "unknown"')
    latest=$(normalize_version "$latest_raw")
    echo -e " Последняя версия панели: ${CYAN}${latest}${NC}"

    if is_interactive; then
        echo ""
        echo -ne " Обновить панель до ${latest}? [y/N]: "; read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
    fi

    local download_url
    download_url=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest" \
        | jq -r --arg bn "$binary_name" '.assets[]? | select(.name == $bn) | .browser_download_url')
    [[ -z "$download_url" ]] && { error "Не удалось найти бинарь в релизе"; return; }

    local tmp
    tmp=$(make_temp) || return

    info "Скачиваю: $download_url"
    if ! curl -fsSL "$download_url" -o "${tmp}/panel.tar.gz"; then
        cleanup_temp "$tmp"
        error "Не удалось скачать архив"
        return
    fi

    if ! tar -xzf "${tmp}/panel.tar.gz" -C "$tmp"; then
        cleanup_temp "$tmp"
        error "Не удалось распаковать архив"
        return
    fi
    rm -f "${tmp}/panel.tar.gz"

    local extracted_bin
    extracted_bin=$(find "$tmp" -type f -name "telemt-panel-*-linux" -print 2>/dev/null | head -1)
    if [[ -z "$extracted_bin" ]]; then
        extracted_bin=$(find "$tmp" -type f -executable -print 2>/dev/null | head -1)
    fi
    [[ -z "$extracted_bin" ]] && { cleanup_temp "$tmp"; error "Бинарь не найден после распаковки"; return; }
    cleanup_temp "$tmp"

    # Backup конфига панели
    if [[ -f "$TELEMT_PANEL_CONFIG" ]]; then
        local backup_dir="/var/backups/telemt-panel"
        mkdir -p "$backup_dir"
        local stamp
        stamp=$(date '+%Y%m%d_%H%M%S')
        cp "$TELEMT_PANEL_CONFIG" "${backup_dir}/config.toml.${stamp}"
        info "Конфиг панели сохранён: ${backup_dir}/config.toml.${stamp}"
        ls -t "${backup_dir}/config.toml."* 2>/dev/null | tail -n +6 | xargs -r rm -f
    fi

    info "Останавливаю панель..."
    systemctl stop telemt-panel 2>/dev/null || true
    install -m 0755 "$extracted_bin" "$TELEMT_PANEL_BIN"

    info "Запускаю обновлённую панель..."
    systemctl start telemt-panel
    sleep 3

    if systemctl is-active --quiet telemt-panel; then
        info "Панель обновлена до ${latest}"
    else
        error "Панель не запустилась. Проверь: journalctl -u telemt-panel -n 30"
    fi
}

# ==============================================================
# АВТООБНОВЛЕНИЕ
# ==============================================================

do_autoupdate() {
    local subcommand="${1:-$FLAG_AUTOUPDATE}"
    local is_enabled=false
    crontab -l 2>/dev/null | grep -q "telemt-autoupdate" && is_enabled=true

    echo ""
    if $is_enabled; then
        echo -e " Автообновление: ${GREEN}ВКЛЮЧЕНО${NC} (каждые 3 часа)"
    else
        echo -e " Автообновление: ${RED}ВЫКЛЮЧЕНО${NC}"
    fi

    if is_interactive && [[ -z "$subcommand" ]]; then
        echo ""
        echo "  1. Включить автообновление"
        echo "  2. Выключить автообновление"
        echo "  3. Показать лог обновлений"
        echo "  0. Назад"
        echo -ne " Выбор: "; read -r au_choice
        case $au_choice in
            1) do_autoupdate_internal enable ;;
            2) do_autoupdate_internal disable ;;
            3) do_autoupdate_internal log ;;
        esac
    else
        case "$subcommand" in
            enable|on|1)  do_autoupdate_internal enable ;;
            disable|off|0) do_autoupdate_internal disable ;;
            log|show)     do_autoupdate_internal log ;;
            *) warn "Неизвестная команда: ${subcommand}. Используй: enable|disable|log" ;;
        esac
    fi
}

do_autoupdate_internal() {
    local action="$1"
    local cron_job="0 */3 * * * ${TELEMT_AUTOUPDATE_SCRIPT}"

    case "$action" in
        enable)
            if ! command -v crontab &>/dev/null; then
                info "Устанавливаю cron..."
                DEBIAN_FRONTEND=noninteractive apt-get update -qq
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron
                systemctl enable --now cron 2>/dev/null || true
            fi

            # Читаем актуальный API_PORT из конфига для скрипта автообновления
            local detected_api_port
            detected_api_port=$(detect_api_port)

            local au_tmp
            au_tmp=$(make_temp) || return
            cat > "${au_tmp}/autoupdate.sh" << 'AUEOF'
#!/bin/bash
# Auto-generated by telemt-manager.sh
set -o pipefail

API_PORT="__API_PORT__"
LOG="__LOG__"
LOCK="__LOCK__"
BIN="__BIN__"
PANEL_BIN="__PANEL_BIN__"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

exec 200>"$LOCK"
if ! flock -n 200; then
    log "Other instance already running, exiting."
    exit 0
fi

norm_ver() { echo "${1#v}"; }

detect_arch() {
    local a
    a=$(uname -m)
    case "$a" in
        x86_64|amd64)
            if [[ -r /proc/cpuinfo ]] && grep -q "avx2" /proc/cpuinfo 2>/dev/null \
                    && grep -q "bmi2" /proc/cpuinfo 2>/dev/null; then
                echo "x86_64-v3"
            else
                echo "x86_64"
            fi
            ;;
        aarch64|arm64) echo "aarch64" ;;
        *) echo ""; return 1 ;;
    esac
}

detect_libc() {
    local f
    for f in /lib/ld-musl-*.so.* /lib64/ld-musl-*.so.*; do
        [[ -e "$f" ]] && { echo "musl"; return 0; }
    done
    grep -qE '^ID="?alpine"?' /etc/os-release 2>/dev/null && { echo "musl"; return 0; }
    if command -v ldd &>/dev/null && ldd --version 2>&1 | grep -qi musl; then
        echo "musl"; return 0
    fi
    echo "gnu"
}

# === Telemt ===
if systemctl is-active --quiet telemt 2>/dev/null; then
    CURRENT_RAW=$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/v1/system/info" | jq -r '.data.version // ""')
    LATEST_RAW=$(curl -s --max-time 10 "https://api.github.com/repos/telemt/telemt/releases/latest" | jq -r '.tag_name // ""')
    CURRENT=$(norm_ver "$CURRENT_RAW")
    LATEST=$(norm_ver "$LATEST_RAW")

    if [[ -z "$LATEST" ]]; then
        log "Telemt: could not fetch latest version"
    elif [[ -z "$CURRENT" ]]; then
        log "Telemt: API did not respond"
    elif [[ "$CURRENT" != "$LATEST" ]]; then
        log "Telemt: updating $CURRENT -> $LATEST"
        ARCH=$(detect_arch); LIBC=$(detect_libc)
        if [[ -z "$ARCH" ]]; then
            log "Telemt: unsupported architecture"
        else
            TMP=$(mktemp -d)
            trap 'rm -rf "$TMP"' RETURN
            URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC}.tar.gz"
            ARCHIVE="${TMP}/telemt.tar.gz"

            if ! curl -fsSL --max-time 60 "$URL" -o "$ARCHIVE"; then
                if [[ "$ARCH" == "x86_64-v3" ]]; then
                    log "Telemt: x86_64-v3 not found, fallback to x86_64"
                    ARCH="x86_64"
                    URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC}.tar.gz"
                    curl -fsSL --max-time 60 "$URL" -o "$ARCHIVE" || { log "Telemt: download failed"; exit 1; }
                else
                    log "Telemt: download failed"; exit 1
                fi
            fi

            if tar -xzf "$ARCHIVE" -C "$TMP"; then
                EXT=$(find "$TMP" -type f -name "telemt" | head -1)
                [[ -z "$EXT" ]] && EXT=$(find "$TMP" -type f -executable ! -name "*.tar.gz" | head -1)
                if [[ -n "$EXT" ]]; then
                    systemctl stop telemt
                    if install -m 0755 "$EXT" "$BIN"; then
                        command -v setcap &>/dev/null && \
                            setcap cap_net_bind_service,cap_net_admin=+ep "$BIN" 2>/dev/null
                        systemctl start telemt
                        sleep 3
                        if systemctl is-active --quiet telemt; then
                            log "Telemt: updated to $LATEST"
                        else
                            log "Telemt: service failed to start after update!"
                        fi
                    else
                        log "Telemt: install failed"
                        systemctl start telemt
                    fi
                else
                    log "Telemt: binary not found after extraction"
                fi
            else
                log "Telemt: extraction failed"
            fi
        fi
    else
        log "Telemt: $CURRENT (up to date)"
    fi
fi

# === Panel ===
if [[ -f "$PANEL_BIN" ]]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)  AS="x86_64" ;;
        aarch64|arm64) AS="aarch64" ;;
        *) log "Panel: unsupported architecture"; exit 0 ;;
    esac
    BN="telemt-panel-${AS}-linux-gnu.tar.gz"

    PANEL_API=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest")
    LATEST_P_RAW=$(echo "$PANEL_API" | jq -r '.tag_name // ""')
    CURRENT_P_RAW=$($PANEL_BIN version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    LATEST_P=$(norm_ver "$LATEST_P_RAW")
    CURRENT_P=$(norm_ver "$CURRENT_P_RAW")

    if [[ -z "$LATEST_P" ]]; then
        log "Panel: could not fetch latest version"
    elif [[ "$CURRENT_P" != "$LATEST_P" ]]; then
        log "Panel: updating $CURRENT_P -> $LATEST_P"
        DL=$(echo "$PANEL_API" | jq -r --arg bn "$BN" '.assets[]? | select(.name == $bn) | .browser_download_url')
        if [[ -n "$DL" ]]; then
            TMP=$(mktemp -d)
            trap 'rm -rf "$TMP"' RETURN
            if curl -fsSL --max-time 60 "$DL" -o "${TMP}/panel.tar.gz" \
                    && tar -xzf "${TMP}/panel.tar.gz" -C "$TMP"; then
                EX=$(find "$TMP" -type f -name "telemt-panel-*-linux" | head -1)
                [[ -z "$EX" ]] && EX=$(find "$TMP" -type f -executable | head -1)
                if [[ -n "$EX" ]]; then
                    systemctl stop telemt-panel
                    if install -m 0755 "$EX" "$PANEL_BIN"; then
                        systemctl start telemt-panel
                        sleep 3
                        if systemctl is-active --quiet telemt-panel; then
                            log "Panel: updated to $LATEST_P"
                        else
                            log "Panel: service failed to start after update!"
                        fi
                    else
                        log "Panel: install failed"
                        systemctl start telemt-panel
                    fi
                else
                    log "Panel: binary not found after extraction"
                fi
            else
                log "Panel: download or extraction failed"
            fi
        else
            log "Panel: no download URL found for $BN"
        fi
    else
        log "Panel: $CURRENT_P (up to date)"
    fi
fi
AUEOF
            # Substitute markers with actual values
            sed -i "s|__API_PORT__|${detected_api_port}|g" "${au_tmp}/autoupdate.sh"
            sed -i "s|__LOG__|${TELEMT_AUTOUPDATE_LOG}|g" "${au_tmp}/autoupdate.sh"
            sed -i "s|__LOCK__|${TELEMT_AUTOUPDATE_LOCK}|g" "${au_tmp}/autoupdate.sh"
            sed -i "s|__BIN__|${TELEMT_BIN}|g" "${au_tmp}/autoupdate.sh"
            sed -i "s|__PANEL_BIN__|${TELEMT_PANEL_BIN}|g" "${au_tmp}/autoupdate.sh"

            install -m 0755 "${au_tmp}/autoupdate.sh" "$TELEMT_AUTOUPDATE_SCRIPT"
            cleanup_temp "$au_tmp"
            chmod +x "$TELEMT_AUTOUPDATE_SCRIPT"
            ( crontab -l 2>/dev/null | grep -v "telemt-autoupdate"; echo "$cron_job" ) | crontab -

            # Logrotate
            _ensure_logrotate

            info "Автообновление включено — каждые 3 часа"
            info "Логи: ${TELEMT_AUTOUPDATE_LOG}"
            ;;
        disable)
            crontab -l 2>/dev/null | grep -v "telemt-autoupdate" | crontab -
            rm -f "$TELEMT_AUTOUPDATE_SCRIPT"
            rm -f "$TELEMT_AUTOUPDATE_LOCK"
            info "Автообновление отключено"
            ;;
        log)
            if [[ -f "$TELEMT_AUTOUPDATE_LOG" ]]; then
                echo ""
                tail -30 "$TELEMT_AUTOUPDATE_LOG"
            else
                warn "Лог пустой — обновлений ещё не было"
            fi
            ;;
    esac
}

# ==============================================================
# AD TAG
# ==============================================================

do_ad_tag() {
    ensure_telemt_installed

    local action="${1:-$FLAG_AD_TAG}"

    if [[ -z "$action" ]]; then
        echo ""
        echo "--- AD TAG ---"
        echo -n " Глобальный: "
        local global_tag
        global_tag=$(grep -Po '(?<=^ad_tag = ")[^"]*' "$TELEMT_CONFIG" 2>/dev/null || true)
        if [[ -n "$global_tag" ]]; then
            echo "$global_tag"
        else
            echo "не задан"
        fi

        local user_tags
        user_tags=$(sed -n '/^\[access\.user_ad_tags\]/,/^\[/p' "$TELEMT_CONFIG" 2>/dev/null | grep -v '^\[' | grep -v '^$' || true)
        if [[ -n "$user_tags" ]]; then
            echo " Per-user:"
            while IFS= read -r line; do
                echo "   $line"
            done <<< "$user_tags"
        fi

        echo ""
        echo " 1. Установить глобальный ad_tag"
        echo " 2. Удалить глобальный ad_tag"
        echo " 3. Установить per-user ad_tag"
        echo " 4. Удалить per-user ad_tag"
        echo " 0. Назад"
        echo -ne " Выбор: "
        local subchoice
        read -r subchoice || true

        case $subchoice in
            1)
                echo -ne " ad_tag (32 hex): "
                read -r tag
                if [[ ! "$tag" =~ ^[0-9a-fA-F]{32}$ ]]; then
                    error "Нужно 32 hex-символа"
                    return
                fi
                if grep -q '^ad_tag = ' "$TELEMT_CONFIG"; then
                    sed -i 's/^ad_tag = ".*"/ad_tag = "'"$tag"'"/' "$TELEMT_CONFIG"
                else
                    sed -i '/^\[general\]/a ad_tag = "'"$tag"'"' "$TELEMT_CONFIG"
                fi
                _fix_config_perm
                systemctl reload telemt 2>/dev/null || true
                info "Глобальный ad_tag установлен"
                ;;
            2)
                sed -i '/^ad_tag = /d' "$TELEMT_CONFIG"
                _fix_config_perm
                systemctl reload telemt 2>/dev/null || true
                info "Глобальный ad_tag удалён"
                ;;
            3)
                echo -ne " Имя пользователя: "
                read -r uname
                if [[ -z "$uname" ]]; then
                    error "Имя не может быть пустым"
                    return
                fi
                echo -ne " ad_tag (32 hex): "
                read -r tag
                if [[ ! "$tag" =~ ^[0-9a-fA-F]{32}$ ]]; then
                    error "Нужно 32 hex-символа"
                    return
                fi
                if ! grep -q '^\[access\.user_ad_tags\]' "$TELEMT_CONFIG"; then
                    echo -e "\n[access.user_ad_tags]" >> "$TELEMT_CONFIG"
                fi
                sed -i "/^\[access\.user_ad_tags\]/,/^\[/{/^${uname} = /d}" "$TELEMT_CONFIG"
                sed -i "/^\[access\.user_ad_tags\]/a ${uname} = \"${tag}\"" "$TELEMT_CONFIG"
                _fix_config_perm
                systemctl reload telemt 2>/dev/null || true
                info "Per-user ad_tag для ${uname} установлен"
                ;;
            4)
                echo -ne " Имя пользователя: "
                read -r uname
                if [[ -z "$uname" ]]; then
                    error "Имя не может быть пустым"
                    return
                fi
                sed -i "/^\[access\.user_ad_tags\]/,/^\[/{/^${uname} = /d}" "$TELEMT_CONFIG"
                _fix_config_perm
                systemctl reload telemt 2>/dev/null || true
                info "Per-user ad_tag для ${uname} удалён"
                ;;
        esac
        return
    fi

    case "$action" in
        show)
            echo -n "Глобальный ad_tag: "
            local gt
            gt=$(grep -Po '(?<=^ad_tag = ")[^"]*' "$TELEMT_CONFIG" 2>/dev/null || true)
            if [[ -n "$gt" ]]; then echo "$gt"; else echo "не задан"; fi
            local ut
            ut=$(sed -n '/^\[access\.user_ad_tags\]/,/^\[/p' "$TELEMT_CONFIG" 2>/dev/null | grep -v '^\[' | grep -v '^$' || true)
            if [[ -n "$ut" ]]; then
                echo "Per-user:"
                echo "$ut"
            fi
            ;;
        set)
            local val="${FLAG_AD_TAG_VALUE}"
            local uname="${FLAG_AD_TAG_USER}"
            if [[ -z "$val" ]]; then
                error "Укажи --ad-tag-value HEX"
                return
            fi
            if [[ ! "$val" =~ ^[0-9a-fA-F]{32}$ ]]; then
                error "ad_tag должен быть 32 hex-символа"
                return
            fi
            if [[ -n "$uname" ]]; then
                if ! grep -q '^\[access\.user_ad_tags\]' "$TELEMT_CONFIG"; then
                    echo -e "\n[access.user_ad_tags]" >> "$TELEMT_CONFIG"
                fi
                sed -i "/^\[access\.user_ad_tags\]/,/^\[/{/^${uname} = /d}" "$TELEMT_CONFIG"
                sed -i "/^\[access\.user_ad_tags\]/a ${uname} = \"${val}\"" "$TELEMT_CONFIG"
                info "Per-user ad_tag для ${uname} установлен"
            else
                if grep -q '^ad_tag = ' "$TELEMT_CONFIG"; then
                    sed -i 's/^ad_tag = ".*"/ad_tag = "'"$val"'"/' "$TELEMT_CONFIG"
                else
                    sed -i '/^\[general\]/a ad_tag = "'"$val"'"' "$TELEMT_CONFIG"
                fi
                info "Глобальный ad_tag установлен"
            fi
            _fix_config_perm
            systemctl reload telemt 2>/dev/null || true
            ;;
        del)
            local uname="${FLAG_AD_TAG_USER}"
            if [[ -n "$uname" ]]; then
                sed -i "/^\[access\.user_ad_tags\]/,/^\[/{/^${uname} = /d}" "$TELEMT_CONFIG"
                info "Per-user ad_tag для ${uname} удалён"
            else
                sed -i '/^ad_tag = /d' "$TELEMT_CONFIG"
                info "Глобальный ad_tag удалён"
            fi
            _fix_config_perm
            systemctl reload telemt 2>/dev/null || true
            ;;
    esac
}

# ==============================================================
# ДОМЕН + SSL + САЙТ-ЗАГЛУШКА
# ==============================================================

do_setup_domain() {
    local domain="${FLAG_DOMAIN}"

    if [[ -z "$domain" ]]; then
        echo -ne " Введите домен (например vpn.example.com): "
        read -r domain
    fi

    if [[ -z "$domain" ]]; then
        warn "Отменено."
        return
    fi

    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        error "Неверный формат домена"
        return
    fi

    if is_interactive; then
        echo -ne "Проверь DNS: A-запись ${domain} указывает на этот сервер? [y/N]: "
        read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
    fi

    info "Устанавливаю nginx и certbot..."
    apt-get install -y nginx certbot python3-certbot-nginx 2>/dev/null || {
        error "Не удалось установить nginx или certbot"
        return
    }

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi active; then
        ufw allow 80/tcp comment "TELEMT_MGR_HTTP" 2>/dev/null || true
        ufw allow 443/tcp comment "TELEMT_MGR_HTTPS" 2>/dev/null || true
    fi

    local web_root="/var/www/${domain}"
    mkdir -p "$web_root"
    chmod 755 "$web_root"
    cat > "${web_root}/index.html" << 'STUB'
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Скоро запуск • живая сеть</title>
  <link rel="stylesheet" href="style.css" />
</head>
<body>
  <canvas id="network-canvas"></canvas>
  <div class="hero">
    <div class="neon-icon">
      <svg viewBox="0 0 24 24">
        <circle cx="12" cy="12" r="10" />
        <polyline points="12 6 12 12 16 14" />
        <path d="M8 4 L4 8" />
        <path d="M16 4 L20 8" />
        <path d="M4 16 L8 20" />
        <path d="M20 16 L16 20" />
      </svg>
    </div>
    <h1>Скоро здесь</h1>
    <div class="tagline">
      <span>Новый уровень в разработке</span>
      <span class="badge">✦ coming soon</span>
    </div>
    <div class="timer-grid" id="timerGrid">
      <div class="time-block"><span class="time-number" id="days">00</span><span class="time-label">дней</span></div>
      <div class="time-block"><span class="time-number" id="hours">00</span><span class="time-label">часов</span></div>
      <div class="time-block"><span class="time-number" id="minutes">00</span><span class="time-label">минут</span></div>
      <div class="time-block"><span class="time-number" id="seconds">00</span><span class="time-label">секунд</span></div>
    </div>
    <div class="description">
      <strong>✦ Мы создаём нечто особенное</strong> — инновационный продукт, который изменит ваш опыт.
      Осталось совсем чуть-чуть. Подпишись и будь в курсе!
    </div>
    <form class="cta-form" id="subscribeForm">
      <input type="email" placeholder="Ваш email" required aria-label="Email для уведомлений" />
      <button type="submit">Уведомить меня</button>
    </form>
    <div class="footer-links">
      <span>© 2026 — ваш проект</span>
      <span class="dot">•</span>
      <a href="#" data-alert="hello@project.dev">Контакты</a>
      <span class="dot">•</span>
      <a href="#" data-alert="Политика конфиденциальности">Конфиденциальность</a>
    </div>
  </div>
  <script src="script.js"></script>
</body>
</html>
STUB
    chmod 644 "${web_root}/index.html"

    cat > "${web_root}/style.css" << 'CSS'
* { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      font-family: 'Segoe UI', 'Poppins', system-ui, sans-serif;
      background: #0a0a12;
      padding: 1.5rem;
      overflow-x: hidden;
      position: relative;
    }
    #network-canvas {
      position: fixed;
      top: 0; left: 0;
      width: 100%; height: 100%;
      z-index: 0;
      pointer-events: none;
    }
    .hero {
      position: relative;
      z-index: 1;
      max-width: 820px;
      width: 100%;
      background: rgba(10, 10, 22, 0.65);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      border-radius: 3.5rem 2rem 3.5rem 2rem;
      padding: 3.5rem 3rem;
      border: 1px solid rgba(255, 255, 255, 0.04);
      box-shadow: 0 30px 70px -20px #000000cc, 0 0 0 1px rgba(255, 255, 255, 0.02), 0 0 80px rgba(99, 102, 241, 0.08);
      text-align: center;
      transition: transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
    }
    .hero:hover { transform: scale(1.008) translateY(-4px); }
    .neon-icon {
      display: inline-flex;
      background: rgba(99, 102, 241, 0.08);
      padding: 1.2rem;
      border-radius: 60% 40% 60% 40%;
      margin-bottom: 1.6rem;
      border: 1px solid rgba(99, 102, 241, 0.15);
      box-shadow: 0 0 40px rgba(99, 102, 241, 0.15), inset 0 0 30px rgba(99, 102, 241, 0.05);
      animation: pulseGlow 3s ease-in-out infinite;
    }
    .neon-icon svg {
      width: 60px; height: 60px;
      fill: none; stroke: #a5b4fc;
      stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round;
      filter: drop-shadow(0 0 12px rgba(99, 102, 241, 0.4));
    }
    @keyframes pulseGlow {
      0%, 100% { box-shadow: 0 0 30px rgba(99, 102, 241, 0.1), inset 0 0 20px rgba(99, 102, 241, 0.02); }
      50% { box-shadow: 0 0 70px rgba(99, 102, 241, 0.25), inset 0 0 40px rgba(99, 102, 241, 0.08); }
    }
    h1 {
      font-size: 4rem;
      font-weight: 800;
      letter-spacing: -0.03em;
      background: linear-gradient(145deg, #e0e7ff, #818cf8, #c7d2fe);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
      margin-bottom: 0.2rem;
      text-shadow: 0 0 50px rgba(99, 102, 241, 0.15);
    }
    .tagline {
      font-size: 1.3rem;
      font-weight: 300;
      color: #9aa2cf;
      letter-spacing: 0.5px;
      border-bottom: 1px solid rgba(255, 255, 255, 0.04);
      padding-bottom: 1.2rem;
      margin-bottom: 1.8rem;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 0.6rem;
      flex-wrap: wrap;
    }
    .tagline .badge {
      background: rgba(99, 102, 241, 0.12);
      padding: 0.2rem 1rem;
      border-radius: 60px;
      font-size: 0.75rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: #a5b4fc;
      border: 1px solid rgba(99, 102, 241, 0.15);
      backdrop-filter: blur(4px);
    }
    .timer-grid {
      display: flex;
      justify-content: center;
      gap: 1.2rem;
      flex-wrap: wrap;
      margin: 2rem 0 2.4rem 0;
    }
    .time-block {
      background: rgba(8, 8, 24, 0.7);
      backdrop-filter: blur(8px);
      -webkit-backdrop-filter: blur(8px);
      border-radius: 2.2rem 1.2rem 2.2rem 1.2rem;
      padding: 0.8rem 1.2rem;
      min-width: 90px;
      border: 1px solid rgba(255, 255, 255, 0.04);
      box-shadow: 0 10px 30px -10px #000000aa, inset 0 1px 0 rgba(255, 255, 255, 0.02);
      transition: 0.25s ease;
    }
    .time-block:hover {
      border-color: rgba(99, 102, 241, 0.15);
      box-shadow: 0 0 30px rgba(99, 102, 241, 0.06);
    }
    .time-number {
      font-size: 3.2rem;
      font-weight: 700;
      color: #eef2ff;
      letter-spacing: 2px;
      display: block;
      line-height: 1.2;
      font-variant-numeric: tabular-nums;
      text-shadow: 0 0 30px rgba(99, 102, 241, 0.2);
    }
    .time-label {
      font-size: 0.7rem;
      text-transform: uppercase;
      letter-spacing: 2.5px;
      color: #7b83ae;
      display: block;
      font-weight: 500;
      margin-top: 0.1rem;
    }
    .description {
      background: rgba(255, 255, 255, 0.015);
      border-radius: 2.5rem 1rem 2.5rem 1rem;
      padding: 1.2rem 1.8rem;
      margin: 1.8rem 0 2.2rem 0;
      border: 1px solid rgba(255, 255, 255, 0.02);
      font-size: 1.05rem;
      color: #c2c9ec;
      line-height: 1.7;
      backdrop-filter: blur(2px);
    }
    .description strong {
      color: #d4dcff;
      font-weight: 500;
      background: linear-gradient(135deg, #a5b4fc, #818cf8);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
    }
    .cta-form {
      display: flex;
      flex-wrap: wrap;
      justify-content: center;
      gap: 0.8rem;
      margin-top: 0.6rem;
    }
    .cta-form input {
      flex: 1 1 220px;
      background: rgba(255, 255, 255, 0.03);
      border: 1px solid rgba(255, 255, 255, 0.06);
      padding: 1rem 1.8rem;
      border-radius: 60px;
      color: #f0f0f5;
      font-size: 1rem;
      outline: none;
      transition: 0.3s ease;
      backdrop-filter: blur(4px);
      font-weight: 300;
      letter-spacing: 0.2px;
    }
    .cta-form input::placeholder { color: #6a729c; font-weight: 300; }
    .cta-form input:focus {
      border-color: #818cf8;
      background: rgba(255, 255, 255, 0.06);
      box-shadow: 0 0 0 5px rgba(99, 102, 241, 0.12), 0 0 40px rgba(99, 102, 241, 0.03);
    }
    .cta-form button {
      background: linear-gradient(145deg, #6366f1, #4338ca);
      border: none;
      padding: 1rem 2.8rem;
      border-radius: 60px;
      font-weight: 600;
      font-size: 1rem;
      color: white;
      cursor: pointer;
      transition: 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
      box-shadow: 0 10px 30px -8px #3b3f9baa, inset 0 1px 0 rgba(255, 255, 255, 0.08);
      letter-spacing: 0.6px;
      border: 1px solid rgba(255, 255, 255, 0.05);
      position: relative;
      overflow: hidden;
    }
    .cta-form button::after {
      content: '';
      position: absolute;
      top: -50%; left: -50%;
      width: 200%; height: 200%;
      background: radial-gradient(circle at center, rgba(255, 255, 255, 0.05) 0%, transparent 70%);
      opacity: 0;
      transition: 0.4s;
    }
    .cta-form button:hover {
      transform: translateY(-3px) scale(1.02);
      background: linear-gradient(145deg, #818cf8, #6366f1);
      box-shadow: 0 16px 40px -10px #4f46e5cc, 0 0 60px rgba(99, 102, 241, 0.08);
    }
    .cta-form button:hover::after { opacity: 1; }
    .cta-form button:active { transform: scale(0.96); }
    .footer-links {
      margin-top: 2.8rem;
      font-size: 0.8rem;
      color: #4d5480;
      letter-spacing: 0.3px;
      border-top: 1px solid rgba(255, 255, 255, 0.02);
      padding-top: 2rem;
      display: flex;
      justify-content: center;
      gap: 2rem;
      flex-wrap: wrap;
    }
    .footer-links a {
      color: #7b84b0;
      text-decoration: none;
      transition: 0.25s;
      border-bottom: 1px solid transparent;
      padding-bottom: 2px;
      font-weight: 400;
    }
    .footer-links a:hover { color: #c7ceff; border-bottom-color: #6366f1; }
    .footer-links .dot { color: #3a3f66; }
    @media (max-width: 600px) {
      .hero { padding: 2rem 1.5rem; border-radius: 2.5rem 1.5rem 2.5rem 1.5rem; }
      h1 { font-size: 2.8rem; }
      .time-number { font-size: 2.4rem; }
      .time-block { min-width: 70px; padding: 0.6rem 0.8rem; }
      .tagline { font-size: 1rem; }
      .cta-form input { flex: 1 1 100%; }
      .cta-form button { width: 100%; }
      .neon-icon svg { width: 44px; height: 44px; }
    }
    @media (max-width: 420px) {
      h1 { font-size: 2.2rem; }
      .timer-grid { gap: 0.6rem; }
      .time-block { min-width: 60px; padding: 0.4rem 0.5rem; }
      .time-number { font-size: 1.8rem; }
    }
CSS
    chmod 644 "${web_root}/style.css"

    cat > "${web_root}/script.js" << 'JS'
(function() {
  var now = new Date();
  var launchDate = new Date(now.getTime());
  launchDate.setDate(launchDate.getDate() + 14);
  var daysEl = document.getElementById('days');
  var hoursEl = document.getElementById('hours');
  var minutesEl = document.getElementById('minutes');
  var secondsEl = document.getElementById('seconds');
  function pad(n) { return String(n).padStart(2, '0'); }
  function updateTimer() {
    var diff = launchDate.getTime() - Date.now();
    if (diff <= 0) {
      daysEl.textContent = '00'; hoursEl.textContent = '00';
      minutesEl.textContent = '00'; secondsEl.textContent = '00';
      return;
    }
    var days = Math.floor(diff / (1000 * 60 * 60 * 24));
    var hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
    var minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60));
    var seconds = Math.floor((diff % (1000 * 60)) / 1000);
    daysEl.textContent = pad(days);
    hoursEl.textContent = pad(hours);
    minutesEl.textContent = pad(minutes);
    secondsEl.textContent = pad(seconds);
  }
  updateTimer();
  setInterval(updateTimer, 1000);
})();

document.getElementById('subscribeForm').addEventListener('submit', function(e) {
  e.preventDefault();
  var email = this.querySelector('input[type="email"]');
  if (email.value.trim() !== '') {
    alert('Отлично! ' + email.value + ' — вы в списке первых. Ждите новостей.');
    email.value = '';
  } else {
    alert('Пожалуйста, введите email.');
  }
});

document.querySelectorAll('a[data-alert]').forEach(function(a) {
  a.addEventListener('click', function(e) {
    e.preventDefault();
    alert(a.getAttribute('data-alert'));
  });
});

(function() {
  var canvas = document.getElementById('network-canvas');
  var ctx = canvas.getContext('2d');
  var width, height;
  var mouseX = 0.5, mouseY = 0.5;
  var targetMouseX = 0.5, targetMouseY = 0.5;
  var NODE_COUNT = 80;
  var CONNECT_DIST = 150;
  var NODE_RADIUS = 2.5;
  var MOUSE_INFLUENCE = 180;
  var MOUSE_FORCE = 1.8;
  var nodes = [];
  function resize() {
    width = canvas.width = window.innerWidth;
    height = canvas.height = window.innerHeight;
    createNodes();
  }
  function createNodes() {
    nodes = [];
    for (var i = 0; i < NODE_COUNT; i++) {
      nodes.push({
        x: Math.random() * width,
        y: Math.random() * height,
        vx: (Math.random() - 0.5) * 0.5,
        vy: (Math.random() - 0.5) * 0.5,
        baseX: 0, baseY: 0,
        radius: NODE_RADIUS + (Math.random() - 0.5) * 1.5
      });
    }
    nodes.forEach(function(n) { n.baseX = n.x; n.baseY = n.y; });
  }
  window.addEventListener('resize', resize);
  resize();
  document.addEventListener('mousemove', function(e) {
    targetMouseX = e.clientX / width;
    targetMouseY = e.clientY / height;
  });
  document.addEventListener('touchmove', function(e) {
    var touch = e.touches[0];
    if (touch) { targetMouseX = touch.clientX / width; targetMouseY = touch.clientY / height; }
  }, { passive: true });
  function smoothMouse() {
    mouseX += (targetMouseX - mouseX) * 0.08;
    mouseY += (targetMouseY - mouseY) * 0.08;
  }
  function updateNodes() {
    var mouseWorldX = mouseX * width;
    var mouseWorldY = mouseY * height;
    nodes.forEach(function(n) {
      n.vx += (n.baseX - n.x) * 0.012;
      n.vy += (n.baseY - n.y) * 0.012;
      var dx = n.x - mouseWorldX;
      var dy = n.y - mouseWorldY;
      var dist = Math.sqrt(dx * dx + dy * dy);
      if (dist < MOUSE_INFLUENCE && dist > 0.5) {
        var force = (MOUSE_INFLUENCE - dist) / MOUSE_INFLUENCE * MOUSE_FORCE;
        n.vx += (dx / dist) * force * 0.4;
        n.vy += (dy / dist) * force * 0.4;
      }
      nodes.forEach(function(other) {
        if (other === n) return;
        var dx2 = n.x - other.x;
        var dy2 = n.y - other.y;
        var dist2 = Math.sqrt(dx2 * dx2 + dy2 * dy2);
        if (dist2 < CONNECT_DIST && dist2 > 0.5) {
          var force = (CONNECT_DIST - dist2) / CONNECT_DIST * 0.02;
          n.vx += (dx2 / dist2) * force * 0.3;
          n.vy += (dy2 / dist2) * force * 0.3;
        }
      });
      n.vx *= 0.94;
      n.vy *= 0.94;
      n.x += n.vx;
      n.y += n.vy;
      n.x = Math.max(0, Math.min(width, n.x));
      n.y = Math.max(0, Math.min(height, n.y));
    });
  }
  function draw() {
    ctx.clearRect(0, 0, width, height);
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        var dx = nodes[i].x - nodes[j].x;
        var dy = nodes[i].y - nodes[j].y;
        var dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < CONNECT_DIST) {
          var alpha = 0.15 * (1 - dist / CONNECT_DIST);
          ctx.beginPath();
          ctx.moveTo(nodes[i].x, nodes[i].y);
          ctx.lineTo(nodes[j].x, nodes[j].y);
          ctx.strokeStyle = 'rgba(165, 180, 252, ' + alpha + ')';
          ctx.lineWidth = 1.2;
          ctx.stroke();
        }
      }
    }
    nodes.forEach(function(n) {
      ctx.shadowColor = 'rgba(99, 102, 241, 0.2)';
      ctx.shadowBlur = 12;
      ctx.beginPath();
      ctx.arc(n.x, n.y, n.radius, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(165, 180, 252, 0.6)';
      ctx.fill();
      ctx.shadowBlur = 0;
      ctx.beginPath();
      ctx.arc(n.x, n.y, n.radius * 0.4, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(220, 230, 255, 0.8)';
      ctx.fill();
      ctx.shadowBlur = 0;
    });
    var mouseWorldX = mouseX * width;
    var mouseWorldY = mouseY * height;
    var gradient = ctx.createRadialGradient(
      mouseWorldX, mouseWorldY, 0,
      mouseWorldX, mouseWorldY, MOUSE_INFLUENCE
    );
    gradient.addColorStop(0, 'rgba(99, 102, 241, 0.03)');
    gradient.addColorStop(1, 'rgba(99, 102, 241, 0)');
    ctx.beginPath();
    ctx.arc(mouseWorldX, mouseWorldY, MOUSE_INFLUENCE, 0, Math.PI * 2);
    ctx.fillStyle = gradient;
    ctx.fill();
  }
  function animate() {
    smoothMouse();
    updateNodes();
    draw();
    requestAnimationFrame(animate);
  }
  animate();
})();
JS
    chmod 644 "${web_root}/script.js"

    # Временный HTTP-конфиг для получения сертификата
    cat > "/etc/nginx/sites-available/${domain}" << EOF
server {
    listen 80;
    server_name ${domain};
    root ${web_root};
    index index.html;
}
EOF
    ln -sf "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/" 2>/dev/null || true
    nginx -t 2>/dev/null && systemctl reload nginx || true

    info "Получаю SSL-сертификат для ${domain}..."
    if certbot --nginx -d "$domain" --non-interactive --agree-tos --email "admin@${domain}" 2>/dev/null; then
        info "Сертификат получен"
    else
        warn "certbot не смог получить сертификат. Проверь DNS A-запись."
    fi

    # Финальный конфиг: HTTP → HTTPS redirect
    cat > "/etc/nginx/sites-available/${domain}" << EOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    root ${web_root};
    index index.html;
}
EOF
    nginx -t 2>/dev/null && systemctl reload nginx || true

    save_manager_config "SETUP_DOMAIN" "$domain"
    save_manager_config "DOMAIN" "$domain"
    save_manager_config "PUBLIC_MODE" "domain"

    # Обновляем public_host в telemt.toml
    if [[ -f "$TELEMT_CONFIG" ]]; then
        local domain_esc
        domain_esc=$(printf '%s' "$domain" | sed 's/[&/\]/\\&/g')
        sed -i "s/^public_host = .*/public_host = \"${domain_esc}\"/" "$TELEMT_CONFIG"
        sed -i "/^public_port = /d" "$TELEMT_CONFIG"
        _fix_config_perm
        systemctl restart telemt 2>/dev/null || true
    fi

    echo ""
    echo "========================"
    echo " Домен + заглушка готовы!"
    echo "========================"
    echo " Домен:   ${domain}"
    echo " Сайт:    https://${domain}"
    echo ""
    info "Ссылки используют домен ${domain}"
    info "Обнови DNS A-запись: ${domain} → IP сервера"
}

do_public_mode() {
    local mode="${FLAG_PUBLIC_MODE}"
    local current
    current=$(load_manager_config "PUBLIC_MODE" "ip")

    if [[ -z "$mode" ]]; then
        local current_host
        current_host=$(grep -oP 'public_host = "\K[^"]+' "$TELEMT_CONFIG" 2>/dev/null || echo "неизвестно")
        echo ""
        echo "Текущий хост в ссылках: ${current_host} (режим: ${current})"
        echo "1. Домен"
        echo "2. IP"
        echo -ne "Выбор [1-2]: "
        read -r choice
        case "$choice" in
            1) mode="domain" ;;
            2) mode="ip" ;;
            *) warn "Отменено"; return ;;
        esac
    fi

    if [[ "$mode" != "domain" && "$mode" != "ip" ]]; then
        error "Режим должен быть domain или ip"
        return
    fi

    local host
    if [[ "$mode" == "domain" ]]; then
        host=$(load_manager_config "DOMAIN" "")
        if [[ -z "$host" ]]; then
            error "Домен не настроен. Сначала выполни 'Домен + SSL + сайт'"
            return
        fi
    else
        host=$(get_public_ip)
        if [[ -z "$host" ]]; then
            error "Не удалось определить публичный IP"
            return
        fi
    fi

    if [[ ! -f "$TELEMT_CONFIG" ]]; then
        error "Telemt не установлен"
        return
    fi

    local host_esc
    host_esc=$(printf '%s' "$host" | sed 's/[&/\]/\\&/g')
    sed -i "s/^public_host = .*/public_host = \"${host_esc}\"/" "$TELEMT_CONFIG"

    sed -i "/^public_port = /d" "$TELEMT_CONFIG"
    _fix_config_perm

    save_manager_config "PUBLIC_MODE" "$mode"
    systemctl restart telemt 2>/dev/null || true

    info "Режим ссылок: ${mode} (${host})"
}

# ==============================================================
# WEB-ПРОКСИ (tg://webproxy)
# ==============================================================

do_web_proxy() {
    local domain="${FLAG_DOMAIN}"
    local web_user="${FLAG_USER}"
    local web_secret="${FLAG_SECRET}"
    local web_port="18080"
    local proxy_port
    local public_ip

    if [[ -z "$domain" ]]; then
        domain=$(load_manager_config "DOMAIN" "")
    fi
    if [[ -z "$domain" ]]; then
        echo -ne " Введите домен с валидным SSL (например vpn.example.com): "
        read -r domain
    fi
    if [[ -z "$domain" ]]; then
        warn "Отменено."
        return
    fi

    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        error "Неверный формат домена"
        return
    fi

    if [[ ! -f "$TELEMT_CONFIG" ]]; then
        error "Telemt не установлен. Сначала выполни --install"
        return
    fi

    local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
    if [[ ! -f "$cert_path" ]]; then
        error "Нет SSL-сертификата для ${domain}. Сначала выполни 'Домен + SSL + сайт' (--setup-domain)"
        return
    fi

    [[ -z "$web_user" ]] && web_user="webuser"
    if ! [[ "$web_user" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
        error "Неверное имя WEB-пользователя"
        return
    fi

    if [[ -z "$web_secret" ]]; then
        web_secret=$(openssl rand -hex 16)
    fi
    if ! [[ "$web_secret" =~ ^[0-9a-fA-F]{32}$ ]]; then
        error "Секрет должен быть 32 hex-символа"
        return
    fi

    proxy_port=$(grep -oP '^port\s*=\s*\K[0-9]+' "$TELEMT_CONFIG" | head -1)
    [[ -z "$proxy_port" ]] && proxy_port="8443"

    public_ip=$(get_public_ip)
    if [[ -z "$public_ip" ]]; then
        error "Не удалось определить публичный IP"
        return
    fi

    if ss -ltn 2>/dev/null | grep -q "127.0.0.1:${web_port}\b"; then
        error "Порт ${web_port} уже занят"
        return
    fi

    # Бэкап перед изменениями
    cp -f "$TELEMT_CONFIG" "${TELEMT_CONFIG}.bak.$(date +%s)" 2>/dev/null || true

    # 1. Создаём WEB-пользователя в [access.users]
    local existing_secret
    existing_secret=$(grep -oP "^${web_user}\s*=\s*\"\K[0-9a-fA-F]{32}" "$TELEMT_CONFIG" | head -1)
    if [[ -z "$existing_secret" ]]; then
        cat >> "$TELEMT_CONFIG" << EOF

${web_user} = "${web_secret}"
EOF
    else
        web_secret="$existing_secret"
        info "Пользователь ${web_user} уже существует, использую его секрет"
    fi

    # 2. Если WEB-listener ещё не добавлен — добавляем Mtproxy + WEB listeners
    if ! grep -q 'transport = "web"' "$TELEMT_CONFIG"; then
        awk -v p="$proxy_port" -v w="$web_port" '
            /^port = / && !done {
                print $0
                printf "\n[[server.listeners]]\nip = \"0.0.0.0\"\nport = %s\n\n[[server.listeners]]\nip = \"127.0.0.1\"\nport = %s\ntransport = \"web\"\nweb_client_ip_source = \"x_forwarded_for\"\nweb_trusted_proxy_cidrs = [\"127.0.0.1/32\"]\n", p, w
                done = 1
                next
            }
            { print }
        ' "$TELEMT_CONFIG" > "$TELEMT_CONFIG.new" && mv "$TELEMT_CONFIG.new" "$TELEMT_CONFIG"
    else
        info "WEB-listener уже настроен, пропускаю"
    fi

    # 3. Добавляем секцию [web]
    if ! grep -q '^\[web\]$' "$TELEMT_CONFIG"; then
        cat >> "$TELEMT_CONFIG" << EOF

[web]
enabled = true
carrier = "https-lanes"

[[web.vhosts]]
host = "${domain}"
public_addr = "${public_ip}:443"

[web.vhosts.decoy]
mode = "static_directory"
directory = "/var/www/${domain}"
index = "index.html"

[[web.vhosts.profiles]]
user = "${web_user}"
secret_mode = "dd"
max_sessions = 8
max_streams = 512
max_streams_per_session = 64
EOF
    fi

    # 4. NGINX: TLS termination → telemt WEB-listener
    info "Настраиваю nginx..."
    cat > /etc/nginx/conf.d/telemt-web.conf << 'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
upstream telemt_web {
    server 127.0.0.1:18080;
    keepalive 64;
}
EOF

    cat > "/etc/nginx/sites-available/${domain}" << EOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 2m;

    location / {
        proxy_pass http://telemt_web;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 65s;
        proxy_send_timeout 65s;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_next_upstream off;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/" 2>/dev/null || true

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
    else
        warn "nginx -t не прошёл, конфиг WEB может быть некорректен"
    fi

    # 5. Перезапуск telemt
    _fix_config_perm
    systemctl restart telemt 2>/dev/null || true

    save_manager_config "WEB_PROXY" "on"
    save_manager_config "WEB_USER" "$web_user"
    save_manager_config "DOMAIN" "$domain"
    save_manager_config "PUBLIC_MODE" "domain"

    # 6. Ссылка WEB
    echo ""
    echo "================================"
    echo " WEB-прокси настроен!"
    echo "================================"
    echo " Домен:   ${domain}"
    echo " Порт:    443 (TLS)"
    echo " Пользователь: ${web_user}"
    echo " Ссылка:"
    echo "  tg://webproxy?server=${domain}&secret=dd${web_secret}"
    echo ""
    echo " Для подключения в Telegram Desktop выбери тип прокси WEB"
    echo " Важно: только секреты plain/dd (FakeTLS ee не работает в WEB)"
}

# ==============================================================
# CLI-АРГУМЕНТЫ
# ==============================================================

FLAG_INSTALL=false
FLAG_REMOVE=false
FLAG_LINKS=false
FLAG_ADD_CLIENT=""
FLAG_CLIENT_TYPE=""
FLAG_DEL_CLIENT=""
FLAG_INSTALL_PANEL=false
FLAG_REMOVE_PANEL=false
FLAG_UPDATE=false
FLAG_UPDATE_PANEL=false
FLAG_AUTOUPDATE=""
FLAG_AD_TAG=""
FLAG_AD_TAG_USER=""
FLAG_AD_TAG_VALUE=""
FLAG_SETUP_DOMAIN=false
FLAG_WEB_PROXY=false
FLAG_PUBLIC_MODE=""
FLAG_DOMAIN=""
FLAG_PORT=""
FLAG_USER=""
FLAG_SECRET=""
FLAG_MIDDLE_PROXY=""
FLAG_PANEL_PORT=""
FLAG_PANEL_USER=""
FLAG_PANEL_PASS=""

# Переменные для установки (также через env)
TLS_DOMAIN="${TLS_DOMAIN:-}"
PROXY_PORT="${PROXY_PORT:-}"
PROXY_USER="${PROXY_USER:-}"
USE_MIDDLE_PROXY="${USE_MIDDLE_PROXY:-}"

usage() {
    echo "Использование: $0 [ОПЦИИ]"
    echo ""
    echo "  --install           Установить Telemt"
    echo "    --domain HOST       Домен маскировки (по умолч. www.gosuslugi.ru)"
    echo "    --port PORT         Порт прокси (по умолч. 443)"
    echo "    --user NAME         Имя пользователя (по умолч. tguser)"
    echo "    --secret HEX        Секрет (32 hex-символа, авто-генерация если не указан)"
    echo "    --middle-proxy BOOL true/false (по умолч. true)"
    echo ""
    echo "  --remove            Удалить Telemt"
    echo "  --links             Показать ссылки и статистику"
    echo "  --add-client NAME   Добавить клиента"
    echo "    --client-type TYPE   Тип прокси: mtproto или web (по умолч. mtproto)"
    echo "  --del-client NAME   Удалить клиента"
    echo "  --update            Обновить Telemt (интерактивно)"
    echo ""
    echo "  --install-panel     Установить панель управления"
    echo "    --panel-port PORT   Порт панели (по умолч. 8080)"
    echo "    --panel-user NAME   Логин админа (по умолч. admin)"
    echo "    --panel-pass PASS   Пароль админа (обязательно)"
    echo ""
    echo "  --remove-panel      Удалить панель"
    echo "  --update-panel      Обновить панель"
    echo ""
    echo "  --autoupdate on|off Включить/выключить автообновление"
    echo ""
    echo "  --ad-tag show|set|del  Управление ad_tag"
    echo "    --ad-tag-user NAME   Имя пользователя для per-user ad_tag"
    echo "    --ad-tag-value HEX   32 hex-символа ad_tag"
    echo ""
    echo "  --setup-domain      Настроить домен + SSL + сайт-заглушку"
    echo "    --domain HOST       Домен (обязательно)"
    echo ""
    echo "  --public-mode domain|ip  Переключить домен/IP в ссылках"
    echo ""
    echo "  --web-proxy         Настроить WEB-прокси (tg://webproxy)"
    echo "    --domain HOST       Домен с валидным SSL (обязательно)"
    echo "    --user NAME         WEB-пользователь (по умолч. webuser)"
    echo "    --secret HEX        Секрет WEB-пользователя (32 hex, авто-генерация)"
    echo ""
    echo "  -h, --help          Показать помощь"
    echo ""
    echo "Переменные окружения: TLS_DOMAIN, PROXY_PORT, PROXY_USER, USE_MIDDLE_PROXY"
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install)         FLAG_INSTALL=true ;;
            --remove)          FLAG_REMOVE=true ;;
            --links)           FLAG_LINKS=true ;;
            --add-client)      shift; FLAG_ADD_CLIENT="$1" ;;
            --client-type)     shift; FLAG_CLIENT_TYPE="$1" ;;
            --del-client)      shift; FLAG_DEL_CLIENT="$1" ;;
            --install-panel)   FLAG_INSTALL_PANEL=true ;;
            --remove-panel)    FLAG_REMOVE_PANEL=true ;;
            --update)          FLAG_UPDATE=true ;;
            --update-panel)    FLAG_UPDATE_PANEL=true ;;
            --autoupdate)      shift; FLAG_AUTOUPDATE="$1" ;;
            --ad-tag)          shift; FLAG_AD_TAG="$1" ;;
            --ad-tag-user)     shift; FLAG_AD_TAG_USER="$1" ;;
            --ad-tag-value)    shift; FLAG_AD_TAG_VALUE="$1" ;;
            --setup-domain)    FLAG_SETUP_DOMAIN=true ;;
            --web-proxy)       FLAG_WEB_PROXY=true ;;
            --public-mode)     shift; FLAG_PUBLIC_MODE="$1" ;;
            --domain)          shift; FLAG_DOMAIN="$1" ;;
            --port)            shift; FLAG_PORT="$1" ;;
            --user)            shift; FLAG_USER="$1" ;;
            --secret)          shift; FLAG_SECRET="$1" ;;
            --middle-proxy)    shift; FLAG_MIDDLE_PROXY="$1" ;;
            --panel-port)      shift; FLAG_PANEL_PORT="$1" ;;
            --panel-user)      shift; FLAG_PANEL_USER="$1" ;;
            --panel-pass)      shift; FLAG_PANEL_PASS="$1" ;;
            -h|--help)         usage ;;
            *) error "Неизвестный аргумент: $1"; usage ;;
        esac
        shift
    done
}

# ==============================================================
# МЕНЮ (интерактивный режим)
# ==============================================================

show_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}        v${TELEMT_MANAGER_VERSION}${NC}"
        echo -e "${CYAN}╔══════════════════════════════╗${NC}"
        echo -e "${CYAN}║      TELEMT MANAGER          ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC}  --- Telemt ---              ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  1. Установка                ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  2. Ссылки / статистика      ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  3. Добавить клиента         ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  4. Удалить клиента          ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  5. Обновить Telemt          ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  6. Полное удаление          ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  --- Панель ---              ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  7. Установить панель        ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  8. Обновить панель          ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  9. Удалить панель           ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  --- Система ---             ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  10. Автообновление          ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  11. AD Tag                  ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  --- Домен ---               ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  12. Домен + SSL + сайт      ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  13. Домен/IP в ссылках      ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  --- WEB-прокси ---           ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  14. WEB-прокси (tg://webproxy)${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  0. Выход                    ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════╝${NC}"
        echo -ne " Выбор: "
        read -r choice || break

        case $choice in
            1) do_install ;;
            2) do_links ;;
            3) do_add_client ;;
            4) do_del_client ;;
            5) do_update_telemt ;;
            6) do_remove ;;
            7) do_install_panel ;;
            8) do_update_panel ;;
            9) do_remove_panel ;;
            10) do_autoupdate ;;
            11) do_ad_tag ;;
            12) do_setup_domain ;;
            13) do_public_mode ;;
            14) do_web_proxy ;;
            0) exit 0 ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

# ==============================================================
# MAIN
# ==============================================================

main() {
    # Проверки среды
    ensure_root
    ensure_debian

    # Если нет аргументов — интерактивный режим
    if [[ $# -eq 0 ]]; then
        if ! is_interactive; then
            error "Нет TTY. Используй флаги командной строки (--help)."
            usage
        fi
        # Загружаем сохранённые настройки
        API_PORT="${API_PORT:-$(detect_api_port)}"
        TLS_DOMAIN="${TLS_DOMAIN:-$(load_manager_config "TLS_DOMAIN" "")}"
        PROXY_PORT="${PROXY_PORT:-$(load_manager_config "PROXY_PORT" "")}"
        PROXY_USER="${PROXY_USER:-$(load_manager_config "USERNAME" "")}"
        show_menu
        return
    fi

    # Парсим аргументы
    parse_args "$@"
    API_PORT="${API_PORT:-$(detect_api_port)}"

    # Выполняем команды (lock только для операций, меняющих состояние)
    local needs_lock=false
    $FLAG_INSTALL && needs_lock=true
    $FLAG_REMOVE && needs_lock=true
    $FLAG_INSTALL_PANEL && needs_lock=true
    $FLAG_REMOVE_PANEL && needs_lock=true
    $FLAG_UPDATE && needs_lock=true
    $FLAG_UPDATE_PANEL && needs_lock=true
    [[ -n "$FLAG_AUTOUPDATE" ]] && needs_lock=true
    [[ -n "$FLAG_ADD_CLIENT" ]] && needs_lock=true
    [[ -n "$FLAG_DEL_CLIENT" ]] && needs_lock=true
    [[ -n "$FLAG_AD_TAG" ]] && needs_lock=true
    $FLAG_SETUP_DOMAIN && needs_lock=true
    $FLAG_WEB_PROXY && needs_lock=true
    [[ -n "$FLAG_PUBLIC_MODE" ]] && needs_lock=true

    $needs_lock && acquire_lock

    $FLAG_INSTALL && do_install
    $FLAG_REMOVE && do_remove
    $FLAG_LINKS && do_links
    [[ -n "$FLAG_ADD_CLIENT" ]] && do_add_client
    [[ -n "$FLAG_DEL_CLIENT" ]] && do_del_client
    $FLAG_INSTALL_PANEL && do_install_panel
    $FLAG_REMOVE_PANEL && do_remove_panel
    $FLAG_UPDATE && do_update_telemt
    $FLAG_UPDATE_PANEL && do_update_panel
    [[ -n "$FLAG_AUTOUPDATE" ]] && do_autoupdate
    [[ -n "$FLAG_AD_TAG" ]] && do_ad_tag
    $FLAG_SETUP_DOMAIN && do_setup_domain
    $FLAG_WEB_PROXY && do_web_proxy
    [[ -n "$FLAG_PUBLIC_MODE" ]] && do_public_mode

    $needs_lock && release_lock
}

trap 'release_lock; cleanup_all; exit 1' INT TERM
trap 'release_lock; cleanup_all' EXIT

main "$@"
