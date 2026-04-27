#!/bin/bash
# ==============================================================================
# lib/common.sh — Doc-Validator · Biblioteca compartilhada
# Importada por setup-infra.sh, setup-rails.sh, setup-go.sh e setup.sh.
# NÃO execute diretamente.
# ==============================================================================

# ──────────────────────────────────────────────
# GUARD
# ──────────────────────────────────────────────
[[ "${COMMON_LIB_LOADED:-}" == "1" ]] && return 0 || true

# ──────────────────────────────────────────────
# CORES
# ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ──────────────────────────────────────────────
# CONFIGURAÇÕES GLOBAIS
# (podem ser sobrescritas antes do source se necessário)
# ──────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/setup.log}"

MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_SLEEP="${RETRY_SLEEP:-5}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-3}"
RAILS_READY_TIMEOUT="${RAILS_READY_TIMEOUT:-120}"
RAILS_READY_INTERVAL="${RAILS_READY_INTERVAL:-5}"
MKCERT_VERSION="${MKCERT_VERSION:-v1.4.4}"

# Rastreia etapa atual para mensagens de erro contextualizadas
CURRENT_STEP="inicialização"
START_TIME="${START_TIME:-$(date +%s)}"

# ──────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────
_ts()         { date '+%H:%M:%S'; }
_log_raw()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

log_info()    { echo -e "${GRAY}[$(_ts)]${NC} ${CYAN}${BOLD}[INFO]${NC}  $*";  _log_raw "[INFO]  $*"; }
log_ok()      { echo -e "${GRAY}[$(_ts)]${NC} ${GREEN}${BOLD}[ OK ]${NC}  $*"; _log_raw "[ OK ]  $*"; }
log_warn()    { echo -e "${GRAY}[$(_ts)]${NC} ${YELLOW}${BOLD}[WARN]${NC}  $*"; _log_raw "[WARN]  $*"; }
log_error()   { echo -e "${GRAY}[$(_ts)]${NC} ${RED}${BOLD}[ERR ]${NC}  $*";   _log_raw "[ERR ]  $*"; }
log_debug()   { _log_raw "[DEBG]  $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}"; _log_raw "======  $*  ======"; }
log_step()    { echo -e "  ${BOLD}▸${NC} $*"; _log_raw "  >> $*"; CURRENT_STEP="$*"; }
die()         { log_error "$*"; exit 1; }

log_banner() {
  local title="$1"
  local subtitle="${2:-}"
  echo -e "\n${BOLD}${CYAN}┌─────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}${CYAN}│  $title${NC}"
  [[ -n "$subtitle" ]] && echo -e "${GRAY}│  $subtitle${NC}"
  echo -e "${BOLD}${CYAN}└─────────────────────────────────────────┘${NC}\n"
  _log_raw "=== $title — $subtitle ==="
}

# ──────────────────────────────────────────────
# INICIALIZA LOG FILE
# ──────────────────────────────────────────────
_init_log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  {
    echo "==============================================================="
    echo " Doc-Validator Setup — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "==============================================================="
  } >> "$LOG_FILE"
}

# ──────────────────────────────────────────────
# TRAP — captura erros não tratados
# ──────────────────────────────────────────────
on_error() {
  local exit_code=$?
  local line_number=${1:-"?"}
  echo ""
  log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_error "FALHA na etapa: ${BOLD}$CURRENT_STEP${NC}"
  log_error "Linha $line_number — código de saída: $exit_code"
  log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "\n${YELLOW}${BOLD}Dicas de diagnóstico:${NC}"
  echo -e "  📋 Log completo:  ${BOLD}cat $LOG_FILE${NC}"
  echo -e "  🐳 Status geral:  ${BOLD}docker ps -a${NC}"
  echo -e "  📦 Infra:         ${BOLD}docker compose -f infra-doc-validator/docker-compose.yml logs --tail=50${NC}"
  echo -e "  💎 Rails:         ${BOLD}docker compose -f rails-doc-validator/docker-compose-rails-infra.yml logs --tail=50 web${NC}"
  echo -e "  🐹 Go Relay:      ${BOLD}docker compose -f go-relay/docker-compose-go-infra.yml logs --tail=50${NC}"
  echo -e "  📊 Grafana:       ${BOLD}docker compose -f infra-doc-validator/docker-compose.yml logs grafana --tail=30${NC}"
  echo ""
  _log_raw "SETUP ABORTADO — etapa: $CURRENT_STEP | linha: $line_number | código: $exit_code"
}
trap 'on_error $LINENO' ERR

