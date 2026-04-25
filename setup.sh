#!/bin/bash
# ==============================================================================
# setup.sh — Doc-Validator Full Stack Bootstrap
# Sobe Infra Base → Rails → Go Relay garantindo healthchecks e ordem correta.
# 
# VERSÃO: 2.0.0 (com Observabilidade - Grafana/Loki)
# ==============================================================================
set -euo pipefail

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
# CONFIGURAÇÕES
# ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/setup.log"
MAX_RETRIES=3
RETRY_SLEEP=5
HEALTH_TIMEOUT=180
HEALTH_INTERVAL=3
RAILS_READY_TIMEOUT=120
RAILS_READY_INTERVAL=5

MKCERT_VERSION="v1.4.4"
CERTS_DIR="$SCRIPT_DIR/rails-doc-validator/docker/certs"

# Rastreia em qual etapa estamos para mensagem de erro contextualizada
CURRENT_STEP="inicialização"
START_TIME=$(date +%s)

# ──────────────────────────────────────────────
# LOGGING — escreve no terminal E no arquivo
# ──────────────────────────────────────────────
_ts() { date '+%H:%M:%S'; }
_log_raw() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

log_info()    { echo -e "${GRAY}[$(_ts)]${NC} ${CYAN}${BOLD}[INFO]${NC}  $*";  _log_raw "[INFO]  $*"; }
log_ok()      { echo -e "${GRAY}[$(_ts)]${NC} ${GREEN}${BOLD}[ OK ]${NC}  $*"; _log_raw "[ OK ]  $*"; }
log_warn()    { echo -e "${GRAY}[$(_ts)]${NC} ${YELLOW}${BOLD}[WARN]${NC}  $*"; _log_raw "[WARN]  $*"; }
log_error()   { echo -e "${GRAY}[$(_ts)]${NC} ${RED}${BOLD}[ERR ]${NC}  $*";   _log_raw "[ERR ]  $*"; }
log_debug()   { _log_raw "[DEBG]  $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}"; _log_raw "======  $*  ======"; }
log_step()    { echo -e "  ${BOLD}▸${NC} $*"; _log_raw "  >> $*"; CURRENT_STEP="$*"; }
die()         { log_error "$*"; exit 1; }

# ──────────────────────────────────────────────
# TRAP — captura qualquer erro não tratado
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
  echo -e "  📦 Logs da infra: ${BOLD}docker compose -f infra-doc-validator/docker-compose.yml logs --tail=50${NC}"
  echo -e "  💎 Logs do Rails: ${BOLD}docker compose -f rails-doc-validator/docker-compose-rails-infra.yml logs --tail=50 web${NC}"
  echo -e "  🐹 Logs do Relay: ${BOLD}docker compose -f go-relay/docker-compose-go-infra.yml logs --tail=50${NC}"
  echo -e "  📊 Logs do Grafana: ${BOLD}docker compose -f infra-doc-validator/docker-compose.yml logs grafana --tail=30${NC}"
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
    log_debug "Checando '$cmd'..."
    if command -v "$cmd" &>/dev/null; then
      log_ok "'$cmd' encontrado: $(command -v "$cmd")"
    else
      die "'$cmd' não encontrado. Instale antes de continuar."
    fi
  done

  log_debug "Checando Docker Compose plugin..."
  local compose_version
  compose_version=$(docker compose version 2>/dev/null) \
    || die "Docker Compose plugin não encontrado. Execute: 'docker compose version' para verificar."
  log_ok "Docker Compose: $compose_version"

  log_debug "Checando se o daemon Docker está rodando..."
  docker info &>/dev/null \
    || die "Daemon Docker não está rodando. Inicie o Docker e tente novamente."
  log_ok "Docker daemon: ativo"
}

