#!/bin/sh

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 apikey client_id"
    exit 1
fi

APIKEY="$1"
CLIENT_ID="$2"

REGISTER_ENDPOINT="https://${SSO_REGISTER_HOSTNAME:=localhost:8444}/auth/realms/${SSO_REALM:=3scale}/register"

curl -D - -k --cert client.crt --key client.key -X POST -d "client_id=${CLIENT_ID}" -H "apikey: ${APIKEY}" "${REGISTER_ENDPOINT}"
