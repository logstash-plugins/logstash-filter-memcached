FROM cameronkerrnz/logstash-plugin-dev:7.13
#FROM logstash-plugin-dev:7.13

USER root

RUN yum install -jq epel-release; yum install -yq memcached socat nc jq

USER builder