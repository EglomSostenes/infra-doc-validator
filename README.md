# 🛠️ Como Inicializar

## Observação importante
* Os três projetos (infra, rails e go) precisam estar no mesmo diretório

O script executa o fluxo completo:

1. **Infra Base:** Sobe Postgres, RabbitMQ e MinIO (aguardando Healthchecks).
2. **Rails:** Inicializa o ambiente, aguarda estabilidade e roda `db:migrate` + `db:seed`.
3. **Go Relay:** Sobe o serviço de mensageria conectado à infraestrutura.
4. **Auto-Recovery:** Caso algum container crítico caia durante o boot, o script tenta reanimá-lo automaticamente.

### Passo a Passo

1. **Configuração de Ambiente:** Certifique-se de que os arquivos `.env` existam nas pastas `infra-doc-validator`, `rails-doc-validator` e `go-relay`.

2. **Permissão de Execução:** No diretório raiz do projeto, execute:

```bash
chmod +x setup.sh
```

3. **Execução: Para este passo é preciso mover o arquivo setup.sh para fora do projeto**

```bash
./setup.sh
```

## Observação importante


---

> ⚠️ **Se não funcionar, tente passo a passo:**

---

# Setup do Ambiente

Siga a ordem abaixo para subir todo o ambiente corretamente.

## 1. Infra (obrigatório primeiro)

```bash
cd infra-doc-validator
docker compose up -d
```

Aguarde a inicialização do serviço responsável pelo storage:

```bash
docker compose wait minio-init
```

---

## 2. Rails

```bash
cd ../rails-doc-validator
docker compose -f docker-compose-rails-infra.yml up -d
```

### Rodar migrations

```bash
docker compose -f docker-compose-rails-infra.yml exec web rails db:migrate
```

### Rodar seed

```bash
docker compose -f docker-compose-rails-infra.yml exec web rails db:seed
```

---

## 3. Go

```bash
cd ../go-relay
docker compose -f docker-compose-go-infra.yml up -d
```

---

## Observações

* A ordem é obrigatória: **Infra → Rails → Go**
* O passo do `minio-init` precisa finalizar antes de seguir
* Todos os serviços sobem em background (`-d`)
* Execute migrations e seed após o Rails estar rodando
* Para o setup ./setup.sh os três projetos precisam estar no mesmo diretório
* No app Rails é preciso verificar se existe a pasta docker/certs e nela contém os certificados, senão conter, será necessário seguir as instruções do README do app Rails para gerá-los