#!/usr/bin/env bash

cd $(dirname $0)

# Check for all the shell commands this script requires
for CMD in curl jq wg-quick base64; do
    if ! command -v $CMD &>/dev/null ; then
        echo $CMD required but not found.  Install before continuing!
        exit 1
    fi
done

# the settings file is used to store auth and wireguard info
# it is full of bash variables that are `source` into this script
# when they are needed
SETTINGS_FILE=".settings.env"

# the portfowarding file stores information for setting and refreshing
# port forwarding information on PIA servers
PF_SETTINGS_FILE=".portforward.env"

# Name of the wireguard file created by the setup command
WG_CONF_FILE="pia.conf"

# ============================================================================
# Function declarations
# ============================================================================
function getToken() {
    PIA_USER=$1
    PIA_PASS=$2

    TOKEN_RESPONSE=$(curl -Gs -u "$PIA_USER:$PIA_PASS" \
        "https://privateinternetaccess.com/gtoken/generateToken")

    if [ "$(echo "$TOKEN_RESPONSE" | jq -r '.status')" != "OK" ]; then
        exit 1
    else
        echo "$TOKEN_RESPONSE" | jq -r '.token'
        return 0
    fi
}
export -f getToken

if [[ $1 == "setup" ]]; then
    if [ -e $SETTINGS_FILE ]; then
        echo $SETTINGS_FILE exists.  Aborting to prevent overwrite
        exit 1
    fi

    if [ -e $WG_CONF_FILE ]; then
        echo $WG_CONF_FILE exists.  Aborting to prevent overwrite
        exit 1
    fi

    echo "Please enter basic information"
    read -p "  PIA Username: " PIA_USER
    read -sp "  PIA Password: " PIA_PASS
    echo
    read -p "  Use portfowarding? [true]: " PIA_USE_PF

    if [[ $PIA_USE_PF == "" ]]; then
        PIA_USE_PF="true"
    fi

    PIA_TOKEN=$(getToken $PIA_USER $PIA_PASS)
    if [ $? -ne 0 ]; then
        echo "Failed fetching Auth Token"
        exit 1
    fi

    MAX_LATENCY=${MAX_LATENCY:-0.05}
    export MAX_LATENCY

    # This function checks the latency you have to a specific region.
    # It will print a human-readable message to stderr,
    # and it will print the variables to stdout
    printServerLatency() {
      serverIP="$1"
      regionID="$2"
      regionName="$(echo ${@:3} |
        sed 's/ false//' | sed 's/true/(geo)/')"
      time=$(LC_NUMERIC=en_US.utf8 curl -o /dev/null -s \
        --connect-timeout $MAX_LATENCY \
        --write-out "%{time_connect}" \
        http://$serverIP:443)
      if [ $? -eq 0 ]; then
        >&2 echo $regionName: ${time}s
        echo $time $regionID $serverIP
      fi
    }
    export -f printServerLatency

    serverlist_url='https://serverlist.piaservers.net/vpninfo/servers/v4'
    echo -n "Getting the server list... "
    # Get all region data since we will need this on multiple occasions
    all_region_data=$(curl -s "$serverlist_url" | head -1)
    if [[ ${#all_region_data} -lt 1000 ]]; then
      echo "Could not get correct region data. To debug this, run:"
      echo "$ curl -v $serverlist_url"
      echo "If it works, you will get a huge JSON as a response."
      exit 1
    else
        echo "OK!"
    fi

    # If the server list has less than 1000 characters, it means curl failed.
    if [[ ${#all_region_data} -lt 1000 ]]; then
      echo "Could not get correct region data. To debug this, run:"
      echo "$ curl -v $serverlist_url"
      echo "If it works, you will get a huge JSON as a response."
      exit 1
    fi

    # Test one server from each region to get the closest region.
    # If port forwarding is enabled, filter out regions that don't support it.
    if [[ $PIA_USE_PF == "true" ]]; then
      summarized_region_data="$( echo $all_region_data |
        jq -r '.regions[] | select(.port_forward==true) |
        .servers.meta[0].ip+" "+.id+" "+.name+" "+(.geo|tostring)' )"
    else
      summarized_region_data="$( echo $all_region_data |
        jq -r '.regions[] |
        .servers.meta[0].ip+" "+.id+" "+.name+" "+(.geo|tostring)' )"
    fi

    bestRegion="$(echo "$summarized_region_data" |
      xargs -I{} bash -c 'printServerLatency {}' |
      sort | head -1 | awk '{ print $2 }')"

    if [ -z "$bestRegion" ]; then
      echo ...
      echo No region responded within ${MAX_LATENCY}s, consider using a higher timeout.
      echo For example, to wait 1 second for each region, inject MAX_LATENCY=1 like this:
      echo $ MAX_LATENCY=1 ./get_region_and_token.sh
      exit 1
    fi

    # Get all data for the best region
    regionData="$( echo $all_region_data |
      jq --arg REGION_ID "$bestRegion" -r \
      '.regions[] | select(.id==$REGION_ID)')"

    echo

    PIA_META_IP="$(echo $regionData | jq -r '.servers.meta[0].ip')"
    PIA_META_HOST="$(echo $regionData | jq -r '.servers.meta[0].cn')"
    PIA_WG_IP="$(echo $regionData | jq -r '.servers.wg[0].ip')"
    PIA_WG_HOST="$(echo $regionData | jq -r '.servers.wg[0].cn')"

    # get PIA_WG_VIP (needed for port forwarding)
    PIA_WG_PRIVATE_KEY="$(wg genkey)"
    PIA_WG_PUBLIC_KEY="$( echo "$PIA_WG_PRIVATE_KEY" | wg pubkey)"
    export PIA_WG_PUBLIC_KEY
    export PIA_WG_PRIVATE_KEY

    RESPONSE="$(curl -s -G \
      --connect-to "$PIA_WG_HOST::$PIA_WG_IP:" \
      --cacert "ca.rsa.4096.crt" \
      --data-urlencode "pt=${PIA_TOKEN}" \
      --data-urlencode "pubkey=$PIA_WG_PUBLIC_KEY" \
      "https://${PIA_WG_HOST}:1337/addKey" )"

    # Check if the API returned OK and stop this script if it didn't.
    if [ "$(echo "$RESPONSE" | jq -r '.status')" != "OK" ]; then
        echo "  - Failed to get WG Peer info  "
        echo "    Test manually with: "
        echo
        echo curl -s -G \
          --connect-to "$PIA_WG_HOST::$PIA_WG_IP:" \
          --cacert "ca.rsa.4096.crt" \
          --data-urlencode "pt=${PIA_TOKEN}" \
          --data-urlencode "pubkey=$PIA_WG_PUBLIC_KEY" \
          "https://${PIA_WG_HOST}:1337/addKey"
        exit 1
    fi

    PIA_DNS_SERVERS="$(echo "$RESPONSE" | jq -r '.dns_servers[0]')"
    PIA_WG_PEER_IP="$(echo "$RESPONSE" | jq -r '.peer_ip')"
    PIA_WG_VIP="$(echo "$RESPONSE" | jq -r '.server_vip')"
    PIA_WG_SERVER_KEY="$(echo "$RESPONSE" | jq -r '.server_key')"
    PIA_WG_SERVER_PORT="$(echo "$RESPONSE" | jq -r '.server_port')"

    # generate the settings file
    echo "# Auto-Generated by generate_settings.sh on $(date)" > $SETTINGS_FILE
    echo "# Use pia-wg.sh setup to create this file. Do not edit
#
PIA_USER=$PIA_USER
PIA_PASS=$PIA_PASS
PIA_META_IP=$PIA_META_IP
PIA_META_HOST=$PIA_META_HOST
PIA_WG_HOST=$PIA_WG_HOST
PIA_WG_IP=$PIA_WG_IP
PIA_WG_VIP=$PIA_WG_VIP" >> $SETTINGS_FILE

    # generate wireguard configuration pia.conf
    echo "# Auto-Generated by generate_settings.sh on $(date)" > $WG_CONF_FILE
    echo "# Use pia-wg.sh setup to create this file. Do not edit
[Interface]
Address = $PIA_WG_PEER_IP
PrivateKey = $PIA_WG_PRIVATE_KEY
# Uncomment to use PIA DNS servers
# DNS = $PIA_DNS_SERVERS

[Peer]
PersistentKeepalive = 25
PublicKey = $PIA_WG_SERVER_KEY
AllowedIPs = 0.0.0.0/0
Endpoint = ${PIA_WG_IP}:$PIA_WG_SERVER_PORT
" >> $WG_CONF_FILE

elif [[ $1 == "token" ]]; then
    if [ ! -e $SETTINGS_FILE ]; then
        echo "$SETTINGS_FILE not found.  Run pia-wg.sh setup"
        exit 1
    else
        source $SETTINGS_FILE
    fi
    PIA_TOKEN=$(getToken $PIA_USER $PIA_PASS)
    if [ $? -ne 0 ]; then
        echo "Failed fetching Auth Token"
        exit 1
    else
        echo $PIA_TOKEN
    fi

elif [[ $1 == "pf_set" ]]; then
    if [ ! -e $SETTINGS_FILE ]; then
        echo "$SETTINGS_FILE not found.  Run pia-wg.sh setup"
        exit 1
    else
        source $SETTINGS_FILE
    fi

    if [ ! -e $PF_SETTINGS_FILE ]; then
        PIA_TOKEN=$($0 token)
        if [ $? -ne 0 ]; then
            echo "Failed fetching token to create $PF_SETTINGS_FILE"
            exit 1
        fi

        echo "File: $PF_SETTINGS_FILE not found.  Creating a new one."
        echo -n "  - Fetching token from metaserver host ... "

        TOKEN_RESPONSE=$(curl -Gs -u "$PIA_USER:$PIA_PASS" \
            "https://privateinternetaccess.com/gtoken/generateToken")

        if [ "$(echo "$TOKEN_RESPONSE" | jq -r '.status')" != "OK" ]; then
            echo "Failed to fetch token from metadata server"
            exit 1
        else
            PIA_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token')
        fi

        if [ ! PIA_TOKEN ]; then
            echo "Failed!"
            exit 1
        else
            echo "Success!"
        fi

        echo -n "  - Fetching payload/signature values from $PIA_WG_VIP ... "
        PF_JSON=$(curl -Gs -m 5 \
            --connect-to "$PIA_WG_HOST::$PIA_WG_VIP:" \
            --cacert "ca.rsa.4096.crt" \
            --data-urlencode "token=${PIA_TOKEN}" \
            "https://${PIA_WG_HOST}:19999/getSignature")

        if [ "$(echo "$PF_JSON" | jq -r '.status')" != "OK" ]; then
            echo "Failed!"
            echo "    ... are you connected to PIA via wireguard?"
            echo "        this script needs to talk to the host's via VIP"
            exit 1
        else
            echo "Success!"
        fi

        # We need to get the signature out of the previous response.
        # The signature will allow the us to bind the port on the server.
        PIA_PF_SIGNATURE="$(echo "$PF_JSON" | jq -r '.signature')"

        # The payload has a base64 format. We need to extract it from the
        # previous response and also get the following information out:
        # - port: This is the port you got access to
        # - expires_at: this is the date+time when the port expires
        PIA_PF_PAYLOAD="$(echo "$PF_JSON" | jq -r '.payload')"
        PIA_PF_PORT="$(echo "$PIA_PF_PAYLOAD" | base64 -d | jq -r '.port')"

        # The port normally expires after 2 months. If you consider
        # 2 months is not enough for your setup, please open a ticket.
        PIA_PF_EXPIRES="$(echo "$PIA_PF_PAYLOAD" | base64 -d | jq -r '.expires_at')"

        echo "# Auto-Generated by port_forwarding.sh on $(date)" > $PF_SETTINGS_FILE
        echo "PIA_PF_PAYLOAD=$PIA_PF_PAYLOAD" >> $PF_SETTINGS_FILE
        echo "PIA_PF_SIGNATURE=$PIA_PF_SIGNATURE" >> $PF_SETTINGS_FILE
        echo "PIA_PF_PORT=$PIA_PF_PORT" >> $PF_SETTINGS_FILE
        echo "PIA_PF_EXPIRES=$PIA_PF_EXPIRES" >> $PF_SETTINGS_FILE

        echo "  - Wrote new $PF_SETTINGS_FILE"
    else
        echo "Loading cached settings from $PF_SETTINGS_FILE"
        source $PF_SETTINGS_FILE
    fi

    echo -n "  - Binding/Refreshing binding on port:$PIA_PF_PORT ... "
    BIND_RESPONSE=$(curl -Gs -m 5 \
        --connect-to "$PIA_WG_HOST::$PIA_WG_VIP:" \
        --cacert "ca.rsa.4096.crt" \
        --data-urlencode "payload=${PIA_PF_PAYLOAD}" \
        --data-urlencode "signature=${PIA_PF_SIGNATURE}" \
        "https://${PIA_WG_HOST}:19999/bindPort")

    if [ "$(echo "$BIND_RESPONSE" | jq -r '.status')" != "OK" ]; then
        echo "Failed!"
        echo "Ports expire after two months; maybe that's why?"
        echo "Delete $PF_SETTINGS_FILE and run port_forwarding.sh again"
        echo "--- Response from PIA"
        echo "$BIND_RESPONSE"
        exit 1
    else
        echo "Success!"
    fi

elif [[ $1 == "pf_clean" ]]; then
    if [ -e $PF_SETTINGS_FILE ]; then
        rm $PF_SETTINGS_FILE
        echo "Deleted $PF_SETTINGS_FILE.  Use $0 pf_set to create portforwarding configuration"
    fi

elif [[ $1 == "pf_port" ]]; then
    if [ -e $PF_SETTINGS_FILE ]; then
        source $PF_SETTINGS_FILE
        echo $PIA_PF_PORT
    else
        >&2 echo "Error! No $PF_SETTINGS_FILE.  Setup port forwarding with $0 pf_set"
        exit 1
    fi
else
    echo "Unknown command: $1"
    echo "Usage: "
    echo "  $0 setup    - Create configuration files"
    echo "  $0 token    - Fetch an auth token with user/password"
    echo "  $0 pf_set   - setup port forwarding"
    echo "  $0 pf_clean - clean up portforwarding data"
    echo "  $0 pf_port  - last known port forwarding port"
    exit 1
fi
