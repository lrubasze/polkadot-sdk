#!/bin/bash

set -e
set -u

#/var/folders/sc/c9stf8y96798j41wbx8hp42w0000gn/T/zombie-f11bbe75-90f6-481c-aaaa-0a6b46666997
BASE_DIR=$1
WHAT=$2
LOG_LEVEL=${3-info}
MONITOR_OUTPUT=${4-none}
collator_metrics=
PATH=/Users/lukasz/work/paritytech/polkadot-sdk/bin:$PATH

if [ "$WHAT" == "validator-0" ] ; then

    cmd="polkadot --chain ${BASE_DIR}/validator-0/cfg/westend-local.json --name validator-0 --rpc-cors all --rpc-methods unsafe --node-key 03e782ee3b8a41bef2863724c2a71e3e666c6aa2a394e34424da72a8b17c4244 --no-telemetry --prometheus-external --validator --insecure-validator-i-know-what-i-do --prometheus-port 62627 --rpc-port 62626 --listen-addr /ip4/0.0.0.0/tcp/62628/ws --base-path ${BASE_DIR}/validator-0/data -lparachain=debug"
    pjs="https://polkadot.js.org/apps/?rpc=ws://127.0.0.1:62626#/explorer"
    papi="https://dev.papi.how/explorer#networkId=custom&endpoint=ws://127.0.0.1:62626"
    node_metrics="http://127.0.0.1:62627/metrics"

elif [ "$WHAT" == "validator-1" ] ; then

    cmd="polkadot --chain ${BASE_DIR}/validator-1/cfg/westend-local.json --name validator-1 --rpc-cors all --rpc-methods unsafe --node-key d2b40032aef27989dd2c44bedfe887441a2f14d0f5702d96d0bb62479be9d367 --no-telemetry --prometheus-external --validator --insecure-validator-i-know-what-i-do --prometheus-port 62631 --rpc-port 62630 --listen-addr /ip4/0.0.0.0/tcp/62632/ws --base-path ${BASE_DIR}/validator-1/data --bootnodes /ip4/127.0.0.1/tcp/62628/ws/p2p/12D3KooWQxLRH6mMorYJEL1ohnqx1uMDd3Z7HytYhGXwr9W7EoNj -lparachain=debug"
    pjs="https://polkadot.js.org/apps/?rpc=ws://127.0.0.1:62630#/explorer"
    papi="https://dev.papi.how/explorer#networkId=custom&endpoint=ws://127.0.0.1:62630"
    node_metrics="http://127.0.0.1:62631/metrics"

elif [ "$WHAT" == "collator" ] ; then

    cmd="polkadot-parachain --chain ${BASE_DIR}/collator/cfg/2000.json --name collator --rpc-cors all \
            --rpc-methods unsafe --node-key 53cf10627db4ce8abcddad56fc510cdfc58bfe587b0cbb6772f1f0727266e565 \
            --prometheus-external --collator --prometheus-port 62637 --rpc-port 62636 --listen-addr /ip4/0.0.0.0/tcp/62638/ws \
            --base-path ${BASE_DIR}/collator/data --warm-up-trie-cache \
            -l${LOG_LEVEL} \
            --pool-type=fork-aware --trie-cache-size=32212254720 --rpc-max-subscriptions-per-connection=327680 \
            --rpc-max-connections=102400 --pool-limit=819200 --pool-kbytes=2048000 \
            -- \
            --base-path ${BASE_DIR}/collator/relay-data --chain ${BASE_DIR}/collator/cfg/westend-local.json \
            --execution wasm --port 62633 --prometheus-port 62634"
    pjs="https://polkadot.js.org/apps/?rpc=ws://127.0.0.1:62636#/explorer"
    papi="https://dev.papi.how/explorer#networkId=custom&endpoint=ws://127.0.0.1:62636"
    collator_metrics="http://127.0.0.1:62637/metrics"
    node_metrics="http://127.0.0.1:62634/metrics"
else
    echo "name ${WHAT} not supported"
    exit 1
fi

echo "launching $WHAT"
echo "log_level = $LOG_LEVEL"
echo "pjs = $pjs"
echo "papi = $papi"
if  [ "$collator_metrics" != "" ] ; then
    echo "metrics = $collator_metrics"
else
    echo "metrics = $node_metrics"
fi

log_file=${BASE_DIR}/${WHAT}.log

$cmd >$log_file 2>&1 &
pid=$!

echo "$WHAT PID = $pid"
echo "kill -9 $pid"
echo "tail -f $log_file"

if [ "$MONITOR_OUTPUT" != "none" ]; then
    echo "monitoring  pid=$pid monitor_output=$MONITOR_OUTPUT"
    top -pid $pid -stats pid,cpu,mem -l0 | grep --line-buffered $pid >${MONITOR_OUTPUT} &
    echo "node monitor pid = $!"
fi
