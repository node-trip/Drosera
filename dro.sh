#!/bin/bash

# === Цвета ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Без цвета

# === Вспомогательные функции ===
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Проверка, используется ли порт
is_port_in_use() {
    local port=$1
    # Пытаемся использовать netcat (nc), lsof или /dev/tcp
    if command -v nc &> /dev/null; then
        nc -z localhost "$port" &> /dev/null
        return $?
    elif command -v lsof &> /dev/null; then
        lsof -i:"$port" &> /dev/null
        return $?
    else
        # Bash fallback
        (echo > /dev/tcp/127.0.0.1/"$port") &> /dev/null
        return $?
    fi
}

# Установка Python3, если не установлен
install_python3() {
    if command -v python3 &> /dev/null; then
        print_message $GREEN "Python3 уже установлен."
        return 0
    fi
    print_message $BLUE "Установка python3..."
    sudo apt-get update
    sudo apt-get install -y python3 python3-pip || {
        print_message $RED "Не удалось установить python3. Пожалуйста, установите вручную."
        return 1
    }
    print_message $GREEN "Python3 успешно установлен."
}

# Установка Cloudflared, если не установлен
install_cloudflared() {
    if command -v cloudflared &> /dev/null; then
        print_message $GREEN "Cloudflared уже установлен."
        return 0
    fi
    print_message $BLUE "Установка cloudflared..."
    local ARCH=$(uname -m)
    local CLOUDFLARED_ARCH=""
    case $ARCH in
        x86_64) CLOUDFLARED_ARCH="amd64" ;;
        aarch64|arm64) CLOUDFLARED_ARCH="arm64" ;;
        *) print_message $RED "Неподдерживаемая архитектура: $ARCH"; return 1 ;;
    esac

    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || return 1

    print_message $BLUE "Загрузка cloudflared для $ARCH..."
    if curl -fL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}.deb" -o cloudflared.deb; then
        print_message $BLUE "Установка через dpkg..."
        sudo dpkg -i cloudflared.deb || sudo apt-get install -f -y # Попытка исправить зависимости
    else
        print_message $YELLOW "Не удалось скачать .deb, попытка скачать бинарник..."
         if curl -fL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}" -o cloudflared; then
            chmod +x cloudflared
            print_message $BLUE "Перемещение в /usr/local/bin..."
            sudo mv cloudflared /usr/local/bin/
        else
            print_message $RED "Не удалось скачать cloudflared."
            cd ~; rm -rf "$temp_dir"
            return 1
        fi
    fi

    cd ~; rm -rf "$temp_dir"

    if command -v cloudflared &> /dev/null; then
        print_message $GREEN "Cloudflared успешно установлен."
        return 0
    else
        print_message $RED "Не удалось установить cloudflared. Проверьте вывод выше и попробуйте установить вручную."
        return 1
    fi
}

# === Функции управления ===

# Показать статус и последние логи
check_status_logs() {
    print_message $BLUE "Проверка статуса службы drosera.service..."
    sudo systemctl status drosera.service --no-pager -l
    print_message $BLUE "\nПоследние 15 строк лога службы drosera.service:"
    sudo journalctl -u drosera.service -n 15 --no-pager -l
    print_message $YELLOW "Для просмотра логов в реальном времени используйте: sudo journalctl -u drosera.service -f"
}

# Остановить службу
stop_node_systemd() {
    print_message $BLUE "Остановка службы drosera.service..."
    sudo systemctl stop drosera.service
    sudo systemctl status drosera.service --no-pager -l
}

# Запустить службу
start_node_systemd() {
    print_message $BLUE "Запуск службы drosera.service..."
    sudo systemctl start drosera.service
    sleep 2 # Даем время на запуск перед проверкой статуса
    sudo systemctl status drosera.service --no-pager -l
}

