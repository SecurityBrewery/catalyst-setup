#!/bin/bash
set -e

# curl -sL "https://raw.githubusercontent.com/SecurityBrewery/catalyst-setup/main/install_catalyst.sh" -o install_catalyst.sh
# bash install_catalyst.sh https://dev.catalyst-soar.com https://dev-authelia.catalyst-soar.com

# if help flag
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    echo "Usage: ./install_catalyst.sh <domain> <hostname> <authelia_hostname>"
    echo "Example: ./install_catalyst.sh catalyst-soar.com https://dev.catalyst-soar.com https://dev-authelia.catalyst-soar.com"
    exit 0
fi

# set default domain
if [ -z "$1" ]; then
    echo "No domain provided, using default domain: localhost"
    catalyst_domain="localhost"
else
    catalyst_domain="$1"
fi

# set default hostname
if [ -z "$2" ]; then
    echo "No hostname provided, using default: http://localhost"
    catalyst_addr="http://localhost"
else
    catalyst_addr="$2"
fi

# set default authelia hostname
if [ -z "$3" ]; then
    echo "No authelia hostname provided, using default: http://localhost:8082"
    authelia_addr="http://localhost:8082"
else
    authelia_addr="$3"
fi

AUTHELIA_HOST=${authelia_addr#"http://"}
AUTHELIA_HOST=${AUTHELIA_HOST#"https://"}

# reset
curl -sL "https://github.com/SecurityBrewery/catalyst-setup/archive/refs/tags/v0.10.0-rc.1.zip" -o catalyst_install.zip
unzip catalyst_install.zip
cd "catalyst-install-0.10.0-rc.1"

# copy templates
cp docker-compose.tmpl.yml docker-compose.yml
cp authelia/configuration.tmpl.yml authelia/configuration.yml
cp nginx/nginx.tmpl.conf nginx/nginx.conf

# generate authelia keys
openssl genrsa -out authelia/private.pem 4096
openssl rsa -in authelia/private.pem -outform PEM -pubout -out authelia/public.pem
AUTHELIA_CLIENT_SECRET=$( openssl rand -hex 64 )
AUTHELIA_PRIVATE_KEY=$( tr -d '\n' < authelia/private.pem )
INITIAL_API_KEY=$( openssl rand -hex 64 )

# adapt docker-compose.yml
sed -i.bak "s#__SECRET__#$( openssl rand -hex 64 )#" docker-compose.yml
sed -i.bak "s#__ARANGO_ROOT_PASSWORD__#$( openssl rand -hex 64 )#" docker-compose.yml
sed -i.bak "s#__S3_PASSWORD__#$( openssl rand -hex 64 )#" docker-compose.yml
sed -i.bak "s#__INITIAL_API_KEY__#$INITIAL_API_KEY#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_JWT_SECRET__#$( openssl rand -hex 64 )#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_PRIVATE_KEY__#$AUTHELIA_PRIVATE_KEY#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_HMAC_SECRET__#$( openssl rand -hex 64 )#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_STORAGE_ENCRYPTION_KEY__#$( openssl rand -hex 64 )#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_SESSION_SECRET__#$( openssl rand -hex 64 )#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_CLIENT_SECRET__#$AUTHELIA_CLIENT_SECRET#" docker-compose.yml
sed -i.bak "s#__ADDR__#$catalyst_addr#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_ADDR__#$authelia_addr#" docker-compose.yml

# adapt authelia configuration.yml
sed -i.bak "s#__AUTHELIA_CLIENT_SECRET__#$AUTHELIA_CLIENT_SECRET#" authelia/configuration.yml
sed -i.bak "s#__ADDR__#$catalyst_addr#" authelia/configuration.yml
sed -i.bak "s#__DOMAIN__#$catalyst_domain#" authelia/configuration.yml

# adapt nginx ngnix.conf
sed -i.bak "s#__AUTHELIA_HOST__#$AUTHELIA_HOST#" nginx/nginx.conf

# start containers
docker compose pull
docker compose build --no-cache
docker compose up --build --force-recreate --detach

# remove all .bak files
find . -name "*.bak" -type f -delete

if [ "$4" == "generate_fake_data" ]; then
  curl -sL https://github.com/SecurityBrewery/catalyst-faker/releases/download/v0.1.1/catalyst-faker_0.1.1_Linux_x86_64.tar.gz -o catalyst-faker.tar.gz
  tar -xvf catalyst-faker.tar.gz
  rm catalyst-faker.tar.gz
  mv catalyst-faker /usr/local/bin
  catalyst-faker http://localhost/api "$INITIAL_API_KEY"
fi
