#!/bin/bash

url=http://127.0.0.1:62637/metrics

while true; do
    value=$(curl -s $url | \
        grep 'substrate_tasks_ended_total{kind="blocking",reason="finished",task_group="default",task_name="warm-up-trie-cache",chain="asset-hub-westend-local"}' | \
        awk '{print $2}')
    echo "Current value: $value"
    if [ "$(echo "$value >= 1" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
      echo "Warm-up finished!"
      break
    fi
    if [ "$value" == "" ];  then
        echo "No warm-up needed!"
        break
    fi
    sleep 10
  done
