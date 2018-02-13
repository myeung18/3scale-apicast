#!/bin/sh

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 client_id key certificate"
    exit 1
fi

CLIENT_ID="$1"
KEY="$2"
CERT="$3"
TOKEN_ENDPOINT="https://${SSO_FRONT_HOSTNAME:=localhost:8443}/auth/realms/${SSO_REALM:=3scale}/protocol/openid-connect/token"
AUDIENCE="https://${SSO_FRONT_HOSTNAME:=localhost:8443}/auth/realms/${SSO_REALM:=3scale}"

JWT="$(./sign.sh "${CLIENT_ID}" "${AUDIENCE}" "${KEY}")"

curl -D - -k --cert "${CERT}" --key "${KEY}" -X POST -d "client_assertion=${JWT}" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" "${TOKEN_ENDPOINT}"