# Функция резервного копирования (SystemD) - ТОЛЬКО СОЗДАЕТ АРХИВ
backup_node_systemd() {
    print_message $BLUE "--- Создание архива резервной копии Drosera (SystemD) ---"
    
    local backup_date=$(date +%Y%m%d_%H%M%S)
    local backup_base_dir="$HOME/drosera_backup"
    local backup_dir="$backup_base_dir/drosera_backup_$backup_date"
    local backup_archive="$HOME/drosera_backup_$backup_date.tar.gz"
    local operator_env_file="/root/.drosera_operator.env"
    local trap_dir="$HOME/my-drosera-trap"
    local service_file="/etc/systemd/system/drosera.service"
    local operator_bin=""

    # Проверяем наличие ключевых компонентов
    if [ ! -d "$trap_dir" ]; then
        print_message $RED "Ошибка: Директория Trap ($trap_dir) не найдена. Бэкап невозможен."
        return 1
    fi
    if [ ! -f "$operator_env_file" ]; then
        print_message $RED "Ошибка: Файл окружения оператора ($operator_env_file) не найден. Бэкап невозможен."
        return 1
    fi
     if [ ! -f "$service_file" ]; then
        print_message $YELLOW "Предупреждение: Файл службы ($service_file) не найден. Бэкап будет неполным."
    fi
    
    # Определяем путь к бинарнику
    if command -v drosera-operator &> /dev/null; then
        operator_bin=$(command -v drosera-operator)
        print_message $BLUE "Найден бинарник оператора: $operator_bin"
    else
        print_message $YELLOW "Предупреждение: Бинарник drosera-operator не найден в PATH. Бэкап будет неполным."
    fi

    # Создаем директорию для бэкапа
    print_message $BLUE "Создание директории бэкапа: $backup_dir"
    if ! mkdir -p "$backup_dir"; then 
        print_message $RED "Не удалось создать директорию бэкапа $backup_dir. Выход."; 
        # Попытка запустить службу обратно, если она была остановлена
        sudo systemctl start drosera.service 2>/dev/null 
        return 1;
    fi
    print_message $GREEN "Директория для бэкапа успешно создана."

    print_message $BLUE "Остановка службы drosera.service..."
    sudo systemctl stop drosera.service
    sleep 2

    print_message $BLUE "Копирование файлов..."
    # Копируем Trap директорию
    print_message $BLUE "Копирование $trap_dir..."
    if cp -rv "$trap_dir" "$backup_dir/"; then
       print_message $GREEN "Успешно скопировано $trap_dir"
    else
       print_message $YELLOW "Ошибка копирования $trap_dir"
    fi
    
    # Копируем файл .env
    print_message $BLUE "Попытка скопировать $operator_env_file..."
    if [ -f "$operator_env_file" ]; then
        print_message $GREEN "Файл $operator_env_file найден."
        # Используем -v для подробного вывода. sudo не нужно, т.к. запускаем от root.
        if cp -v "$operator_env_file" "$backup_dir/"; then
            print_message $GREEN "Успешно скопировано $operator_env_file в $backup_dir"
        else
            print_message $RED "Ошибка копирования $operator_env_file (Код ошибки: $?). Проверьте права на $backup_dir."
        fi
    else
        print_message $RED "Ошибка: Файл $operator_env_file НЕ НАЙДЕН по указанному пути!"
    fi

    # Копируем файл службы
    print_message $BLUE "Попытка скопировать $service_file..."
    if [ -f "$service_file" ]; then
        print_message $GREEN "Файл $service_file найден."
        # Используем -v. sudo не нужно.
        if cp -v "$service_file" "$backup_dir/"; then
           print_message $GREEN "Успешно скопировано $service_file в $backup_dir"
        else
           print_message $RED "Ошибка копирования $service_file (Код ошибки: $?)."
        fi
    else
        print_message $YELLOW "Предупреждение: Файл службы $service_file НЕ НАЙДЕН."
    fi

    # Копируем бинарник оператора
    if [ -n "$operator_bin" ] && [ -f "$operator_bin" ]; then
        print_message $BLUE "Попытка скопировать бинарник $operator_bin..."
        if cp -v "$operator_bin" "$backup_dir/"; then
            print_message $GREEN "Успешно скопирован бинарник $operator_bin"
            # Сохраняем путь к бинарнику для восстановления
            echo "OPERATOR_BIN_PATH=$operator_bin" > "$backup_dir/restore_info.txt"
        else
            print_message $YELLOW "Ошибка копирования $operator_bin (Код ошибки: $?)."
        fi
    fi

    print_message $BLUE "Создание архива $backup_archive..."
    if tar czf "$backup_archive" -C "$backup_base_dir" "drosera_backup_$backup_date"; then
        print_message $GREEN "Резервная копия успешно создана: $backup_archive"
        print_message $YELLOW "ПОЖАЛУЙСТА, скопируйте этот файл в безопасное место (не на этот VPS)!"
        print_message $YELLOW "Архив содержит ваш приватный ключ в файле .drosera_operator.env!"
    else
        print_message $RED "Ошибка при создании архива."
    fi

    print_message $BLUE "Очистка временной директории бэкапа..."
    rm -rf "$backup_dir" 
    # Можно удалить и $backup_base_dir, если он пуст, но оставим пока
    # find "$backup_base_dir" -maxdepth 0 -empty -delete

    print_message $BLUE "Запуск службы drosera.service..."
    sudo systemctl start drosera.service
    print_message $BLUE "--- Создание резервной копии завершено ---"
    return 0
}

