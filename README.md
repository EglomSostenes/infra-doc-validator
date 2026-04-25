# 🛠️ infra-doc-validator

Camada de infraestrutura compartilhada que sustenta o ecossistema Doc Validator.
Provisiona todos os serviços base — banco de dados, mensageria, storage e observabilidade — consumidos pelos apps Rails e Go.

---

## 📦 Componentes

### Infraestrutura Base
| Serviço | Imagem | Porta | Descrição |
|---|---|---|---|
| **Postgres** | `postgres:16-alpine` | `5432` | Banco de dados relacional |
| **RabbitMQ** | `rabbitmq:3-management` | `5672` / `15672` | Mensageria + painel de gestão |
| **MinIO** | `minio/minio` | `9000` / `9001` | Object storage compatível com S3 |

### Observabilidade
| Serviço | Imagem | Porta | Descrição |
|---|---|---|---|
| **Loki** | `grafana/loki:3.0.0` | `3100` | Agregação e indexação de logs |
| **Promtail** | `grafana/promtail:3.0.0` | — | Agente de coleta de logs dos containers Docker |
| **Grafana** | `grafana/grafana:10.4.0` | `3030` | Dashboards e visualização de métricas |

---

## 🗂️ Estrutura de Repositórios

Os três repositórios precisam estar **na mesma pasta raiz** e com os nomes exatos abaixo:

```
pasta-raiz/
├── infra-doc-validator/   ← este repositório
├── rails-doc-validator/   ← renomeado de doc_validator
├── go-relay/              ← renomeado de doc-validator-relay
└── setup.sh               ← copiado de infra-doc-validator/
```

### Nomes esperados
| Repositório original | Nome esperado |
|---|---|
| `doc_validator` | `rails-doc-validator` |
| `doc-validator-relay` | `go-relay` |

---

## 🚀 Setup Automatizado (recomendado)

O `setup.sh` executa todo o fluxo na ordem correta, aguardando healthchecks e tentando auto-recovery em caso de falha.

### O que o script faz

1. **Certificados HTTPS** — instala `mkcert` e gera os certificados para o Rails se necessário
2. **Rede compartilhada** — cria a rede Docker `local-infra-net` se não existir
3. **Infra Base** — sobe Postgres, RabbitMQ, MinIO e a stack de observabilidade (Loki, Promtail, Grafana)
4. **Rails** — inicializa o ambiente, aguarda estabilidade, roda `db:migrate` e `db:seed`
5. **Go Relay** — sobe o serviço conectado à infra
6. **Verificação** — valida se Loki e Grafana estão respondendo

### Passo a Passo

**1. Clone os três repositórios na mesma pasta raiz**

```bash
git clone <url-infra>        infra-doc-validator
git clone <url-rails>        rails-doc-validator
git clone <url-go-relay>     go-relay
```

**2. Copie o `setup.sh` para a pasta raiz**

```bash
cp infra-doc-validator/setup.sh ./setup.sh
```

**3. Dê permissão de execução**

```bash
chmod +x setup.sh
```

> Os arquivos `.env` são criados automaticamente a partir do `.env.example` de cada projeto caso não existam. Revise as variáveis após a primeira execução se necessário.

**4. Execute**

```bash
./setup.sh
```

---

## 🔗 Endereços após o setup

| Serviço | URL |
|---|---|
| Rails (HTTPS) | https://localhost |
| Rails (direto) | http://localhost:3000 |
| MinIO Console | http://localhost:9001 |
| RabbitMQ Management | http://localhost:15672 |
| Grafana | http://localhost:3030 |
| Loki API | http://localhost:3100 |
| Postgres | localhost:5432 |

### Grafana
- **Login:** `admin` / senha definida em `GRAFANA_PASSWORD` no `.env` (padrão: `DocValidator2024!`)
- **Dashboard:** Go Relay — Outbox Monitor

---

## 📊 Observabilidade

O Promtail coleta automaticamente os logs de todos os containers Docker e os envia ao Loki.
O Grafana já vem pré-configurado com o datasource Loki e o dashboard do Go Relay.

### O que é monitorado no dashboard
- Eventos publicados, retries agendados e falhas definitivas (por minuto)
- Taxa de erro percentual
- Latência P50 / P95 / P99 do publisher RabbitMQ
- Erros de conexão com o broker (timeout, NACK, conexão perdida)
- Eventos stale reclaimed pelo poller
- Logs de nível `warn` e `error` em tempo real
- Rastreamento por `event_id`

---

## ⚠️ Setup Manual (caso o script falhe)

Siga rigorosamente a ordem: **Infra → Rails → Go**

### 1. Infra

```bash
docker network create local-infra-net

cd infra-doc-validator
docker compose up -d
docker compose wait minio-init
```

Aguarde todos os serviços ficarem healthy antes de continuar:

```bash
docker compose ps
```

### 2. Rails

```bash
cd ../rails-doc-validator
docker compose -f docker-compose-rails-infra.yml up -d
```

Aguarde o container `web` estar rodando, depois execute:

```bash
docker compose -f docker-compose-rails-infra.yml exec web rails db:migrate
docker compose -f docker-compose-rails-infra.yml exec web rails db:seed
```

### 3. Go Relay

```bash
cd ../go-relay
docker compose -f docker-compose-go-infra.yml up -d
```

---

## 📋 Observações

- A ordem de subida é obrigatória: **Infra → Rails → Go**
- O `minio-init` precisa finalizar com sucesso antes de subir o Rails
- Todos os serviços sobem em background (`-d`)
- O Loki pode levar até 30s para ficar healthy após subir — isso é normal
- O Grafana sobe na porta `3030` para não conflitar com o Rails que usa a `3000`
- Para certificados HTTPS do Rails, verifique se `rails-doc-validator/docker/certs/` contém `localhost.pem` e `localhost-key.pem`. Se não existirem, o `setup.sh` os gera automaticamente via `mkcert`
