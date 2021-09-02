#!/bin/bash
set -euo pipefail
set -x

# Hardcoded environment variables for MySQL directories
MYSQL=/home/glsai/mysql/mysql-5.7.27-linux-glibc2.12-x86_64/
MYSQL_RUNDIR=/home/glsai/mysql/mysql-5.7.27-linux-glibc2.12-x86_64/
CROMWELL=/share/ClusterShare/software/contrib/evaben7/cromwell/38/prebuilt/cromwell-38.jar
CROMWELL_BN="$(basename ${CROMWELL})"

# Arguments
db_host="$1"
db_port="$2"
db_name="$3"
crom_port="$4"

# Configure mutect2.conf
# Set the MySQL hostname, port, and database name
sed -i -e "s/DBHOST_TO_SED/${db_host}/g" \
    -e "s/DBPORT_TO_SED/${db_port}/g" \
    -e "s/DBNAME_TO_SED/${db_name}/g" \
    -e "s/CROMWELL_PORT_TO_SED/${crom_port}/g" \
    ./workflow/mutect2.conf

# Configure options.json
# '#' delimiters are used to enable path substitution
sed -i -e "s#PWD_TO_SED#${PWD}#g" ./workflow/options.json
# Set up output directories
mkdir -p workflow_out
mkdir -p workflow_logs
mkdir -p workflow_call_logs

# Configure run.sh
sed -i -e "s/CROMWELL_PORT_TO_SED/${crom_port}/g" ./run.sh

# Configure start_cromwell.sh
ln -s ${CROMWELL}
sed -i -e "s/CROMWELL_JAR_TO_SED/${CROMWELL_BN}/g" ./start_cromwell.sh
# Create the database for Cromwell
echo 'CREATE DATABASE '"$db_name"';
GRANT ALL PRIVILEGES ON '"$db_name"'.* TO '\''cromwell_user'\''@'\''localhost'\'' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON '"$db_name"'.* TO '\''cromwell_user'\''@'\''%'\'' WITH GRANT OPTION;' \
| ${MYSQL}/bin/mysql -u root --password=password --socket="$MYSQL_RUNDIR"/socket