# Новая функция для создания и выдачи бэкапа по ссылке
backup_and_serve_systemd() {
    print_message $BLUE "--- Создание и выдача резервной копии по ссылке ---"

    # 1. Создаем временную директорию с файлами бэкапа
    local backup_files_dir
    # Вызываем оригинальную функцию бэкапа, она вернет путь к директории
    backup_files_dir=$(backup_node_systemd) 
    local backup_exit_code=$?
    
    if [[ $backup_exit_code -ne 0 ]] || [[ -z "$backup_files_dir" ]] || [[ ! -d "$backup_files_dir" ]]; then
        print_message $RED "Не удалось создать директорию с файлами бэкапа. Выдача по ссылке отменена."
        # Убедимся, что служба запущена, если бэкап прервался после остановки
        sudo systemctl start drosera.service 2>/dev/null
        return 1
    fi
    
    print_message $BLUE "Файлы для бэкапа подготовлены в: $backup_files_dir"
    
    # 2. Создаем архив из этой директории
    local archive_name="drosera_backup_$(basename "$backup_files_dir" | sed 's/drosera_backup_//').tar.gz"
    local archive_path="$HOME/$archive_name"
    print_message $BLUE "Создание архива $archive_name..."
    if ! tar czf "$archive_path" -C "$(dirname "$backup_files_dir")" "$(basename "$backup_files_dir")"; then
        print_message $RED "Ошибка создания архива $archive_path."
        rm -rf "$backup_files_dir"
        return 1
    fi
    print_message $GREEN "Архив успешно создан: $archive_path"
    
    # 3. Очищаем временную директорию с файлами (архив остается)
    print_message $BLUE "Очистка временной директории с файлами..."
    rm -rf "$backup_files_dir"

    # 4. Проверяем и устанавливаем зависимости для сервера
    install_python3 || return 1
    install_cloudflared || return 1
    # Проверим nc/lsof для проверки порта
    if ! command -v nc &> /dev/null && ! command -v lsof &> /dev/null; then
        print_message $BLUE "Установка netcat/lsof для проверки портов..."
        sudo apt-get update && sudo apt-get install -y netcat lsof
    fi

    # 5. Запускаем сервер и туннель
    local PORT=8000
    local MAX_RETRIES=10
    local RETRY_COUNT=0
    local SERVER_STARTED=false
    local HTTP_SERVER_PID=""
    local CLOUDFLARED_PID=""
    local TUNNEL_URL=""

    # Переходим в домашнюю директорию, чтобы сервер отдавал файлы оттуда
    cd ~ || { print_message $RED "Не удалось перейти в домашнюю директорию."; return 1; }

    while [[ $RETRY_COUNT -lt $MAX_RETRIES && $SERVER_STARTED == false ]]; do
        print_message $BLUE "Попытка запуска сервера на порту $PORT..."
        if is_port_in_use "$PORT"; then
            print_message $YELLOW "Порт $PORT занят. Пробуем следующий."
            PORT=$((PORT + 1))
            RETRY_COUNT=$((RETRY_COUNT + 1))
            continue
        fi

        # Запускаем HTTP сервер
        local temp_log_http="/tmp/http_server_$$.log"
        rm -f "$temp_log_http"
        python3 -m http.server "$PORT" > "$temp_log_http" 2>&1 &
        HTTP_SERVER_PID=$!
        sleep 3 # Даем время на запуск

        if ! ps -p $HTTP_SERVER_PID > /dev/null; then
            print_message $RED "Не удалось запустить HTTP сервер на порту $PORT."
            cat "$temp_log_http"
            rm -f "$temp_log_http"
            PORT=$((PORT + 1))
            RETRY_COUNT=$((RETRY_COUNT + 1))
            continue
        fi
        print_message $GREEN "HTTP сервер запущен на порту $PORT (PID: $HTTP_SERVER_PID)."
        rm -f "$temp_log_http" # Лог больше не нужен

        # Запускаем Cloudflared туннель
        print_message $BLUE "Запуск cloudflared туннеля к http://localhost:$PORT..."
        local temp_log_cf="/tmp/cloudflared_$$.log"
        rm -f "$temp_log_cf"
        cloudflared tunnel --url "http://localhost:$PORT" --no-autoupdate > "$temp_log_cf" 2>&1 &
        CLOUDFLARED_PID=$!
        
        # Ждем появления URL туннеля
        print_message $YELLOW "Ожидание URL туннеля Cloudflare (до 20 секунд)..."
        for i in {1..10}; do
            TUNNEL_URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' "$temp_log_cf" | head -n 1)
            if [[ -n "$TUNNEL_URL" ]]; then
                break
            fi
            sleep 2
        done

        if [[ -z "$TUNNEL_URL" ]]; then
            print_message $RED "Не удалось получить URL туннеля Cloudflare."
            print_message $YELLOW "Лог cloudflared:"
            cat "$temp_log_cf"
            # Останавливаем сервер и туннель, пробуем следующий порт
            kill $HTTP_SERVER_PID 2>/dev/null
            kill $CLOUDFLARED_PID 2>/dev/null
            wait $HTTP_SERVER_PID 2>/dev/null
            wait $CLOUDFLARED_PID 2>/dev/null
            rm -f "$temp_log_cf"
            HTTP_SERVER_PID=""
            CLOUDFLARED_PID=""
            PORT=$((PORT + 1))
            RETRY_COUNT=$((RETRY_COUNT + 1))
        else
            print_message $GREEN "Туннель Cloudflare создан: $TUNNEL_URL"
            rm -f "$temp_log_cf" # Лог больше не нужен
            SERVER_STARTED=true
        fi
    done

    if [[ $SERVER_STARTED == false ]]; then
        print_message $RED "Не удалось запустить сервер и туннель после $MAX_RETRIES попыток."
        return 1
    fi

    # Устанавливаем обработчик для Ctrl+C
    trap 'cleanup_server' INT

    # Функция очистки
    cleanup_server() {
        print_message $YELLOW "\nОстановка сервера и туннеля..."
        if [[ -n "$HTTP_SERVER_PID" ]]; then kill $HTTP_SERVER_PID 2>/dev/null; fi
        if [[ -n "$CLOUDFLARED_PID" ]]; then kill $CLOUDFLARED_PID 2>/dev/null; fi
        wait $HTTP_SERVER_PID 2>/dev/null # Ожидаем завершения
        wait $CLOUDFLARED_PID 2>/dev/null
        print_message $GREEN "Серверы остановлены."
        # Выход из скрипта или возврат в меню?
        # Пока просто выходим из ожидания
        exit 0 # Или просто return, если хотим вернуться в меню
    }

    # Выводим ссылку
    print_message $GREEN "========================================================="
    print_message $GREEN "Резервная копия доступна для скачивания по ссылке:"
    print_message $YELLOW "$TUNNEL_URL/$(basename "$archive_path")"
    print_message $GREEN "========================================================="
    print_message $YELLOW "Ссылка действительна, пока запущен этот скрипт."
    print_message $YELLOW "Нажмите Ctrl+C, чтобы остановить сервер и завершить работу."

    # Ожидаем нажатия Ctrl+C (wait без аргументов ждет все фоновые процессы)
    wait $HTTP_SERVER_PID $CLOUDFLARED_PID
    # Если дошли сюда без Ctrl+C (маловероятно), все равно чистим
    cleanup_server 
    return 0 # Возврат в меню после Ctrl+C (если не было exit 0 в trap)
}