# ──────────────────────────────────────────────
# DEPENDÊNCIAS
# ──────────────────────────────────────────────
check_dependencies() {
  log_step "Verificando dependências do sistema"

  for cmd in docker curl; do
    if command -v "$cmd" &>/dev/null; then
      log_ok "'$cmd' encontrado: $(command -v "$cmd")"
    else
      die "'$cmd' não encontrado. Instale antes de continuar."
    fi
  done

  local compose_version
  compose_version=$(docker compose version 2>/dev/null) \
    || die "Docker Compose plugin não encontrado. Execute: 'docker compose version' para verificar."
  log_ok "Docker Compose: $compose_version"

  docker info &>/dev/null \
    || die "Daemon Docker não está rodando. Inicie o Docker e tente novamente."
  log_ok "Docker daemon: ativo"
}

# ──────────────────────────────────────────────
# .ENV
# ──────────────────────────────────────────────
ensure_env() {
  local dir="$1"
  local label="$2"
  local env_file="$dir/.env"
  local example_file="$dir/.env.example"

  log_step "Verificando .env — $label"

  if [[ -f "$env_file" ]]; then
    log_ok ".env já existe em $dir"
    return 0
  fi

  if [[ -f "$example_file" ]]; then
    cp "$example_file" "$env_file"
    log_ok "Criado $env_file a partir de .env.example"
    log_warn "Revise as variáveis em $env_file antes de usar em produção."
  else
    die "Nem .env nem .env.example encontrados em '$dir'. Crie o arquivo manualmente."
  fi
}

# ──────────────────────────────────────────────
# REDE COMPARTILHADA
# ──────────────────────────────────────────────
ensure_network() {
  log_step "Verificando rede compartilhada local-infra-net"

  if docker network inspect local-infra-net >/dev/null 2>&1; then
    log_ok "Rede local-infra-net já existe"
  else
    log_info "Criando rede local-infra-net..."
    docker network create local-infra-net
    log_ok "Rede local-infra-net criada"
  fi
}

# ──────────────────────────────────────────────
# AGUARDA CONTAINER HEALTHY
# ──────────────────────────────────────────────
wait_for_healthy() {
  local service_name="$1"
  local compose_file="$2"
  local elapsed=0

  echo -ne "  ⏳ Aguardando '${BOLD}$service_name${NC}' ficar healthy"

  while true; do
    local health status
    health=$(docker compose -f "$compose_file" ps --format "{{.Health}}" "$service_name" 2>/dev/null || echo "")
    status=$(docker compose -f "$compose_file" ps --format "{{.Status}}" "$service_name" 2>/dev/null || echo "")

    log_debug "[$service_name] health='$health' status='$status' elapsed=${elapsed}s"

    if [[ "$health" == *"healthy"* ]]; then
      echo -e "\r  ${GREEN}✔${NC}  '${BOLD}$service_name${NC}' está healthy! (${elapsed}s)                    "
      _log_raw "[ OK ]  '$service_name' healthy após ${elapsed}s"
      return 0
    fi

    if [[ "$status" == *"Exited"* || "$status" == *"Exit"* ]]; then
      echo -e "\r  ${YELLOW}⚠${NC}  '$service_name' caiu — tentando reiniciar...    "
      _log_raw "[WARN]  '$service_name' caiu — status: '$status'. Reiniciando..."
      docker compose -f "$compose_file" up -d "$service_name" &>/dev/null
    fi

    if (( elapsed >= HEALTH_TIMEOUT )); then
      echo ""
      _log_raw "[ERR ]  Timeout em '$service_name' após ${elapsed}s"
      log_warn "Últimos logs de '$service_name':"
      docker compose -f "$compose_file" logs --tail=20 "$service_name" 2>&1 | tee -a "$LOG_FILE" || true
      die "Timeout: '$service_name' não ficou healthy em ${HEALTH_TIMEOUT}s."
    fi

    echo -n "."
    sleep "$HEALTH_INTERVAL"
    (( elapsed += HEALTH_INTERVAL ))
  done
}

