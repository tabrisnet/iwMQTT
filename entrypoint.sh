#!/bin/sh

tempio -conf /data/options.json -template /iotawatt_config.yaml.gtmpl -out iotawatt_config.yaml

exec perl iwMQTT.pl
