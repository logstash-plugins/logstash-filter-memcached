echo "Starting memcached"
memcached -d -l 127.0.0.1
sleep 1

echo "Loading test data into memcached"
for i in `seq 1 10`
do
  echo -en 'set perf:10.0.0.'$i' 0 10000 100\r\n1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890\r\n' | nc 127.0.0.1 11211
done

echo "Stats poller should start in 60 seconds"
( sleep 60; /qa/stats-poller ) &

echo "Starting logstash"
logstash -f /qa/logstash.conf