# ──────────────────────────────────────────────
# .ENV — copia .env.example se não existir
# ──────────────────────────────────────────────
ensure_env() {
  local dir="$1"
  local label="$2"
  local env_file="$dir/.env"
  local example_file="$dir/.env.example"

  log_step "Verificando .env — $label"
  log_debug "Procurando $env_file"

  if [[ -f "$env_file" ]]; then
    log_ok ".env já existe em $dir"
    return 0
  fi

  log_debug ".env não encontrado, procurando .env.example em $dir"

  if [[ -f "$example_file" ]]; then
    cp "$example_file" "$env_file"
    log_ok "Criado $env_file a partir de .env.example"
    log_warn "Revise as variáveis em $env_file antes de usar em produção."
  else
    die "Nem .env nem .env.example encontrados em '$dir'. Crie o arquivo manualmente."
  fi
}

# ──────────────────────────────────────────────
# VERIFICAR REDE COMPARTILHADA (não criar)
# ──────────────────────────────────────────────
ensure_network() {
  log_step "Verificando rede compartilhada local-infra-net"
  
  if docker network inspect local-infra-net >/dev/null 2>&1; then
    log_ok "Rede local-infra-net já existe"
  else
    log_info "Rede local-infra-net não encontrada. Criando..."
    docker network create local-infra-net
    log_ok "Rede local-infra-net criada"
  fi
}

