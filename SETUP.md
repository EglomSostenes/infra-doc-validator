# Doc-Validator — Setup

## Estrutura de diretórios

Todos os repositórios e os scripts de setup precisam estar numa mesma raiz. Os diretórios **precisam ter exatamente estes nomes** — os scripts dependem deles:

```
doc-validator/                         ← pasta raiz (nome livre)
├── setup.sh                           # orquestrador principal
├── setup-infra.sh
├── setup-rails.sh
├── setup-go.sh
├── lib/
│   └── common.sh                      # biblioteca compartilhada (não executar diretamente)
│
├── infra-doc-validator/               ← repo: infra-doc-validator (mesmo nome)
│   ├── docker-compose.yml
│   ├── .env                           # criado automaticamente a partir de .env.example
│   └── ...
│
├── rails-doc-validator/               ← repo: doc_validator  →  renomear para rails-doc-validator
│   ├── docker-compose-rails-infra.yml
│   ├── .env
│   └── ...
│
└── go-relay/                          ← repo: doc-validator-relay  →  renomear para go-relay
    ├── docker-compose-go-infra.yml
    ├── .env
    └── ...
```

---

## Pré-requisitos

- Docker com o Compose plugin (`docker compose version`)
- `curl`
- O daemon Docker em execução

---

## Passo a passo

### 1. Clone os repositórios dentro de uma mesma pasta raiz

Os repos têm nomes diferentes no GitHub. O `git clone` já faz o renomeio:

```bash
mkdir doc-validator && cd doc-validator

git clone <url-infra-doc-validator>   infra-doc-validator   # mesmo nome
git clone <url-doc_validator>         rails-doc-validator   # era: doc_validator
git clone <url-doc-validator-relay>   go-relay              # era: doc-validator-relay
```

### 2. Extraia os scripts de setup para a raiz

Cada script vive dentro do seu respectivo repositório. Copie-os para a raiz:

```bash
# setup principal
cp infra-doc-validator/setup.sh .

# scripts de cada camada
cp infra-doc-validator/setup-infra.sh .
cp rails-doc-validator/setup-rails.sh .
cp go-relay/setup-go.sh              .

# biblioteca compartilhada
mkdir -p lib
cp infra-doc-validator/lib/common.sh lib/
```

A raiz deve ficar assim:

```
doc-validator/
├── setup.sh
├── setup-infra.sh
├── setup-rails.sh
├── setup-go.sh
└── lib/
    └── common.sh
```

### 3. Habilite as permissões de execução

Execute uma única vez na raiz do projeto:

```bash
chmod +x setup.sh setup-infra.sh setup-rails.sh setup-go.sh
```

> `lib/common.sh` **não** precisa de `chmod` — ele é apenas importado pelos outros scripts via `source`, nunca executado diretamente.

### 4. Garanta os arquivos `.env`

Cada repositório precisa de um `.env` na sua raiz. O setup cria automaticamente a partir do `.env.example` se ele não existir, mas é recomendável revisá-los antes:

```bash
cp infra-doc-validator/.env.example  infra-doc-validator/.env
cp rails-doc-validator/.env.example  rails-doc-validator/.env
cp go-relay/.env.example             go-relay/.env
```

Edite cada `.env` conforme o ambiente.

### 5. Execute o setup completo

Na raiz `doc-validator/`:

```bash
./setup.sh
```

O orquestrador sobe tudo na ordem correta:

```
Infra (Postgres · RabbitMQ · MinIO · Loki · Grafana)
  └─▸ Rails (web · worker · nginx · db:seed)
        └─▸ Go Relay
              └─▸ Verificação de Observabilidade
```

---

## Executar partes individualmente

Caso precise resubir apenas uma camada (assumindo que as dependências já estão no ar):

```bash
./setup-infra.sh    # Postgres, RabbitMQ, MinIO, Loki, Grafana, Promtail
./setup-rails.sh    # web, worker, nginx, db:seed
./setup-go.sh       # relay
```

---

## Serviços disponíveis após o setup

| Serviço | Endereço |
|---|---|
| Aplicação (HTTPS) | https://localhost |
| Rails (direto) | http://localhost:3000 |
| MinIO Console | http://localhost:9001 |
| RabbitMQ Management | http://localhost:15672 |
| Postgres | localhost:5432 |
| Grafana | http://localhost:3030 |
| Loki API | http://localhost:3100 |

---

## Logs e diagnóstico

```bash
# Log completo do setup
cat setup.log

# Status de todos os containers
docker ps -a

# Logs por camada
docker compose -f infra-doc-validator/docker-compose.yml logs --tail=50
docker compose -f rails-doc-validator/docker-compose-rails-infra.yml logs --tail=50 web
docker compose -f go-relay/docker-compose-go-infra.yml logs --tail=50
```
