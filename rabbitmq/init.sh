#!/bin/sh
set -e

echo "===> Subindo RabbitMQ em background..."
rabbitmq-server -detached

echo "===> Aguardando RabbitMQ iniciar..."
sleep 10

echo "===> Criando usuário..."
rabbitmqctl add_user "$RABBITMQ_DEFAULT_USER" "$RABBITMQ_DEFAULT_PASS" || true

echo "===> Setando permissões..."
rabbitmqctl set_user_tags "$RABBITMQ_DEFAULT_USER" administrator
rabbitmqctl set_permissions -p / "$RABBITMQ_DEFAULT_USER" ".*" ".*" ".*"

echo "===> Importando definitions..."
rabbitmqctl import_definitions /etc/rabbitmq/definitions.json

echo "===> Parando instância temporária..."
rabbitmqctl stop

echo "===> Subindo RabbitMQ em foreground..."
exec rabbitmq-server