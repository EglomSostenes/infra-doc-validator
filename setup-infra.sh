#!/bin/bash
# ==============================================================================
# setup-infra.sh — Doc-Validator · Infraestrutura Base
# Sobe: Postgres · RabbitMQ · MinIO · Loki · Grafana · Promtail
#
# Pode ser chamado diretamente ou pelo setup.sh principal.
# Exporta: INFRA_READY=1 quando tudo estiver saudável.
# ==============================================================================
set -euo pipefail

# ──────────────────────────────────────────────
# GUARD — evita double-source acidental
# ──────────────────────────────────────────────
[[ "${INFRA_BOOTSTRAP_LOADED:-}" == "1" ]] && return 0 || true

# ──────────────────────────────────────────────
# LOCALIZAÇÃO
# ──────────────────────────────────────────────
INFRA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_COMPOSE_FILE="$INFRA_SCRIPT_DIR/infra-doc-validator/docker-compose.yml"
INFRA_DIR="$INFRA_SCRIPT_DIR/infra-doc-validator"

# ──────────────────────────────────────────────
# IMPORTA LIB COMPARTILHADA (cores, logs, helpers)
# ──────────────────────────────────────────────
# shellcheck source=./lib/common.sh
source "$INFRA_SCRIPT_DIR/lib/common.sh"

# ──────────────────────────────────────────────
# MAIN DA INFRA
# ──────────────────────────────────────────────
setup_infra() {
  local standalone=${1:-0}   # 1 = chamado diretamente, 0 = chamado pelo setup.sh

  if [[ "$standalone" == "1" ]]; then
    _init_log
    log_banner "Infraestrutura Base" "Postgres · RabbitMQ · MinIO · Loki · Grafana · Promtail"
    check_dependencies
    ensure_env "$INFRA_DIR" "infra-doc-validator"
    ensure_network
  fi

  # ── .env precisa existir antes dos healthchecks referenciarem variáveis ────
  ensure_env "$INFRA_DIR" "infra-doc-validator"

  log_section "Infraestrutura Base"

  # ── Sobe tudo de uma vez; healthchecks garantem a ordem real ───────────────
  log_step "Subindo containers de infra"
  docker compose -f "$INFRA_COMPOSE_FILE" up -d 2>&1 | tee -a "$LOG_FILE"

  # ── Serviços críticos — bloqueia até ficarem healthy ───────────────────────
  log_step "Aguardando Postgres"
  wait_for_healthy "postgres" "$INFRA_COMPOSE_FILE"

  log_step "Aguardando RabbitMQ"
  wait_for_healthy "rabbitmq" "$INFRA_COMPOSE_FILE"

  log_step "Aguardando MinIO"
  wait_for_healthy "minio" "$INFRA_COMPOSE_FILE"

  # ── Inicializa bucket (job de curta duração) ───────────────────────────────
  log_step "Inicializando bucket no MinIO (minio-init)"
  docker compose -f "$INFRA_COMPOSE_FILE" up minio-init 2>&1 | tee -a "$LOG_FILE" | tail -5

  local init_exit
  init_exit=$(docker compose -f "$INFRA_COMPOSE_FILE" ps --format "{{.ExitCode}}" minio-init 2>/dev/null || echo "0")

  if [[ "$init_exit" != "0" && "$init_exit" != "" ]]; then
    log_warn "minio-init retornou código $init_exit — verifique:"
    log_warn "  docker compose -f $INFRA_COMPOSE_FILE logs minio-init"
    docker compose -f "$INFRA_COMPOSE_FILE" logs minio-init >> "$LOG_FILE" 2>&1 || true
  else
    log_ok "Bucket MinIO inicializado"
  fi

  # ── Observabilidade — não-bloqueante; falha não aborta o setup ─────────────
  log_step "Aguardando Loki"
  wait_for_healthy "loki" "$INFRA_COMPOSE_FILE" \
    || log_warn "Loki não ficou healthy — continuando mesmo assim"

  log_step "Aguardando Grafana"
  wait_for_healthy "grafana" "$INFRA_COMPOSE_FILE" \
    || log_warn "Grafana não ficou healthy — continuando mesmo assim"

  log_step "Verificando Promtail"
  wait_for_running "promtail" "$INFRA_COMPOSE_FILE" \
    || log_warn "Promtail não subiu — continuando mesmo assim"

  log_ok "Infraestrutura Base pronta!"
  export INFRA_READY=1
}

# ──────────────────────────────────────────────
# EXECUÇÃO DIRETA
# ──────────────────────────────────────────────
# Permite: bash setup-infra.sh
# Quando sourced pelo setup.sh, apenas define a função.
# ──────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  INFRA_BOOTSTRAP_LOADED=1
  setup_infra 1
  echo ""
  log_ok "━━━  Infra no ar  ━━━"
  echo -e "  Postgres:       localhost:5432"
  echo -e "  RabbitMQ Mgmt:  http://localhost:15672"
  echo -e "  MinIO Console:  http://localhost:9001"
  echo -e "  Grafana:        http://localhost:3030"
  echo -e "  Loki API:       http://localhost:3100"
fi

INFRA_BOOTSTRAP_LOADED=1
