#!/bin/sh
# Creates Temporal's two databases on the shared Postgres server and applies any
# pending schema versions. Every step is idempotent, so this runs on each deploy
# and is also how the schema is upgraded when the Temporal image is bumped.
set -eu

schema=/etc/temporal/schema/postgresql/v12
for pair in temporal:temporal temporal_visibility:visibility; do
  db=${pair%%:*}
  dir=${pair#*:}
  tool="temporal-sql-tool --plugin postgres12 --ep $POSTGRES_SEEDS -u $POSTGRES_USER -p $DB_PORT --db $db"
  $tool create
  $tool setup-schema -v 0.0
  $tool update-schema -d "$schema/$dir/versioned"
done
echo "Temporal schema is up to date"
