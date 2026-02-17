#!/bin/sh

if [ -f ".env" ]; then
	set -a
	. ".env"
	set +a
fi

KEY_ID="$ZELA_PROJECT_KEY_ID"
KEY_SECRET="$ZELA_PROJECT_KEY_SECRET"
PROCEDURE="$ZELA_PROCEDURE"
PARAMS="$ZELA_PARAMS"

usage() {
	echo "usage: define required variables in .env and run ./run-procedure.sh"
	echo "required: ZELA_PROJECT_KEY_ID, ZELA_PROJECT_KEY_SECRET, ZELA_PROCEDURE, ZELA_PARAMS"
}

if [ -z "$KEY_ID" ] || [ -z "$KEY_SECRET" ] || [ -z "$PROCEDURE" ] || [ -z "$PARAMS" ]; then
	usage
	exit 1
fi

token=$(curl -s --user "$KEY_ID:$KEY_SECRET" --data 'grant_type=client%5Fcredentials' --data 'scope=zela%2Dexecutor%3Acall' https://auth.zela.io/realms/zela/protocol/openid-connect/token | jq -r .access_token)
# a little bit stupid but we print the output of the request to stderr and capture timing information on stdout
stats=$(curl -s --write-out '%{stdout} %{time_starttransfer} - %{time_pretransfer}' -o /dev/stderr \
	--header "Authorization: Bearer $token" --header 'Content-type: application/json' \
	--data "{ \"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"zela.$PROCEDURE\", \"params\": $PARAMS }" https://executor.zela.io)
# then we compute the subtraction of timing using bc and print it
req_time=$(bc -e "$stats")
echo "\nRequest time: ${req_time}s"
