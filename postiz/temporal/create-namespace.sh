#!/bin/sh
# Creates the "default" namespace Postiz uses once Temporal is serving.
# Postiz registers its own search attributes in it at startup.
set -eu

namespace=default
attempts=0
until temporal operator cluster health --address "$TEMPORAL_ADDRESS" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || { echo "Temporal did not become healthy" >&2; exit 1; }
  sleep 2
done

if temporal operator namespace describe -n "$namespace" --address "$TEMPORAL_ADDRESS" >/dev/null 2>&1; then
  echo "Namespace $namespace already exists"
else
  temporal operator namespace create -n "$namespace" --retention 168h --address "$TEMPORAL_ADDRESS"
fi
