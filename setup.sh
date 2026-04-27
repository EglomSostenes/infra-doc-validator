#!/bin/bash
# ==============================================================================
# setup.sh — Doc-Validator · Orquestrador Principal
# Ordem de subida: Infra → Rails → Go Relay → Observabilidade
#
# VERSÃO: 3.0.0 (setup desmembrado)
# ==============================================================================
set -euo pipefail

# ──────────────────────────────────────────────
# LOCALIZAÇÃO — base de todos os paths relativos
# ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# Log único compartilhado por todos os sub-scripts
export LOG_FILE="$SCRIPT_DIR/setup.log"
export START_TIME=$(date +%s)

# ──────────────────────────────────────────────
# IMPORTA LIB COMPARTILHADA
# ──────────────────────────────────────────────
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# ──────────────────────────────────────────────
# IMPORTA SUB-SCRIPTS (define funções, não executa)
# ──────────────────────────────────────────────
# shellcheck source=./setup-infra.sh
source "$SCRIPT_DIR/setup-infra.sh"

# shellcheck source=./setup-rails.sh
source "$SCRIPT_DIR/setup-rails.sh"

# shellcheck source=./setup-go.sh
source "$SCRIPT_DIR/setup-go.sh"

# ──────────────────────────────────────────────
# VERIFICAÇÃO DE OBSERVABILIDADE
# ──────────────────────────────────────────────
verify_observability() {
  log_section "Verificando Stack de Observabilidade"

  # Carrega variáveis do .env da infra para pegar senha do Grafana
  if [[ -f "$SCRIPT_DIR/infra-doc-validator/.env" ]]; then
    set -a; source "$SCRIPT_DIR/infra-doc-validator/.env"; set +a
  fi

  # Loki
  if curl -s -f http://localhost:3100/ready >/dev/null 2>&1; then
    log_ok "Loki API está respondendo"

    sleep 5   # aguarda primeiros logs chegarem

    local log_count
    log_count=$(curl -s -G 'http://localhost:3100/loki/api/v1/query' \
      --data-urlencode 'query={container=~".*relay.*"}' \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['data']['result']))" 2>/dev/null || echo "0")

    if [[ "$log_count" -gt 0 ]]; then
      log_ok "Logs do Relay sendo coletados ($log_count entradas)"
    else
      log_warn "Nenhum log do Relay ainda — Promtail pode levar alguns segundos."
    fi
  else
    log_warn "Loki não está disponível. Verifique: docker compose -f infra-doc-validator/docker-compose.yml logs loki"
  fi

  # Grafana
  if curl -s -f http://localhost:3030/api/health >/dev/null 2>&1; then
    log_ok "Grafana disponível em http://localhost:3030"
    log_info "   Login: admin / ${GRAFANA_PASSWORD:-DocValidator2024!}"
  else
    log_warn "Grafana não responde em http://localhost:3030"
    log_info "   Diagnóstico: docker compose -f infra-doc-validator/docker-compose.yml logs grafana"
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

  # Carrega .env da infra para ter GRAFANA_PASSWORD no escopo
  if [[ -f "$SCRIPT_DIR/infra-doc-validator/.env" ]]; then
    set -a; source "$SCRIPT_DIR/infra-doc-validator/.env"; set +a
  fi

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
  echo -e "     Relay (logs):   docker compose -f go-relay/docker-compose-go-infra.yml logs -f relay"
  echo -e "     Loki (logs):    docker compose -f infra-doc-validator/docker-compose.yml logs -f loki"
  echo -e "     Rails (logs):   docker compose -f rails-doc-validator/docker-compose-rails-infra.yml logs -f web"
  echo -e "     Grafana:        open http://localhost:3030"
  echo ""
  echo -e "  ${BOLD}⚙️  Reexecutar partes individualmente:${NC}"
  echo -e "     bash setup-infra.sh   # somente infra"
  echo -e "     bash setup-rails.sh   # somente Rails"
  echo -e "     bash setup-go.sh      # somente Go Relay"
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
  # Inicializa log (cabeçalho único — sub-scripts apenas fazem append)
  mkdir -p "$(dirname "$LOG_FILE")"
  {
    echo "==============================================================="
    echo " Doc-Validator Setup — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "==============================================================="
  } > "$LOG_FILE"

  # Banner
  echo -e "${BOLD}${CYAN}"
  echo "  ██████╗  ██████╗  ██████╗    ██╗   ██╗ █████╗ ██╗     "
  echo "  ██╔══██╗██╔═══██╗██╔════╝    ██║   ██║██╔══██╗██║     "
  echo "  ██║  ██║██║   ██║██║         ██║   ██║███████║██║     "
  echo "  ██║  ██║██║   ██║██║         ╚██╗ ██╔╝██╔══██║██║     "
  echo "  ██████╔╝╚██████╔╝╚██████╗     ╚████╔╝ ██║  ██║███████╗"
  echo "  ╚═════╝  ╚═════╝  ╚═════╝      ╚═══╝  ╚═╝  ╚═╝╚══════╝"
  echo -e "${NC}"
  echo -e "  ${BOLD}Doc-Validator — Full Stack Bootstrap v3.0${NC}"
  echo -e "  Infra Base → Rails → Go Relay → Observabilidade"
  echo -e "  ${GRAY}Log: $LOG_FILE${NC}\n"

  # ── Pré-voo ────────────────────────────────────────────────────────────────
  check_dependencies

  log_section "0/4 · Verificando arquivos .env"
  ensure_env "$SCRIPT_DIR/infra-doc-validator" "infra-doc-validator"
  ensure_env "$SCRIPT_DIR/rails-doc-validator" "rails-doc-validator"
  ensure_env "$SCRIPT_DIR/go-relay"            "go-relay"
  log_ok "Todos os .env estão presentes"

  log_section "0.5/4 · Rede compartilhada"
  ensure_network

  # ── 1. Infra ───────────────────────────────────────────────────────────────
  setup_infra 0

  # ── 2. Rails ──────────────────────────────────────────────────────────────
  setup_rails 0

  # ── 3. Go Relay ───────────────────────────────────────────────────────────
  setup_go 0

  # ── 4. Observabilidade ────────────────────────────────────────────────────
  verify_observability

  # ── Resumo ─────────────────────────────────────────────────────────────────
  print_summary
}

main "$@"
