#!/bin/bash
set -e

# ./install_catalyst.sh https://try.catalyst-soar.com https://try-authelia.catalyst-soar.com --no-ssl alice:alice:alice@example.com bob:bob:bob@example.com admin:admin:admin@example.com"

print_usage() {
  echo "Usage:"
  echo "  ./install_catalyst.sh [-h | --help]"
  echo "  ./install_catalyst.sh <hostname> <authelia_hostname> <ssl_certificate> <ssl_certificate_key> <admin-user:admin-password:admin-email> <user:password:email> ..."
  echo "  ./install_catalyst.sh <hostname> <authelia_hostname> --no-ssl <admin-user:admin-password:admin-email> <user:password:email> ..."
  echo "Example:"
  echo "  ./install_catalyst.sh https://try.catalyst-soar.com https://try-authelia.catalyst-soar.com --no-ssl admin:admin:admin@example.com alice:alice:alice@example.com bob:bob:bob@example.com"
}

# if help flag
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
  print_usage
  exit 0
fi

# set default hostname
if [ -z "$1" ]; then
  echo "Error: hostname is required"
  print_usage
  exit 1
else
  catalyst_addr="$1"
  if [[ "$catalyst_addr" != "https://"* ]]; then
    echo "Error: hostname must start with https://"
    print_usage
    exit 1
  fi
fi

# set default authelia hostname
if [ -z "$2" ]; then
  echo "Error: authelia hostname is required"
  print_usage
  exit 1
else
  authelia_addr="$2"
  if [[ "$authelia_addr" != "https://"* ]]; then
    echo "Error: authelia hostname must start with https://"
    print_usage
    exit 1
  fi
fi

# set default ssl
if [ -z "$3" ]; then
  echo "Error: ssl certificate or --no-ssl is required"
  print_usage
  exit 1
else
  if [ "$3" == "--no-ssl" ]; then
    ssl="false"
  else
    ssl="true"
    ssl_certificate="$3"
    ssl_certificate_key="$4"
    shift 1

    if [ -z "$ssl_certificate" ]; then
      echo "Error: ssl certificate is required"
      print_usage
      exit 1
    fi

    if [ -z "$ssl_certificate_key" ]; then
      echo "Error: ssl certificate key is required"
      print_usage
      exit 1
    fi

    if [ ! -f "$ssl_certificate" ]; then
      echo "Error: ssl certificate file does not exist"
      print_usage
      exit 1
    fi

    if [ ! -f "$ssl_certificate_key" ]; then
      echo "Error: ssl certificate key file does not exist"
      print_usage
      exit 1
    fi
  fi
fi

# set default users
if [ -z "$4" ]; then
  echo "Error: at least one user is required"
  print_usage
  exit 1
else
  users=()
  while [ -n "$4" ]; do
    if [[ "$4" != *":"* ]]; then
      echo "Error: user must be in the format user:password:email"
      print_usage
      exit 1
    fi

    users+=("$4")
    shift
  done

  admin_user=$(echo "${users[0]}" | cut -d: -f1)
fi

AUTHELIA_HOST=${authelia_addr#"http://"}
AUTHELIA_HOST=${AUTHELIA_HOST#"https://"}
AUTHELIA_DOMAIN=${AUTHELIA_HOST%%:*}

# create initial api key
INITIAL_API_KEY=$(openssl rand -hex 64)
echo "$INITIAL_API_KEY" >INITIAL_API_KEY

# download catalyst setup
curl -sL "https://github.com/SecurityBrewery/catalyst-setup/archive/refs/tags/v0.10.3.zip" -o catalyst_install.zip
unzip catalyst_install.zip
cd "catalyst-setup-0.10.3"

# generate authelia keys
openssl genrsa -out authelia/private.pem 4096
openssl rsa -in authelia/private.pem -outform PEM -pubout -out authelia/public.pem
AUTHELIA_CLIENT_SECRET=$(openssl rand -hex 64)
AUTHELIA_PRIVATE_KEY=$(tr -d '\n' <authelia/private.pem)

# copy templates
cp docker-compose.tmpl.yml docker-compose.yml
cp authelia/configuration.tmpl.yml authelia/configuration.yml
if [ "$ssl" == "true" ]; then
  cp nginx/nginx-ssl.tmpl.conf nginx/nginx.conf
  mkdir -p nginx/certs
  cp "$ssl_certificate" nginx/certs/cert.pem
  cp "$ssl_certificate_key" nginx/certs/key.pem
else
  cp nginx/nginx.tmpl.conf nginx/nginx.conf
fi

# adapt docker-compose.yml
sed -i.bak "s#__SECRET__#$(openssl rand -hex 64)#" docker-compose.yml
sed -i.bak "s#__ARANGO_ROOT_PASSWORD__#$(openssl rand -hex 32)#" docker-compose.yml
sed -i.bak "s#__S3_PASSWORD__#$(openssl rand -hex 64)#" docker-compose.yml
sed -i.bak "s#__INITIAL_API_KEY__#$INITIAL_API_KEY#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_JWT_SECRET__#$(openssl rand -hex 64)#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_PRIVATE_KEY__#$AUTHELIA_PRIVATE_KEY#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_HMAC_SECRET__#$(openssl rand -hex 64)#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_STORAGE_ENCRYPTION_KEY__#$(openssl rand -hex 64)#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_SESSION_SECRET__#$(openssl rand -hex 64)#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_CLIENT_SECRET__#$AUTHELIA_CLIENT_SECRET#" docker-compose.yml
sed -i.bak "s#__ADDR__#$catalyst_addr#" docker-compose.yml
sed -i.bak "s#__AUTHELIA_ADDR__#$authelia_addr#" docker-compose.yml
sed -i.bak "s#__ADMIN_USER__#$admin_user#" docker-compose.yml

# adapt authelia configuration.yml
sed -i.bak "s#__AUTHELIA_CLIENT_SECRET__#$AUTHELIA_CLIENT_SECRET#" authelia/configuration.yml
sed -i.bak "s#__ADDR__#$catalyst_addr#" authelia/configuration.yml
sed -i.bak "s#__DOMAIN__#$AUTHELIA_DOMAIN#" authelia/configuration.yml

# create authelia users_database.yml
echo "users:" >authelia/users_database.yml
for user in "${users[@]}"; do
  username=$(echo "$user" | cut -d: -f1)
  password=$(echo "$user" | cut -d: -f2)
  email=$(echo "$user" | cut -d: -f3)
  argon2_output=$(docker run --rm -i authelia/authelia:4 authelia crypto hash generate argon2 --password "$password")  argon2_hash=${argon2_output#*Digest: }
  email=${password#*:}
  {
      echo "  $username:"
      echo "    displayname: \"$username\""
      echo "    password: \"$argon2_hash\""
      echo "    email: \"$email\""
  } >>authelia/users_database.yml
done

# adapt nginx nginx.conf
sed -i.bak "s#__AUTHELIA_HOST__#$AUTHELIA_HOST#" nginx/nginx.conf
if [ "$ssl" == "true" ]; then
  sed -i.bak "s#__SSL_CERTIFICATE__#$ssl_certificate#" nginx/nginx.conf
  sed -i.bak "s#__SSL_CERTIFICATE_KEY__#$ssl_certificate_key#" nginx/nginx.conf
fi

# start containers
docker compose pull
docker compose build --no-cache
docker compose up --build --force-recreate --detach

# remove all .bak files
find . -name "*.bak" -type f -delete
