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
