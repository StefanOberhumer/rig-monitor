#!/bin/bash

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd $BASE_DIR

. ${BASE_DIR}/conf/rig-monitor.conf

#Current time
TIME=`date +%s%N`

unset $DATA_BINARY

if [ -f ${BASE_DIR}/run/PROFIT_LOCK ]; then
    	echo "profit calculator process still running! Exiting..."
	exit
else
	touch  ${BASE_DIR}/run/PROFIT_LOCK
fi

for ARGUMENT in "$@"; do
	if [ "$ARGUMENT" == "-bt" ]; then
		set -x
	elif [ "$ARGUMENT" == "-d" ]; then
		DEBUG=1
	elif [[ $ARGUMENT =~ ^-p[0-9]+ ]]; then
		L_INDEX=${ARGUMENT:2}
		POOL_LIST=("${POOL_LIST[@]:$L_INDEX:1}")
	else
		echo "Argument unknonw: ${ARGUMENT}"
		rm ${BASE_DIR}/run/PROFIT_LOCK 
		exit
	fi
done

SAVEIFS=$IFS

for POOL_LINE in "${POOL_LIST[@]}"
do
	IFS=$',' read POOL_TYPE CRYPTO LABEL BASE_API_URL API_TOKEN WALLET_ADDR <<<${POOL_LINE}
	if (( DEBUG == 1 )); then
		echo "Pool info in conf file: $POOL_TYPE $CRYPTO $LABEL"
	fi

	# Query coin price in BTC and QUOTE CURRENCY as defined in the conf file
	COIN_PRICE_SQL="select * from coin_data where crypto='"${CRYPTO}"'"
	COIN_PRICE=`curl -sG 'http://localhost:8086/query?pretty=true' --data-urlencode "db=rigdata" --data-urlencode "epoch=ns" --data-urlencode "q=${COIN_PRICE_SQL}" `
	if (( DEBUG == 1 )); then
		echo "SQL: ${COIN_PRICE_SQL}"
		echo "OUTPUT: ${COIN_PRICE}"
	fi
	PRICE="price_${QUOTE_CURRENCY,,}"
	VOLUME="24h_volume_${QUOTE_CURRENCY,,}"
	MARKET="market_cap_${QUOTE_CURRENCY,,}"

	c_data=($(echo $COIN_PRICE | jq -r --arg price $PRICE --arg volume $VOLUME --arg market $MARKET '.results[0].series[0].values[0] | "\(.[7]) \(.[8]) \(.[6]) \(.[1]) \(.[2]) \(.[3]) \(.[5])" '))
	echo "${c_data[@]}"
	
	continue
		
	# Aggregate pool payments in 24h periods
	LAST_RECORD_SQL="SELECT last(revenue) from profitability where label='"${LABEL}"'"
	if (( DEBUG == 1 )); then
		echo "SQL: ${LAST_RECORD_SQL}"
	fi
	LAST_RECORD=`curl -G 'http://localhost:8086/query?pretty=true' --data-urlencode "db=rigdata" --data-urlencode "epoch=ns" --data-urlencode "q=${LAST_RECORD_SQL}" \
		| jq -r '.results[0].series[0].values[0][0]' | awk '/^null/ { print 0 }; /[0-9]+/ {print substr($1,1,10) };' `
	if (( LAST_RECORD == 0 )); then
		# Get epoch from 1 month ago and round it to 12:00am
		_TIME=`date -d "1 month ago" +%s`
		LAST_RECORD=$(( ${_TIME} - (${_TIME} % (24 * 60 * 60)) ))000000000
	fi
	if (( DEBUG == 1 )); then
		echo "calculating profitability from ${LAST_RECORD} until ${TIME} (now)"
	fi
	if [[ "$POOL_TYPE" == "MPOS" ]]; then
		REVENUE_24H_SQL="select amount from pool_payments where time >= $LAST_RECORD and time <= $TIME and label='"${LABEL}"'"
		REVENUE_24H=`curl -G 'http://localhost:8086/query?pretty=true' --data-urlencode "db=rigdata" --data-urlencode "epoch=ns" --data-urlencode "q=${REVENUE_24H_SQL}" \
			| jq -r '.results[0].series[0].values[] | "date=\(.[0]),revenue=\(.[1])"' `
	else
		REVENUE_24H_SQL="select sum(amount) from pool_payments where time >= $LAST_RECORD and time <= $TIME and label='"${LABEL}"' group by time(24h)"
		REVENUE_24H=`curl -G 'http://localhost:8086/query?pretty=true' --data-urlencode "db=rigdata" --data-urlencode "epoch=ns" --data-urlencode "q=${REVENUE_24H_SQL}" \
			| jq -r '.results[0].series[0].values[] | "revenue=\(.[1]) \(.[0])"' `
	fi
	if (( DEBUG == 1 )); then
		echo "SQL: ${REVENUE_24H_SQL}"
		echo "OUTPUT: ${REVENUE_24H}"
	fi

	MEASUREMENT="revenue"
	TAGS="pool_type=${POOL_TYPE},crypto=${CRYPTO},label=${LABEL}"
	while read -r FIELDS_AND_TIME;do 
		LINE="${MEASUREMENT},${TAGS} ${FIELDS_AND_TIME}"
		if (( DEBUG == 1 )); then
			echo "$LINE"
		fi 
		DATA_BINARY="${DATA_BINARY}"$'\n'"${LINE}"
	done <<< "$REVENUE_24H"

done

# Write to DB
#curl -i -XPOST 'http://localhost:8086/write?db=rigdata' --data-binary "${DATA_BINARY}"

IFS=$SAVEIFS
rm ${BASE_DIR}/run/PROFIT_LOCK 

