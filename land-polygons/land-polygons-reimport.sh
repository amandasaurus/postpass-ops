#! /bin/bash
set -o errexit -o nounset -o pipefail

export PGUSER=${PGUSER:-osm}
export PGDATABASE=${PGDATABASE:-gis}

for WANTED_CMD in ogr2ogr curl units ; do
	if ! command -v $WANTED_CMD &>/dev/null ; then
		echo "${WANTED_CMD}(1) not installed."
		exit 1
	fi
done

WORKINGDIR=$(realpath "${WORKINGDIR:-$(dirname "$0")}")
export WORKINGDIR

cd "$WORKINGDIR" || exit

if [ ! -w "${WORKINGDIR}" ] ; then
	echo 1>&2 "No write permissions to directory $WORKINGDIR"
	exit 1
fi

export PGAPPNAME="postpass_land_polygons_updater"

if ! psql -XAt -c "select 1" &>/dev/null ; then
	echo 1>&2 "PostgreSQL not running, or you have no access rights"
	psql -XAt -c "select 1"
	exit 1
fi

# If the latest data is <5min, then exit early. Try to save HTTP requests.
if [ "$(psql -XAt -c "select extract(epoch from (now()-value::timestamp))::integer < 300  from land_polygons_properties where property = 'current_timestamp';" &>/dev/null)" = "t" ] ; then
	exit 0
fi

# Download
for TYPE in land water ; do
	timeout 1h curl -s -A "${PGAPPNAME}/1" --remote-time --location -O -z "${TYPE}-polygons-split-4326.zip" "https://osmdata.openstreetmap.de/download/${TYPE}-polygons-split-4326.zip"
done


for TYPE in land water ; do
	if [ "$(psql -XAt -c "SELECT count(*) FROM pg_tables WHERE tablename = '${TYPE}_polygons_properties';")" -eq 0 ] ; then
		psql -X -c "CREATE TABLE ${TYPE}_polygons_properties (property text not null primary key, value text not null);"
	fi

	CURRENT_TIMESTAMP=$(psql -XAt -c "select extract(epoch from value::timestamp)::integer from ${TYPE}_polygons_properties where property = 'current_timestamp';")


	if [ -z "$CURRENT_TIMESTAMP" ] || [ "$CURRENT_TIMESTAMP" -lt "$(stat -c %Y ${TYPE}-polygons-split-4326.zip)" ] ; then
		echo "Reimporting new ${TYPE}-polgyons-split-4326.zip"
		ls -lh ${TYPE}-polygons-split-4326.zip

		# client_min_messages stops the message if this table doesn't exist.
		psql -qX -c "SET client_min_messages TO 'WARNING'; DROP TABLE IF EXISTS ${TYPE}_polygons_new CASCADE;"

		# No geom index, because when we rename the table, the index doesn't get
		# changed from ${TYPE}_polygons_new_geom (or whatever) and so we can't do an
		# import the next time.
		# the shapefile already has a id column, so just use that. we can't stop
		# ogr2ogr from adding one
		ogr2ogr -select "" -overwrite -nln "${TYPE}_polygons_new" -lco GEOMETRY_NAME=geom -lco FID=fid -lco SPATIAL_INDEX=NONE -f PostgreSQL PG: /vsizip/${TYPE}-polygons-split-4326.zip/${TYPE}-polygons-split-4326/${TYPE}_polygons.shp

		psql -qX -c "ALTER TABLE ${TYPE}_polygons_new DROP COLUMN fid;"		# don't need id col.

		# rename table
		psql -qX -c "BEGIN; DROP TABLE IF EXISTS ${TYPE}_polygons CASCADE; ALTER TABLE ${TYPE}_polygons_new RENAME TO ${TYPE}_polygons; CREATE INDEX ${TYPE}_polygons_geom ON ${TYPE}_polygons USING gist (geom) ; COMMIT"
		echo "Renamed ${TYPE}_polygons_new → ${TYPE}_polygons"

		CURRENT_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" -d "@$(stat -c %Y ${TYPE}-polygons-split-4326.zip )")
		psql -qX -c "INSERT INTO ${TYPE}_polygons_properties (property, value) VALUES ('current_timestamp', '${CURRENT_TIMESTAMP}') ON CONFLICT (property) DO UPDATE SET value = EXCLUDED.value;"
		echo "Updated ${TYPE}_polygons_properties to set the current_timestamp to \"${CURRENT_TIMESTAMP}\""

	else
		echo "No new data to import. Current ${TYPE}_polygons timestamp is $CURRENT_TIMESTAMP / $(date --rfc-3339=seconds -d "@${CURRENT_TIMESTAMP}") / $(( $(date +%s) -  CURRENT_TIMESTAMP )) sec ago / $(units $(( $(date +%s) -  CURRENT_TIMESTAMP ))sec time) ago."
	fi

done