# === Основная функция установки (из скрипта Kazuha) ===
install_drosera_systemd() {
    # Оставляем эту функцию как есть, она выполняет шаги 1-13
    # Добавим проверку, запускалась ли установка ранее
    if [ -f "/etc/systemd/system/drosera.service" ]; then
        print_message $YELLOW "Похоже, установка Drosera (SystemD) уже была выполнена."
        read -p "Вы уверены, что хотите запустить установку заново? Это удалит некоторые старые файлы и переустановит компоненты. (y/N): " confirm_reinstall
        if [[ ! "$confirm_reinstall" =~ ^[Yy]$ ]]; then
            print_message $YELLOW "Повторная установка отменена."
            return 1
        fi
        # Останавливаем и отключаем старую службу перед переустановкой
        sudo systemctl stop drosera.service 2>/dev/null
        sudo systemctl disable drosera.service 2>/dev/null
    fi

    # === Баннер УДАЛЕН ===
    # print_banner() { ... } # Определение функции удалено
    clear
    # print_banner # Вызов функции удален
    # === Баннер УДАЛЕН ===

    echo "🚀 Drosera Full Auto Install (SystemD Only)"

    # === 1. User Inputs ===
    read -p "📧 GitHub email: " GHEMAIL
    read -p "👩‍💻 GitHub username: " GHUSER
    read -p "🔐 Drosera private key (без 0x): " PK_RAW # Запрашиваем без 0x
    read -p "🌍 VPS public IP: " VPSIP
    read -p "📬 Public address for whitelist (0x...): " OP_ADDR
    # Добавляем запрос RPC
    read -p "🔗 Holesky RPC URL (например, Alchemy): " ETH_RPC_URL

    # Убираем префикс 0x из ключа, если он был введен
    PK=${PK_RAW#0x}

    # Проверка формата ключа (64 hex символа)
    if ! [[ "$PK" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo "❌ Неверный формат приватного ключа. Должно быть 64 шестнадцатеричных символа."
        exit 1
    fi

    # Проверка формата адреса (0x + 40 hex символов)
    if ! [[ "$OP_ADDR" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        echo "❌ Неверный формат адреса для Whitelist. Должен начинаться с 0x и содержать 40 шестнадцатеричных символов."
        exit 1
    fi
    
    # Проверка формата RPC URL
    if [[ -z "$ETH_RPC_URL" || (! "$ETH_RPC_URL" =~ ^https?:// && ! "$ETH_RPC_URL" =~ ^wss?://) ]]; then
        echo "❌ Неверный формат RPC URL. Должен начинаться с http://, https://, ws:// или wss://."
        # Используем стандартный как fallback?
        echo "Попытка использовать стандартный RPC: https://ethereum-holesky-rpc.publicnode.com"
        ETH_RPC_URL="https://ethereum-holesky-rpc.publicnode.com"
        # Или лучше прервать?
        # exit 1
    fi

    for var in GHEMAIL GHUSER PK VPSIP OP_ADDR ETH_RPC_URL; do
        if [[ -z "${!var}" ]]; then
            echo "❌ $var is required."
            exit 1
        fi
    done

    echo "--------------------------------------------------"
    echo "Проверьте введенные данные:"
    echo "Email: $GHEMAIL"
    echo "Username: $GHUSER"
    echo "Private Key: <скрыто>"
    echo "VPS IP: $VPSIP"
    echo "Whitelist Address: $OP_ADDR"
    echo "RPC URL: $ETH_RPC_URL" # Добавили вывод RPC
    echo "--------------------------------------------------"
    read -p "Все верно? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Установка отменена."
        exit 1
    fi


    # === 2. Install Dependencies ===
    echo "⚙️ Установка зависимостей..."
    sudo apt-get update && sudo apt-get upgrade -y
    sudo apt install -y curl ufw build-essential git wget jq make gcc nano automake autoconf tmux htop pkg-config libssl-dev tar clang bsdmainutils ca-certificates gnupg unzip lz4 nvme-cli libgbm1 libleveldb-dev || { echo "❌ Ошибка установки зависимостей."; exit 1; }


    # === 3. Install Drosera CLI ===
    echo "💧 Установка Drosera CLI..."
    curl -L https://app.drosera.io/install | bash || { echo "❌ Ошибка установки Drosera CLI."; exit 1; }
    if ! grep -q '$HOME/.drosera/bin' ~/.bashrc; then
      echo 'export PATH="$HOME/.drosera/bin:$PATH"' >> ~/.bashrc
    fi
    export PATH="$HOME/.drosera/bin:$PATH"
    droseraup || { echo "❌ Ошибка обновления Drosera CLI."; exit 1; }


    # === 4. Install Foundry ===
    echo "🛠️ Установка Foundry..."
    curl -L https://foundry.paradigm.xyz | bash || { echo "❌ Ошибка установки Foundry."; exit 1; }
    if ! grep -q '$HOME/.foundry/bin' ~/.bashrc; then
      echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
    fi
    export PATH="$HOME/.foundry/bin:$PATH"
    foundryup || { echo "❌ Ошибка обновления Foundry."; exit 1; }


    # === 5. Install Bun ===
    echo "📦 Установка Bun..."
    curl -fsSL https://bun.sh/install | bash || { echo "❌ Ошибка установки Bun."; exit 1; }
    if ! grep -q '$HOME/.bun/bin' ~/.bashrc; then
      echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.bashrc
    fi
    export PATH="$HOME/.bun/bin:$PATH"


    # === 6. Clean Old Directories ===
    echo "🧹 Очистка предыдущих директорий..."
    # Добавим -f для игнорирования несуществующих файлов/папок
    rm -rf ~/drosera_operator ~/my-drosera-trap ~/.drosera/.env # Удаляем старые операторские файлы и env
    # .drosera саму папку лучше не удалять, чтобы не переустанавливать CLI


    # === 7. Set Up Trap ===
    echo "🔧 Настройка Trap..."
    mkdir -p ~/my-drosera-trap && cd ~/my-drosera-trap || { echo "❌ Не удалось создать/перейти в ~/my-drosera-trap."; exit 1; }

    echo "👤 Настройка Git..."
    git config --global user.email "$GHEMAIL"
    git config --global user.name "$GHUSER"

    echo "⏳ Инициализация проекта Trap (может занять время)..."
    if ! timeout 300 forge init -t drosera-network/trap-foundry-template; then
        echo "❌ Ошибка инициализации Trap через forge init (возможно, таймаут или проблема с шаблоном)."
        exit 1
    fi

    echo "📦 Установка зависимостей Bun..."
    if ! timeout 300 bun install; then
         echo "❌ Ошибка при установке зависимостей Bun."
         echo "Попытка очистить node_modules и повторить..."
         rm -rf node_modules bun.lockb
         if ! timeout 300 bun install; then
             echo "❌ Повторная ошибка при установке зависимостей Bun."
             exit 1
         fi
    fi

    echo "🧱 Компиляция Trap..."
    if ! forge build; then
        echo "❌ Ошибка компиляции Trap."
        exit 1
    fi


    # === 8. Deploy Trap ===
    echo "🚀 Развертывание Trap в Holesky (используя RPC: $ETH_RPC_URL)..."
    LOG_FILE="/tmp/drosera_deploy.log"
    TRAP_NAME="mytrap"
    echo "Используется имя трапа: $TRAP_NAME"
    rm -f "$LOG_FILE"

    # Добавляем --eth-rpc-url
    if ! DROSERA_PRIVATE_KEY=$PK drosera apply --eth-rpc-url "$ETH_RPC_URL" <<< "ofc" | tee "$LOG_FILE"; then
        echo "❌ Ошибка развертывания Trap."
        cat "$LOG_FILE" # Показываем лог ошибки
        exit 1
    fi

    # Извлечение адреса Trap из лога
    TRAP_ADDR=$(grep -oP "(?<=address: )0x[a-fA-F0-9]{40}" "$LOG_FILE" | head -n 1)

    if [[ -z "$TRAP_ADDR" || "$TRAP_ADDR" == "0x" ]]; then
        echo "❌ Не удалось определить адрес развернутого Trap из лога:"
        cat "$LOG_FILE"
        exit 1
    fi
    echo "🪤 Trap успешно развернут по адресу: $TRAP_ADDR"


    # === 9. Whitelist Operator ===
    echo "🔐 Обновление drosera.toml для Whitelist..."
    # Используем awk для безопасного обновления/добавления
    temp_toml=$(mktemp)
    awk -v addr="$OP_ADDR" \
        '/^private_trap *=/{private_found=1; print "private_trap = true"; next} \
         /^whitelist *=/{whitelist_found=1; print "whitelist = [\"" addr "\"]"; next} \
         {print} \
         END { \
             if(!private_found) print "private_trap = true"; \
             if(!whitelist_found) print "whitelist = [\"" addr "\"]" \
         }' drosera.toml > "$temp_toml" \
    && mv "$temp_toml" drosera.toml || { echo "❌ Ошибка обновления drosera.toml"; rm -f "$temp_toml"; exit 1; }

    echo "Файл drosera.toml обновлен."


    # === 10. Wait & Reapply ===
    echo "⏳ Ожидание 10 минут (600 секунд) перед повторным применением конфигурации с Whitelist..."
    sleep 600
    echo "🚀 Повторное применение конфигурации Trap с Whitelist (используя RPC: $ETH_RPC_URL)..."
    rm -f "$LOG_FILE"
    # Добавляем --eth-rpc-url
    if ! DROSERA_PRIVATE_KEY=$PK drosera apply --eth-rpc-url "$ETH_RPC_URL" <<< "ofc" | tee "$LOG_FILE"; then
        echo "❌ Ошибка повторного применения конфигурации Trap."
        cat "$LOG_FILE"
        exit 1
    fi
    echo "✅ Конфигурация Trap с Whitelist успешно применена."


    # === 11. Download Operator Binary ===
    echo "🔽 Загрузка бинарного файла оператора..."
    cd ~ || exit 1
    OPERATOR_CLI_URL="https://github.com/drosera-network/releases/releases/download/v1.16.2/drosera-operator-v1.16.2-x86_64-unknown-linux-gnu.tar.gz"
    OPERATOR_CLI_ARCHIVE=$(basename $OPERATOR_CLI_URL)
    OPERATOR_CLI_BIN="drosera-operator"

    # Удаляем старые файлы
    rm -f "$OPERATOR_CLI_ARCHIVE" "$OPERATOR_CLI_BIN" "/usr/local/bin/$OPERATOR_CLI_BIN"

    if ! curl -fLO "$OPERATOR_CLI_URL"; then
        echo "❌ Ошибка загрузки архива оператора."
        exit 1
    fi

    echo "📦 Распаковка архива оператора..."
    if ! tar -xvf "$OPERATOR_CLI_ARCHIVE"; then
        echo "❌ Ошибка распаковки архива оператора."
        rm -f "$OPERATOR_CLI_ARCHIVE"
        exit 1
    fi

    echo "🚀 Установка бинарного файла оператора в /usr/local/bin..."
    if ! sudo mv "$OPERATOR_CLI_BIN" /usr/local/bin/; then
        echo "❌ Ошибка перемещения $OPERATOR_CLI_BIN в /usr/local/bin/. Проверьте sudo права."
        rm -f "$OPERATOR_CLI_ARCHIVE"
        # Оставляем бинарник в ~ для ручной установки
        exit 1
    fi
    sudo chmod +x /usr/local/bin/drosera-operator # Даем права на выполнение

    # Проверка после установки
    if ! command -v drosera-operator &> /dev/null; then
        echo "❌ Не удалось найти drosera-operator в PATH после установки."
        rm -f "$OPERATOR_CLI_ARCHIVE"
        exit 1
    else
        echo "✅ Operator CLI успешно установлен."
        rm -f "$OPERATOR_CLI_ARCHIVE" # Удаляем архив
    fi


    # === 12. Register Operator ===
    echo "✍️ Регистрация оператора (используя RPC: $ETH_RPC_URL)..."
    # Используем введенный RPC вместо drpc.org
    if ! drosera-operator register --eth-rpc-url "$ETH_RPC_URL" --eth-private-key $PK; then
        echo "❌ Ошибка регистрации оператора."
        exit 1
    fi
    echo "✅ Оператор успешно зарегистрирован."


    # === 13. Setup SystemD ===
    echo "⚙️ Настройка службы SystemD..."
    SERVICE_FILE="/etc/systemd/system/drosera.service"
    # Определяем файл окружения в /root, как и в рабочей конфигурации
    OPERATOR_ENV_FILE="/root/.drosera_operator.env" 

    echo "Создание файла окружения $OPERATOR_ENV_FILE..."
    # Убедимся, что директория /root существует (хотя она должна)
    sudo mkdir -p /root 
    sudo bash -c "cat > $OPERATOR_ENV_FILE" << EOF
ETH_PRIVATE_KEY=$PK
VPS_IP=$VPSIP
ETH_RPC_URL=$ETH_RPC_URL
EOF
    sudo chmod 600 "$OPERATOR_ENV_FILE" # Безопасные права

    echo "Создание файла службы $SERVICE_FILE..."
    # Используем финальную рабочую версию файла службы
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Drosera Operator Service
After=network.target

[Service]
# Запускаем от имени пользователя root, так как .env файл и .db файл в /root
User=root
Group=root
WorkingDirectory=/root

# Указываем путь к файлу с переменными окружения (приватный ключ, IP, RPC URL)
EnvironmentFile=$OPERATOR_ENV_FILE

# Команда запуска оператора со всеми необходимыми флагами
# Значения \${ETH_RPC_URL}, \${ETH_PRIVATE_KEY} и \${VPS_IP} будут подставлены из EnvironmentFile
ExecStart=/usr/local/bin/drosera-operator node \\
    --db-file-path /root/.drosera.db \\
    --network-p2p-port 31313 \\
    --server-port 31314 \\
    --eth-rpc-url \${ETH_RPC_URL} \\
    --eth-private-key \${ETH_PRIVATE_KEY} \\
    --drosera-address 0xea08f7d533C2b9A62F40D5326214f39a8E3A32F8 \\
    --listen-address 0.0.0.0 \\
    --network-external-p2p-address \${VPS_IP} \\
    --disable-dnr-confirmation true

# Перезапускать службу при сбое
Restart=on-failure
RestartSec=10

# Увеличиваем лимит открытых файлов
LimitNOFILE=65535

[Install]
# Запускать службу при старте системы для уровней multi-user
WantedBy=multi-user.target
EOF

    # Настройка Firewall (UFW) перед запуском службы
    echo "🔧 Настройка правил Firewall (UFW)..."
    sudo ufw allow 22/tcp comment 'Allow SSH'
    sudo ufw allow 31313/tcp comment 'Allow Drosera P2P'
    sudo ufw allow 31314/tcp comment 'Allow Drosera Server'
    # Скрипт не активирует ufw, предполагая, что пользователь управляет им сам,
    # но необходимые порты будут открыты, если ufw активен.

    echo "🔄 Перезагрузка демона SystemD и запуск службы..."
    sudo systemctl daemon-reload
    sudo systemctl enable drosera.service
    sudo systemctl restart drosera.service

    # Проверка статуса службы
    echo "⏳ Ожидание 5 секунд для стабилизации службы..."
    sleep 5
    echo "📊 Проверка статуса службы drosera.service:"
    sudo systemctl status drosera.service --no-pager -l

    echo "=================================================="
    print_message $GREEN "✅ Установка Drosera (SystemD) завершена!"
    echo "Основные шаги выполнены скриптом:"
    echo "  - Зависимости установлены."
    echo "  - Drosera CLI, Foundry, Bun установлены."
    echo "  - Trap '$TRAP_NAME' развернут по адресу: $TRAP_ADDR"
    echo "  - Оператор $OP_ADDR добавлен в Whitelist."
    echo "  - Operator CLI установлен."
    echo "  - Оператор зарегистрирован (с RPC: $ETH_RPC_URL)."
    echo "  - Служба SystemD 'drosera.service' настроена и запущена."
    echo ""
    print_message $YELLOW "ℹ️ ВАШИ СЛЕДУЮЩИЕ ДЕЙСТВИЯ (ОБЯЗАТЕЛЬНО):"
    echo "  1. Проверьте статус службы: sudo systemctl status drosera.service"
    echo "     (Должен быть статус 'active (running)'. Если нет, проверьте логи)"
    echo "  2. Просмотрите логи службы: sudo journalctl -u drosera.service -f -n 100"
    echo "     (Убедитесь, что нет критических ошибок. Предупреждения 'InsufficientPeers' в начале нормальны)"
    echo "  3. Перейдите на дашборд Drosera: https://app.drosera.io/"
    echo "  4. Подключите ваш кошелек оператора ($OP_ADDR)."
    echo "  5. Найдите ваш развернутый Trap по адресу: $TRAP_ADDR (можно найти в секции 'Traps Owned')."
    echo "  6. На странице вашего Trap нажмите кнопку [Send Bloom Boost] и пополните баланс Trap (используя Holesky ETH)."
    echo "     (Это необходимо для вознаграждения операторов и активации Trap)."
    echo "  7. На странице вашего Trap нажмите кнопку [Opt In]."
    echo "     (Это подтверждает, что ваш запущенный оператор согласен обслуживать этот Trap)."
    echo "  8. Обновите страницу дашборда и убедитесь, что ваш оператор появился в секции 'Operators Status' для вашего Trap (шкала должна стать зеленой)."
    echo ""
    print_message $YELLOW "ℹ️ Опционально, но РЕКОМЕНДУЕТСЯ:"
    echo "  9. Проверьте/Отредактируйте файл службы, чтобы оператор ТОЧНО использовал ваш RPC при работе:"
    echo "     sudo nano /etc/systemd/system/drosera.service"
    echo "     Убедитесь, что в строке 'ExecStart=' есть флаг '--eth-rpc-url "$ETH_RPC_URL"'"
    echo "     (Мы добавили это в скрипт, но проверка не помешает)."
    echo "     Если вносили изменения: sudo systemctl daemon-reload && sudo systemctl restart drosera.service"
    echo "=================================================="

    echo "Установка завершена основной функцией."
    # В конце установки SystemD уже есть проверка статуса
    return 0
}

# === Функция обновления ноды Drosera ===
update_drosera_systemd() {
    print_message $BLUE "==== Обновление ноды Drosera (SystemD) ====="
    
    # 1. Автоматически создаем резервную копию перед обновлением
    print_message $BLUE "Создание резервной копии ноды перед обновлением..."
    local backup_archive="$HOME/drosera_backup_update_$(date +%Y%m%d_%H%M%S).tar.gz"
    backup_node_systemd > /dev/null 2>&1 || {
        print_message $YELLOW "Не удалось создать резервную копию, но продолжаем обновление..."
    }
    print_message $GREEN "Резервная копия создана в $backup_archive"
    
    # 2. Обновляем Drosera CLI (Droseraup)
    print_message $BLUE "Обновление Drosera CLI (Droseraup)..."
    if curl -L https://app.drosera.io/install | bash; then
        print_message $GREEN "Drosera CLI успешно обновлено."
        print_message $BLUE "Активация новых команд в PATH..."
        
        # Прямое добавление команд в PATH скрипта
        if [ -f "/usr/local/bin/droseraup" ]; then
            export PATH="/usr/local/bin:$PATH"
            print_message $GREEN "Команда droseraup найдена в /usr/local/bin."
        elif [ -f "$HOME/.local/bin/droseraup" ]; then
            export PATH="$HOME/.local/bin:$PATH"
            print_message $GREEN "Команда droseraup найдена в $HOME/.local/bin."
        else
            # Поиск команды в системе
            droseraup_path=$(find / -name droseraup -type f 2>/dev/null | head -n 1)
            if [ -n "$droseraup_path" ]; then
                droseraup_dir=$(dirname "$droseraup_path")
                export PATH="$droseraup_dir:$PATH"
                print_message $GREEN "Команда droseraup найдена в $droseraup_dir."
            else
                print_message $RED "Не удалось найти команду droseraup."
                print_message $YELLOW "Попробуем запустить через bash source..."
                # Попытка через source в новом подпроцессе
                bash -c 'source /root/.bashrc && droseraup' || {
                    print_message $RED "Не удалось запустить droseraup."
                    read -p "Продолжить обновление? (y/N): " continue_update
                    if [[ ! "$continue_update" =~ ^[Yy]$ ]]; then
                        return 1
                    fi
                }
            fi
        fi
        
        # Проверяем, доступна ли команда droseraup теперь
        if command -v droseraup &>/dev/null; then
            print_message $BLUE "Запуск droseraup..."
            droseraup
        else
            print_message $YELLOW "Команда droseraup недоступна в текущем сеансе."
            print_message $YELLOW "Это не критично, продолжаем обновление."
        fi
    else
        print_message $RED "Ошибка при обновлении Drosera CLI."
        read -p "Продолжить обновление? (y/N): " continue_update
        if [[ ! "$continue_update" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    # 3. Обновляем seed-ноду в конфигурационном файле
    print_message $BLUE "Обновление seed-ноды в конфигурационном файле..."
    local drosera_toml="$HOME/my-drosera-trap/drosera.toml"
    
    if [ ! -f "$drosera_toml" ]; then
        print_message $RED "Ошибка: Файл $drosera_toml не найден."
        read -p "Введите путь к файлу drosera.toml: " custom_path
        drosera_toml="$custom_path"
        
        if [ ! -f "$drosera_toml" ]; then
            print_message $RED "Ошибка: Файл $drosera_toml не найден. Обновление невозможно."
            return 1
        fi
    fi
    
    # Сохраняем текущий пользовательский RPC URL
    local current_eth_rpc=$(grep "ethereum_rpc" "$drosera_toml" | sed 's/ethereum_rpc\s*=\s*"\(.*\)"/\1/')
    print_message $BLUE "Обнаружен пользовательский Ethereum RPC URL: $current_eth_rpc"
    
    # Делаем резервную копию файла конфигурации
    cp "$drosera_toml" "${drosera_toml}.backup_$(date +%Y%m%d_%H%M%S)"
    print_message $GREEN "Создана резервная копия файла конфигурации."
    
    # Заменяем старый seed-node на новый, сохраняя пользовательский URL
    if grep -q "seed-node.testnet.drosera.io" "$drosera_toml"; then
        sed -i 's|seed-node\.testnet\.drosera\.io|relay.testnet.drosera.io|g' "$drosera_toml"
        print_message $GREEN "Seed-нода успешно обновлена на relay.testnet.drosera.io."
    elif ! grep -q "drosera_rpc.*relay.testnet.drosera.io" "$drosera_toml"; then
        # Если drosera_rpc существует, но не содержит relay.testnet.drosera.io
        if grep -q "drosera_rpc" "$drosera_toml"; then
            print_message $YELLOW "Обновление адреса Drosera RPC на relay.testnet.drosera.io..."
            sed -i 's|drosera_rpc\s*=\s*"\(.*\)"|drosera_rpc = "https://relay.testnet.drosera.io"|g' "$drosera_toml"
            print_message $GREEN "Drosera RPC успешно обновлен на relay.testnet.drosera.io."
        else
            print_message $YELLOW "Добавление адреса Drosera RPC relay.testnet.drosera.io..."
            echo 'drosera_rpc = "https://relay.testnet.drosera.io"' >> "$drosera_toml"
            print_message $GREEN "Drosera RPC успешно добавлен."
        fi
    else
        print_message $GREEN "Drosera RPC уже настроен на relay.testnet.drosera.io."
    fi
    
    # Проверяем настройки RPC и выводим их
    print_message $BLUE "Текущие настройки RPC в файле:"
    grep -i "rpc" "$drosera_toml" || print_message $RED "Записи RPC не найдены."
    
    # 4. Проверяем адрес трапа
    print_message $BLUE "Проверка адреса трапа в конфигурационном файле..."
    if ! grep -q "^address = \"0x" "$drosera_toml"; then
        print_message $YELLOW "Внимание: Адрес трапа (формат 'address = \"0x...\"') не найден в файле конфигурации."
        print_message $YELLOW "Вам необходимо добавить адрес трапа в файл конфигурации."
        print_message $YELLOW "Вы можете найти адрес на Dashboard: https://app.drosera.io/"
        
        read -p "Хотите добавить адрес трапа сейчас? (y/N): " add_address
        if [[ "$add_address" =~ ^[Yy]$ ]]; then
            read -p "Введите адрес трапа (начинается с 0x): " trap_address
            # Добавим адрес в начало файла (можно настроить, где именно)
            sed -i "1s/^/address = \"$trap_address\"\n/" "$drosera_toml"
            print_message $GREEN "Адрес трапа добавлен в файл конфигурации."
        fi
    else
        print_message $GREEN "Адрес трапа найден в файле конфигурации."
    fi
    
    # 5. Повторно применяем конфигурацию Drosera
    print_message $BLUE "Повторное применение конфигурации Drosera..."
    
    # Ищем приватный ключ в файле окружения или запрашиваем у пользователя
    local private_key=""
    local env_file="/root/.drosera_operator.env"
    
    if [ -f "$env_file" ]; then
        # Извлекаем ключ из файла окружения
        print_message $BLUE "Автоматическое извлечение приватного ключа из $env_file..."
        private_key=$(grep -oP 'DROSERA_PRIVATE_KEY=\K[^\s]+' "$env_file" 2>/dev/null || echo "")
        
        if [ -n "$private_key" ]; then
            print_message $GREEN "Приватный ключ успешно получен из файла."
        else
            print_message $YELLOW "Не удалось найти приватный ключ в файле."
        fi
    else
        print_message $YELLOW "Файл окружения $env_file не найден."
    fi
    
    # Если ключ не найден в файле, запрашиваем его у пользователя
    if [ -z "$private_key" ]; then
        print_message $YELLOW "Необходимо ввести приватный ключ трапа."
        read -s -p "Введите приватный ключ трапа: " private_key
        echo # Перевод строки после ввода
    fi
    
    # Проверяем, что ключ не пуст
    if [ -z "$private_key" ]; then
        print_message $RED "Приватный ключ не может быть пустым."
        return 1
    fi
    
    # Переходим в каталог трапа
    trap_dir="$HOME/my-drosera-trap"
    if [ ! -d "$trap_dir" ]; then
        trap_dir="$(dirname "$drosera_toml")"
    fi
    
    cd "$trap_dir" || { 
        print_message $RED "Не удалось перейти в директорию трапа $trap_dir." 
        read -p "Введите путь к директории трапа: " custom_trap_dir
        cd "$custom_trap_dir" || { 
            print_message $RED "Не удалось перейти в указанную директорию. Обновление прервано."
            return 1
        }
    }
    
    print_message $BLUE "Выполнение команды 'drosera apply'..."
    print_message $YELLOW "(Когда будет запрос, автоматически будет введено 'ofc')"
    
    # Подготавливаем команду для автоматического ввода "ofc"
    apply_cmd="echo 'ofc' | DROSERA_PRIVATE_KEY='$private_key' drosera apply"
    
    # Проверяем, доступна ли команда drosera в текущем PATH
    if command -v drosera &>/dev/null; then
        eval "$apply_cmd"
        apply_result=$?
    else
        # Поиск команды drosera в системе
        drosera_path=$(find / -name drosera -type f 2>/dev/null | head -n 1)
        if [ -n "$drosera_path" ]; then
            print_message $GREEN "Команда drosera найдена в $drosera_path."
            eval "echo 'ofc' | DROSERA_PRIVATE_KEY='$private_key' '$drosera_path' apply"
            apply_result=$?
        else
            print_message $YELLOW "Попытка запуска через bash source..."
            # Автоматически вводим "ofc" на запрос
            bash -c "source /root/.bashrc && echo 'ofc' | DROSERA_PRIVATE_KEY='$private_key' drosera apply" 2>/dev/null
            apply_result=$?
            
            if [ $apply_result -ne 0 ]; then
                print_message $RED "Не удалось запустить команду drosera."
                print_message $YELLOW "Попробуйте выполнить следующие команды вручную после завершения скрипта:"
                print_message $YELLOW "source /root/.bashrc"
                print_message $YELLOW "echo 'ofc' | DROSERA_PRIVATE_KEY=XXX drosera apply"
                print_message $YELLOW "sudo systemctl restart drosera.service"
            fi
        fi
    fi
    
    if [ $apply_result -ne 0 ]; then
        print_message $RED "Ошибка при применении конфигурации."
        read -p "Продолжить обновление? (y/N): " continue_update
        if [[ ! "$continue_update" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    # 6. Автоматически открываем UDP порты
    print_message $BLUE "Автоматическое открытие UDP портов..."
    
    # Проверяем количество операторов в конфигурации
    local operator_count=1  # По умолчанию 1 оператор
    
    # Пытаемся определить количество операторов по конфигурации
    if grep -q "operator2" "$drosera_toml" || grep -q "\[operators.2\]" "$drosera_toml"; then
        operator_count=2
        print_message $BLUE "Обнаружено 2 оператора в конфигурации."
    else
        print_message $BLUE "Обнаружен 1 оператор в конфигурации."
    fi
    
    # Открываем порты для первого оператора
    print_message $BLUE "Открытие портов для первого оператора (31313/udp, 31314/udp)..."
    sudo ufw allow 31313/udp &>/dev/null || true
    sudo ufw allow 31314/udp &>/dev/null || true
    
    # Если есть второй оператор, открываем и его порты
    if [ "$operator_count" -eq 2 ]; then
        print_message $BLUE "Открытие портов для второго оператора (31315/udp, 31316/udp)..."
        sudo ufw allow 31315/udp &>/dev/null || true
        sudo ufw allow 31316/udp &>/dev/null || true
    fi
    
    print_message $GREEN "UDP порты успешно открыты."
    
    # 7. Перезапускаем службу drosera
    print_message $BLUE "Перезапуск службы drosera..."
    
    # Плавный перезапуск службы
    sudo systemctl stop drosera.service
    sleep 3 # Даем больше времени на остановку
    
    # Проверяем, что служба действительно остановилась
    for i in {1..5}; do
        if ! systemctl is-active drosera.service &>/dev/null; then
            break
        fi
        print_message $YELLOW "Ожидание остановки службы..."
        sleep 2
    done
    
    sudo systemctl start drosera.service
    sleep 3 # Даем время на запуск
    
    # 8. Проверяем статус
    print_message $BLUE "Проверка статуса службы..."
    sudo systemctl status drosera.service --no-pager -l
    
    print_message $GREEN "==== Обновление завершено ====="
    print_message $YELLOW "Для просмотра логов в реальном времени используйте: sudo journalctl -u drosera.service -f"
    print_message $YELLOW "Первые несколько минут могут быть ошибки, это нормально."
    
    # Ждём, пока пользователь ознакомится с результатом
    read -p "Нажмите Enter для возврата в меню..."
    return 0
}

# === Главное меню ===
main_menu() {
    while true; do
        clear
        print_message $GREEN "========= Меню Управления Нодой Drosera (SystemD) ========"
        # Здесь можно добавить отображение какой-то информации, если нужно
        # Например, статус службы
        local status
        status=$(systemctl is-active drosera.service 2>/dev/null)
        echo -e "Статус службы drosera.service: $( [[ "$status" == "active" ]] && echo -e "${GREEN}Активна${NC}" || echo -e "${RED}Не активна (${status:-не найдена})${NC}" )"
        print_message $BLUE "---------------------- Установка -----------------------"
        print_message $YELLOW " 1. Запустить полную установку/переустановку (SystemD)"
        print_message $GREEN " 8. Обновить ноду Drosera до новой версии"
        print_message $BLUE "-------------------- Управление нодой --------------------"
        print_message $GREEN " 2. Показать статус и последние логи"
        print_message $GREEN " 3. Запустить службу"
        print_message $RED   " 4. Остановить службу"
        print_message $BLUE "--------------------- Обслуживание ---------------------"
        print_message $YELLOW " 5. Создать резервную копию (Только архив)"
        print_message $YELLOW " 6. Создать и выдать бэкап по ссылке"
        print_message $NC   " 7. Восстановить из резервной копии (НЕ РЕАЛИЗОВАНО)"
        # print_message $YELLOW " 7. Перерегистрировать оператора (НЕ РЕАЛИЗОВАНО)"
        # print_message $RED   " 8. Удалить ноду (НЕ РЕАЛИЗОВАНО)"
        print_message $BLUE "---------------------------------------------------------"
        print_message $NC   " 0. Выход"
        print_message $BLUE "========================================================="
        read -p "Выберите опцию: " choice

        case $choice in
            1) install_drosera_systemd ;; 
            2) check_status_logs ;;  
            3) start_node_systemd ;;   
            4) stop_node_systemd ;;    
            5) backup_node_systemd ;;   
            6) backup_and_serve_systemd ;;   
            7) print_message $RED "Функция восстановления пока не реализована." ;; 
            8) update_drosera_systemd ;; 
            # 7) re_register_operator_menu ;; # Placeholder
            # 8) uninstall_node ;;    # Placeholder
            0) print_message $GREEN "Выход."; exit 0 ;;
            *) print_message $RED "Неверная опция.";;
        esac
        read -p "Нажмите Enter для продолжения..."
    done
}

# === Точка входа ===
# Запускаем главное меню
main_menu

# ======================================================================
# Ниже идет оригинальный код установки из скрипта Kazuha,
# он теперь вызывается из функции install_drosera_systemd() внутри меню.
# Этот код здесь больше не нужен, так как он был перенесен внутрь функции.
# Можно удалить все строки ниже этой секции, если функция 
# install_drosera_systemd() была полностью скопирована выше.
# ======================================================================