# ──────────────────────────────────────────────
# CERTIFICADOS — instala mkcert + gera certs
# ──────────────────────────────────────────────
setup_certificates() {
  log_section "0.5 · Certificados HTTPS (mkcert)"

  # ── Instala mkcert se não existir ─────────────────────────────────────────
  log_step "Verificando instalação do mkcert"

  if command -v mkcert &>/dev/null; then
    log_ok "mkcert já instalado: $(mkcert --version)"
  else
    log_info "mkcert não encontrado. Iniciando instalação..."

    local arch os_name binary_name=""
    arch="$(uname -m)"
    os_name="$(uname -s)"
    log_debug "OS: $os_name | Arch: $arch"

    if [[ "$os_name" == "Darwin" ]]; then
      log_step "macOS detectado — instalando via Homebrew"
      command -v brew &>/dev/null \
        || die "Homebrew não encontrado. Instale em https://brew.sh ou instale mkcert manualmente."
      brew install mkcert nss
      log_ok "mkcert instalado via Homebrew"

    else
      log_step "Linux detectado — baixando binário para $arch"
      case "$arch" in
        x86_64)  binary_name="mkcert-${MKCERT_VERSION}-linux-amd64"  ;;
        aarch64) binary_name="mkcert-${MKCERT_VERSION}-linux-arm64"  ;;
        armv7l)  binary_name="mkcert-${MKCERT_VERSION}-linux-arm"    ;;
        *) die "Arquitetura '$arch' não suportada. Instale mkcert manualmente: https://github.com/FiloSottile/mkcert" ;;
      esac

      local download_url="https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/${binary_name}"
      log_debug "Baixando: $download_url"
      log_info "Baixando $binary_name..."

      local tmp_bin
      tmp_bin="$(mktemp)"

      if ! curl -fsSL "$download_url" -o "$tmp_bin"; then
        rm -f "$tmp_bin"
        die "Falha ao baixar mkcert. Verifique sua conexão ou baixe manualmente de: $download_url"
      fi

      chmod +x "$tmp_bin"
      log_debug "Movendo binário para /usr/local/bin/mkcert (pode pedir sudo)"
      sudo mv "$tmp_bin" /usr/local/bin/mkcert
      log_ok "mkcert instalado em /usr/local/bin/mkcert"
    fi

    mkcert --version &>/dev/null \
      || die "mkcert instalado mas não está funcionando. Verifique o PATH ou instale manualmente."
    log_ok "mkcert $(mkcert --version) — OK"
  fi

  # ── Instala CA local ───────────────────────────────────────────────────────
  log_step "Instalando autoridade certificadora local (CA)"
  log_debug "Executando mkcert -install"

  mkcert -install \
    || die "Falha ao instalar a CA local do mkcert. Tente executar 'mkcert -install' manualmente."
  log_ok "CA local instalada — o navegador confiará nos certificados gerados"

  # ── Verifica se já existem ─────────────────────────────────────────────────
  log_step "Verificando certificados existentes em $CERTS_DIR"

  if [[ -f "$CERTS_DIR/localhost.pem" && -f "$CERTS_DIR/localhost-key.pem" ]]; then
    log_ok "Certificados já existem — pulando geração"
    log_debug "  cert: $CERTS_DIR/localhost.pem"
    log_debug "  key:  $CERTS_DIR/localhost-key.pem"
    return 0
  fi

  log_info "Certificados não encontrados. Gerando..."

  # ── Garante estrutura de diretórios ───────────────────────────────────────
  log_step "Criando estrutura de diretórios para certificados"
  mkdir -p "$CERTS_DIR"
  log_debug "Diretório criado/verificado: $CERTS_DIR"

  local nginx_conf="$SCRIPT_DIR/rails-doc-validator/docker/nginx/nginx.conf"
  if [[ ! -f "$nginx_conf" ]]; then
    log_warn "nginx.conf não encontrado em $nginx_conf — certifique-se de que ele existe antes de subir o nginx."
  else
    log_debug "nginx.conf encontrado: $nginx_conf"
  fi

  # ── Gera os certificados ───────────────────────────────────────────────────
  log_step "Gerando certificados com mkcert (localhost + 127.0.0.1)"
  log_debug "Entrando em $CERTS_DIR para geração"

  pushd "$CERTS_DIR" > /dev/null
  log_debug "Executando: mkcert localhost 127.0.0.1"

  if ! mkcert localhost 127.0.0.1; then
    popd > /dev/null
    die "Falha ao gerar certificados. Verifique se a CA foi instalada corretamente ('mkcert -install')."
  fi

  popd > /dev/null
  log_ok "Certificados gerados em $CERTS_DIR"

  log_debug "Arquivos gerados em $CERTS_DIR:"
  ls -la "$CERTS_DIR" >> "$LOG_FILE" 2>&1 || true

  # ── Normaliza nomes (mkcert gera localhost+1.pem em alguns ambientes) ──────
  log_step "Normalizando nomes dos certificados"

  local pem key
  pem="$(ls "$CERTS_DIR"/localhost*.pem 2>/dev/null | grep -v '\-key\.pem' | head -1 || true)"
  key="$(ls "$CERTS_DIR"/localhost*-key.pem 2>/dev/null | head -1 || true)"

  log_debug "Certificado encontrado: ${pem:-'NENHUM'}"
  log_debug "Chave encontrada:       ${key:-'NENHUMA'}"

  if [[ -z "$pem" || -z "$key" ]]; then
    die "Certificados não encontrados em $CERTS_DIR após geração. Conteúdo: $(ls "$CERTS_DIR" 2>/dev/null || echo 'vazio')"
  fi

  if [[ "$(basename "$pem")" != "localhost.pem" ]]; then
    mv "$pem" "$CERTS_DIR/localhost.pem"
    log_info "Renomeado: $(basename "$pem") → localhost.pem"
  else
    log_debug "Nome do certificado já está correto: localhost.pem"
  fi

  if [[ "$(basename "$key")" != "localhost-key.pem" ]]; then
    mv "$key" "$CERTS_DIR/localhost-key.pem"
    log_info "Renomeado: $(basename "$key") → localhost-key.pem"
  else
    log_debug "Nome da chave já está correto: localhost-key.pem"
  fi

  # ── Permissões ─────────────────────────────────────────────────────────────
  log_step "Ajustando permissões dos certificados"
  chmod 644 "$CERTS_DIR/localhost.pem"
  chmod 600 "$CERTS_DIR/localhost-key.pem"
  log_debug "localhost.pem     → 644 (leitura pública)"
  log_debug "localhost-key.pem → 600 (chave privada, só dono)"

  log_ok "Certificados prontos:"
  log_ok "  📄 $CERTS_DIR/localhost.pem"
  log_ok "  🔑 $CERTS_DIR/localhost-key.pem"
}

