FROM docker.elastic.co/logstash/logstash-oss:7.13.1

ARG version=1.2.0

USER root

RUN yum install -y -q epel-release && yum install -y -q jq nc memcached socat

# Logstash-plugin can take a very long time to run; this can be due to entropy
# starvation. In our use-case we don't need to worry about particularly
# high grade of randomness, and /dev/urandom will do just fine. There
# are plenty of ways we could achieve this, changing /dev/random out
# to point to the same source as /dev/urandom will set this globally.
#
# Note: even with this done, installing a logstash plugin still takes
# an awful 86 seconds... without it it takes about 110 seconds; not a
# big change on this particular system, but when entropy is low...
#
RUN rm -f /dev/random; mknod /dev/random c 1 9

COPY logstash-filter-memcached-${version}.gem /tmp/

RUN logstash-plugin install /tmp/logstash-filter-memcached-${version}.gem

RUN install -o 1000 -g 1000 -m 0755 -d /qa

USER 1000

ADD * /qa

ENTRYPOINT /qa/entrypoint.sh
