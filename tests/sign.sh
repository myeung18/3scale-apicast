#!/bin/bash

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 subject audience key"
    exit 1
fi

KEY="$3"
ISSUER="$1"
SUBJECT="$1"
AUDIENCE="$2"
EXPIRATION=$(date -v+1d "+%s")
ISSUED_AT=$(date "+%s")
NOT_BEFORE=$(date -v-1H "+%s")
TOKENID=$(openssl rand -hex 8)

jwt -claim "iss=$ISSUER" \
    -claim "sub=$SUBJECT" \
    -claim "aud=$AUDIENCE" \
    -claim "exp=$EXPIRATION" \
    -claim "iat=$ISSUED_AT" \
    -claim "nbf=$NOT_BEFORE" \
    -claim "jti=$TOKENID" \
    -sign + \
    -key "$KEY" \
    -alg "RS256"