# ──────────────────────────────────────────────
# AGUARDA CONTAINER HEALTHY
# ──────────────────────────────────────────────
wait_for_healthy() {
  local service_name="$1"
  local compose_file="$2"
  local elapsed=0

  log_debug "wait_for_healthy: '$service_name' em $compose_file (timeout: ${HEALTH_TIMEOUT}s)"
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
      echo -e "\r  ${YELLOW}⚠${NC}  '$service_name' caiu (status: $status). Tentando reiniciar...    "
      _log_raw "[WARN]  '$service_name' caiu — status: '$status'. Reiniciando..."
      docker compose -f "$compose_file" up -d "$service_name" &>/dev/null
    fi

    if (( elapsed >= HEALTH_TIMEOUT )); then
      echo ""
      _log_raw "[ERR ]  Timeout em '$service_name' após ${elapsed}s | health='$health' status='$status'"
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

  log_debug "wait_for_running: '$service_name' em $compose_file (timeout: ${HEALTH_TIMEOUT}s)"
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
        echo -e "\r  ${YELLOW}⚠${NC}  '$service_name' caiu. Tentando reiniciar ($((retries+1))/$MAX_RETRIES)..."
        _log_raw "[WARN]  '$service_name' caiu — tentativa $((retries+1))/$MAX_RETRIES | status: '$status'"
        docker compose -f "$compose_file" logs --tail=10 "$service_name" >> "$LOG_FILE" 2>&1 || true
        docker compose -f "$compose_file" up -d "$service_name" &>/dev/null
        (( retries++ ))
        sleep "$RETRY_SLEEP"
        continue
      else
        echo ""
        log_warn "Últimos logs de '$service_name':"
        docker compose -f "$compose_file" logs --tail=30 "$service_name" 2>&1 | tee -a "$LOG_FILE" || true
        die "'$service_name' falhou após $MAX_RETRIES tentativas de reinício."
      fi
    fi

    if (( elapsed >= HEALTH_TIMEOUT )); then
      echo ""
      _log_raw "[ERR ]  Timeout em '$service_name' após ${elapsed}s | status='$status'"
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
# AGUARDA RAILS ESTAR REALMENTE PRONTO
# ──────────────────────────────────────────────
wait_for_rails_ready() {
  local compose_file="$1"
  local elapsed=0

  log_debug "wait_for_rails_ready: probe via ActiveRecord SELECT 1 (timeout: ${RAILS_READY_TIMEOUT}s)"
  echo -ne "  ⏳ Aguardando Rails carregar ambiente e conectar ao DB"

  while true; do
    log_debug "Tentando probe Rails (${elapsed}s / ${RAILS_READY_TIMEOUT}s)..."

    if docker compose -f "$compose_file" exec -T web \
        rails runner "ActiveRecord::Base.connection.execute('SELECT 1')" \
        >> "$LOG_FILE" 2>&1; then
      echo -e "\r  ${GREEN}✔${NC}  Rails pronto — DB conectado e ambiente carregado! (${elapsed}s)   "
      _log_raw "[ OK ]  Rails pronto após ${elapsed}s"
      return 0
    fi

    log_debug "Probe falhou (${elapsed}s) — Rails ainda inicializando"

    if (( elapsed >= RAILS_READY_TIMEOUT )); then
      echo ""
      _log_raw "[ERR ]  Rails não ficou pronto em ${RAILS_READY_TIMEOUT}s"
      log_warn "Últimos logs do container 'web':"
      docker compose -f "$compose_file" logs --tail=30 web 2>&1 | tee -a "$LOG_FILE" || true
      die "Timeout: Rails não ficou pronto em ${RAILS_READY_TIMEOUT}s. Veja os logs acima."
    fi

    echo -n "."
    sleep "$RAILS_READY_INTERVAL"
    (( elapsed += RAILS_READY_INTERVAL ))
  done
}

# ──────────────────────────────────────────────
# EXECUTA COMANDO DENTRO DE CONTAINER (com retry)
# ──────────────────────────────────────────────
exec_in_container() {
  local compose_file="$1"
  local service="$2"
  shift 2
  local cmd=("$@")
  local attempt=1

  log_debug "exec_in_container: '$service' → ${cmd[*]}"

  while (( attempt <= MAX_RETRIES )); do
    log_step "${cmd[*]} (tentativa $attempt/$MAX_RETRIES)"

    if docker compose -f "$compose_file" exec -T "$service" "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
      log_ok "${cmd[*]} — concluído"
      return 0
    fi

    local exit_code=$?
    log_warn "Comando '${cmd[*]}' falhou com código $exit_code."

    if (( attempt < MAX_RETRIES )); then
      log_info "Aguardando ${RETRY_SLEEP}s antes da próxima tentativa..."
      sleep "$RETRY_SLEEP"
    fi

    (( attempt++ ))
  done

  die "Comando '${cmd[*]}' falhou após $MAX_RETRIES tentativas. Verifique os logs em: $LOG_FILE"
}

# ──────────────────────────────────────────────
# VERIFICA OBSERVABILIDADE
# ──────────────────────────────────────────────
verify_observability() {
  log_section "Verificando Stack de Observabilidade"
  
  # Carregar variáveis do .env para obter senha do Grafana
  if [ -f "$SCRIPT_DIR/infra-doc-validator/.env" ]; then
    set -a
    source "$SCRIPT_DIR/infra-doc-validator/.env"
    set +a
  fi
  
  # Verificar se Loki está respondendo
  if curl -s -f http://localhost:3100/ready >/dev/null 2>&1; then
    log_ok "Loki API está respondendo"
    
    # Aguardar alguns logs
    sleep 5
    
    # Verificar se logs do relay estão chegando
    local log_count
    log_count=$(curl -s -G 'http://localhost:3100/loki/api/v1/query' \
      --data-urlencode 'query={container=~".*relay.*"}' \
      | jq '.data.result | length' 2>/dev/null || echo "0")
    
    if [ "$log_count" -gt 0 ]; then
      log_ok "✅ Logs do Relay estão sendo coletados ($log_count entradas encontradas)"
    else
      log_warn "⚠️ Nenhum log do Relay encontrado ainda. O Promtail pode levar alguns segundos para coletar."
    fi
  else
    log_warn "⚠️ Loki não está disponível. Verifique se os serviços de observabilidade subiram corretamente."
  fi
  
  # Verificar se Grafana está acessível
  if curl -s -f http://localhost:3030/api/health >/dev/null 2>&1; then
    log_ok "✅ Grafana está disponível em http://localhost:3030"
    log_info "   Login: admin / ${GRAFANA_PASSWORD:-DocValidator2024!}"
    log_info "   Dashboard: Go Relay - Outbox Monitor"
  else
    log_warn "⚠️ Grafana não está respondendo em http://localhost:3030"
    log_info "   Verifique: docker compose -f infra-doc-validator/docker-compose.yml logs grafana"
  fi
}

# ──────────────────────────────────────────────
# RESUMO FINAL
# ──────────────────────────────────────────────
print_summary() {
  local end_time duration mins secs
  end_time=$(date +%s)
  duration=$(( end_time - START_TIME ))
  mins=$(( duration / 60 ))
  secs=$(( duration % 60 ))

  echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║   🎉  Doc-Validator está no ar!                                   ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}📍 Aplicações:${NC}"
  echo -e "     Nginx (HTTPS):      https://localhost"
  echo -e "     Rails (direto):     http://localhost:3000"
  echo -e "     MinIO Console:      http://localhost:9001"
  echo -e "     RabbitMQ Mgmt:      http://localhost:15672"
  echo -e "     Postgres:           localhost:5432"
  echo ""
  echo -e "  ${BOLD}📊 Observabilidade:${NC}"
  if curl -s -f http://localhost:3030/api/health >/dev/null 2>&1; then
    echo -e "     Grafana:            http://localhost:3030"
    echo -e "     Login:              admin / ${GRAFANA_PASSWORD:-DocValidator2024!}"
    echo -e "     Dashboard:          Go Relay - Outbox Monitor"
  else
    echo -e "     Grafana:            ${YELLOW}Não disponível (verifique logs)${NC}"
  fi
  echo -e "     Loki API:           http://localhost:3100"
  echo ""
  echo -e "  ${BOLD}🔧 Comandos úteis:${NC}"
  echo -e "     Ver logs do Relay:  docker compose -f go-relay/docker-compose-go-infra.yml logs -f relay"
  echo -e "     Ver logs do Loki:   docker compose -f infra-doc-validator/docker-compose.yml logs -f loki"
  echo -e "     Dashboard direto:   open http://localhost:3030"
  echo ""
  echo -e "  ${GRAY}⏱  Tempo total: ${mins}m ${secs}s${NC}"
  echo -e "  ${GRAY}📋 Log completo: $LOG_FILE${NC}"
  echo ""
  _log_raw "SETUP CONCLUÍDO em ${mins}m ${secs}s"
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
  # Inicializa o log file
  mkdir -p "$(dirname "$LOG_FILE")"
  {
    echo "==============================================================="
    echo " Doc-Validator Setup — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "==============================================================="
  } > "$LOG_FILE"

  echo -e "${BOLD}${CYAN}"
  echo "  ██████╗  ██████╗  ██████╗    ██╗   ██╗ █████╗ ██╗     "
  echo "  ██╔══██╗██╔═══██╗██╔════╝    ██║   ██║██╔══██╗██║     "
  echo "  ██║  ██║██║   ██║██║         ██║   ██║███████║██║     "
  echo "  ██║  ██║██║   ██║██║         ╚██╗ ██╔╝██╔══██║██║     "
  echo "  ██████╔╝╚██████╔╝╚██████╗     ╚████╔╝ ██║  ██║███████╗"
  echo "  ╚═════╝  ╚═════╝  ╚═════╝      ╚═══╝  ╚═╝  ╚═╝╚══════╝"
  echo -e "${NC}"
  echo -e "  ${BOLD}Doc-Validator — Full Stack Bootstrap${NC}"
  echo -e "  Infra Base → Rails → Go Relay → Observabilidade"
  echo -e "  ${GRAY}Log: $LOG_FILE${NC}\n"

  check_dependencies

  # ────────────────────────────────────────────
  # 0. GARANTIR .ENV EM TODOS OS PROJETOS
  # ────────────────────────────────────────────
  log_section "0/4 · Verificando arquivos .env"
  ensure_env "$SCRIPT_DIR/infra-doc-validator" "infra-doc-validator"
  ensure_env "$SCRIPT_DIR/rails-doc-validator" "rails-doc-validator"
  ensure_env "$SCRIPT_DIR/go-relay"            "go-relay"
  log_ok "Todos os .env estão presentes"

  # ────────────────────────────────────────────
  # 0.5. CERTIFICADOS HTTPS
  # ────────────────────────────────────────────
  setup_certificates

  # ────────────────────────────────────────────
  # 0.6. GARANTIR REDE COMPARTILHADA
  # ────────────────────────────────────────────
  log_section "0.6 · Garantindo rede compartilhada"
  ensure_network

  # ────────────────────────────────────────────
  # 1. INFRAESTRUTURA BASE (com Observabilidade)
  # ────────────────────────────────────────────
  log_section "1/4 · Infraestrutura Base (Postgres + RabbitMQ + MinIO + Observabilidade)"

  INFRA_FILE="$SCRIPT_DIR/infra-doc-validator/docker-compose.yml"
  log_debug "Compose file: $INFRA_FILE"

  log_step "Subindo containers de infra"
  docker compose -f "$INFRA_FILE" up -d 2>&1 | tee -a "$LOG_FILE"

  log_step "Aguardando Postgres"
  wait_for_healthy "postgres" "$INFRA_FILE"

  log_step "Aguardando RabbitMQ"
  wait_for_healthy "rabbitmq" "$INFRA_FILE"

  log_step "Aguardando MinIO"
  wait_for_healthy "minio" "$INFRA_FILE"

  # Aguardar serviços de observabilidade
  log_step "Aguardando Loki (Observabilidade)"
  wait_for_healthy "loki" "$INFRA_FILE" || log_warn "Loki não está healthy, continuando..."
  
  log_step "Aguardando Grafana"
  wait_for_healthy "grafana" "$INFRA_FILE" || log_warn "Grafana não está healthy, continuando..."
  
  log_step "Verificando Promtail"
  wait_for_running "promtail" "$INFRA_FILE" || log_warn "Promtail não está rodando, continuando..."

  log_step "Inicializando bucket no MinIO (minio-init)"
  docker compose -f "$INFRA_FILE" up minio-init 2>&1 | tee -a "$LOG_FILE" | tail -5

  local init_exit
  init_exit=$(docker compose -f "$INFRA_FILE" ps --format "{{.ExitCode}}" minio-init 2>/dev/null || echo "0")
  log_debug "minio-init exit code: $init_exit"

  if [[ "$init_exit" != "0" && "$init_exit" != "" ]]; then
    log_warn "minio-init retornou código $init_exit."
    log_warn "Diagnóstico: docker compose -f $INFRA_FILE logs minio-init"
    docker compose -f "$INFRA_FILE" logs minio-init >> "$LOG_FILE" 2>&1 || true
  else
    log_ok "Bucket MinIO inicializado"
  fi

  log_ok "Infraestrutura Base pronta!"

  # ────────────────────────────────────────────
  # 2. RAILS
  # ────────────────────────────────────────────
  log_section "2/4 · Rails (API + Worker + Nginx)"

  RAILS_FILE="$SCRIPT_DIR/rails-doc-validator/docker-compose-rails-infra.yml"
  log_debug "Compose file: $RAILS_FILE"

  log_step "Subindo container 'web'"
  docker compose -f "$RAILS_FILE" up -d web 2>&1 | tee -a "$LOG_FILE"

  log_step "Aguardando inicialização do ambiente Rails (DB + Migrations)"
  wait_for_rails_ready "$RAILS_FILE"

  log_step "Subindo Worker e Nginx"
  docker compose -f "$RAILS_FILE" up -d worker nginx 2>&1 | tee -a "$LOG_FILE"

  log_step "Validando estabilidade do Worker"
  wait_for_running "worker" "$RAILS_FILE"

  log_step "Aguardando Nginx (Proxy Reverso)"
  wait_for_healthy "nginx" "$RAILS_FILE"

  log_step "Executando db:seed (População de dados)"
  if ! docker compose -f "$RAILS_FILE" exec -T web rails db:seed 2>&1 | tee -a "$LOG_FILE"; then
    log_warn "db:seed reportou algo inesperado. Verifique os logs se for a primeira subida."
  else
    log_ok "db:seed concluído com sucesso"
  fi

  log_ok "Módulo Rails (Full Stack) operacional!"

  # ────────────────────────────────────────────
  # 3. GO RELAY
  # ────────────────────────────────────────────
  log_section "3/4 · Go Relay"

  GO_FILE="$SCRIPT_DIR/go-relay/docker-compose-go-infra.yml"
  log_debug "Compose file: $GO_FILE"

  log_step "Subindo containers Go"
  docker compose -f "$GO_FILE" up -d 2>&1 | tee -a "$LOG_FILE"

  log_step "Aguardando Relay"
  wait_for_running "relay" "$GO_FILE"

  log_ok "Go Relay pronto!"

  # ────────────────────────────────────────────
  # 4. VERIFICAÇÃO DE OBSERVABILIDADE
  # ────────────────────────────────────────────
  log_section "4/4 · Verificando Observabilidade"
  
  # Aguarda alguns segundos para os primeiros logs
  sleep 5
  
  verify_observability

  # ────────────────────────────────────────────
  # FIM
  # ────────────────────────────────────────────
  print_summary
}

main "$@"