# ──────────────────────────────────────────────
# AGUARDA CONTAINER RUNNING (sem healthcheck)
# ──────────────────────────────────────────────
wait_for_running() {
  local service_name="$1"
  local compose_file="$2"
  local retries=0
  local elapsed=0

  echo -ne "  ⏳ Aguardando '${BOLD}$service_name${NC}' subir"

  while true; do
    local status
    status=$(docker compose -f "$compose_file" ps --format "{{.Status}}" "$service_name" 2>/dev/null || echo "")

    log_debug "[$service_name] status='$status' elapsed=${elapsed}s retries=$retries"

    if [[ "$status" == *"Up"* || "$status" == *"running"* ]]; then
      echo -e "\r  ${GREEN}✔${NC}  '${BOLD}$service_name${NC}' está no ar! (${elapsed}s)                    "
      _log_raw "[ OK ]  '$service_name' running após ${elapsed}s"
      return 0
    fi

    if [[ "$status" == *"Exited"* || "$status" == *"Exit"* ]]; then
      if (( retries < MAX_RETRIES )); then
        echo -e "\r  ${YELLOW}⚠${NC}  '$service_name' caiu — tentando reiniciar ($((retries+1))/$MAX_RETRIES)..."
        _log_raw "[WARN]  '$service_name' caiu — tentativa $((retries+1))/$MAX_RETRIES"
        docker compose -f "$compose_file" logs --tail=10 "$service_name" >> "$LOG_FILE" 2>&1 || true
        docker compose -f "$compose_file" up -d "$service_name" &>/dev/null
        (( retries++ ))
        sleep "$RETRY_SLEEP"
        continue
      else
        echo ""
        log_warn "Últimos logs de '$service_name':"
        docker compose -f "$compose_file" logs --tail=30 "$service_name" 2>&1 | tee -a "$LOG_FILE" || true
        die "'$service_name' falhou após $MAX_RETRIES tentativas."
      fi
    fi

    if (( elapsed >= HEALTH_TIMEOUT )); then
      echo ""
      _log_raw "[ERR ]  Timeout em '$service_name' após ${elapsed}s"
      log_warn "Últimos logs de '$service_name':"
      docker compose -f "$compose_file" logs --tail=20 "$service_name" 2>&1 | tee -a "$LOG_FILE" || true
      die "Timeout: '$service_name' não subiu em ${HEALTH_TIMEOUT}s."
    fi

    echo -n "."
    sleep "$HEALTH_INTERVAL"
    (( elapsed += HEALTH_INTERVAL ))
  done
}

# ──────────────────────────────────────────────
# AGUARDA RAILS PRONTO (probe via ActiveRecord)
# ──────────────────────────────────────────────
wait_for_rails_ready() {
  local compose_file="$1"
  local elapsed=0

  echo -ne "  ⏳ Aguardando Rails carregar ambiente e conectar ao DB"

  while true; do
    if docker compose -f "$compose_file" exec -T web \
        rails runner "ActiveRecord::Base.connection.execute('SELECT 1')" \
        >> "$LOG_FILE" 2>&1; then
      echo -e "\r  ${GREEN}✔${NC}  Rails pronto — DB conectado! (${elapsed}s)   "
      _log_raw "[ OK ]  Rails pronto após ${elapsed}s"
      return 0
    fi

    log_debug "Probe Rails falhou (${elapsed}s) — ainda inicializando"

    if (( elapsed >= RAILS_READY_TIMEOUT )); then
      echo ""
      _log_raw "[ERR ]  Rails não ficou pronto em ${RAILS_READY_TIMEOUT}s"
      log_warn "Últimos logs do container 'web':"
      docker compose -f "$compose_file" logs --tail=30 web 2>&1 | tee -a "$LOG_FILE" || true
      die "Timeout: Rails não ficou pronto em ${RAILS_READY_TIMEOUT}s."
    fi

    echo -n "."
    sleep "$RAILS_READY_INTERVAL"
    (( elapsed += RAILS_READY_INTERVAL ))
  done
}

# ──────────────────────────────────────────────
# EXEC COM RETRY
# ──────────────────────────────────────────────
exec_in_container() {
  local compose_file="$1"
  local service="$2"
  shift 2
  local cmd=("$@")
  local attempt=1

  while (( attempt <= MAX_RETRIES )); do
    log_step "${cmd[*]} (tentativa $attempt/$MAX_RETRIES)"

    if docker compose -f "$compose_file" exec -T "$service" "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
      log_ok "${cmd[*]} — concluído"
      return 0
    fi

    log_warn "Comando '${cmd[*]}' falhou."
    (( attempt < MAX_RETRIES )) && { log_info "Aguardando ${RETRY_SLEEP}s..."; sleep "$RETRY_SLEEP"; }
    (( attempt++ ))
  done

  die "Comando '${cmd[*]}' falhou após $MAX_RETRIES tentativas. Log: $LOG_FILE"
}

COMMON_LIB_LOADED=1
