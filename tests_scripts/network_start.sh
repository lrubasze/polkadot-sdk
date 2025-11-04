#!/bin/bash

BASE_DIR=${1-test1}
rm -rf $BASE_DIR
cp -r zombie_snapshot $BASE_DIR

./node_launch.sh $BASE_DIR validator-0

./node_launch.sh $BASE_DIR validator-1

# echo "./node_launch.sh $BASE_DIR collator >${COLLATOR_LOG} 2>&1 &"
