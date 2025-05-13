#!/bin/sh

if [ -f /data/options.json ]; then
# this is an HA Addon thing, which strictly speaking we might not want
    tempio -conf /data/options.json -template /iotawatt_config.yaml.gtmpl -out iotawatt_config.yaml
fi

if [ -f iotawatt_config.yaml ]; then
    exec perl iwMQTT.pl
else
# this is only useful for testing
    echo "iotawatt_config.yaml is missing, sleeping for an hour"
    sleep 3600;
fi
