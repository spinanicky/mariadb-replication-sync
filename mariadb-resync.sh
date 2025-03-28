#!/bin/bash

set -e

# Function to check if docker containers exist and are running
check_containers() {
    if ! docker ps | grep -q "db-primary\|db-replica"; then
        echo "Error: Required containers (db-primary and db-replica) not found or not running"
        exit 1
    fi
}

# Function to generate a random password
generate_password() {
    openssl rand -base64 16 | tr -d '/+=' | cut -c1-16
}

# Function to wait for MariaDB to be ready
wait_for_mariadb() {
    local container=$1
    local root_pass=$2
    echo "Waiting for MariaDB in $container to be ready..."
    while ! docker exec $container mariadb-admin ping -h localhost -u root -p"$root_pass" --silent; do
        sleep 1
    done
}


# Function to check if a GTID string is valid
check_gtid() {
    local gtid=$1
    local regex='^([0-9]{1,10})-([0-9]{1,10})-([0-9]{1,20})$'

    if [[ $gtid =~ $regex ]]; then
        local domain_id=${BASH_REMATCH[1]}
        local server_id=${BASH_REMATCH[2]}
        local sequence_number=${BASH_REMATCH[3]}

        # Check if domain_id and server_id are 32-bit unsigned integers
        if (( domain_id < 0 || domain_id > 4294967295 )); then
            echo "Invalid domain ID: $domain_id"
            return 1
        fi

        if (( server_id < 0 || server_id > 4294967295 )); then
            echo "Invalid server ID: $server_id"
            return 1
        fi

        # Check if sequence_number is a 64-bit unsigned integer
        local max_64bit="18446744073709551615"
        if [[ ${#sequence_number} -gt ${#max_64bit} ]]; then
            echo "Invalid sequence number: $sequence_number (too long)"
            return 1
        elif [[ ${#sequence_number} -eq ${#max_64bit} && "$sequence_number" > "$max_64bit" ]]; then
            echo "Invalid sequence number: $sequence_number (exceeds 64-bit limit)"
            return 1
        fi

        echo "GTID is valid: $gtid"
        return 0
    else
        echo "Invalid GTID format: $gtid"
        return 1
    fi
}




# Main script
echo "MariaDB Master-Slave Resynchronization Script"
echo "-------------------------------------------"

# Check if containers exist
check_containers

# Get root password
read -sp "Enter MariaDB root password: " ROOT_PASS
echo

# Ask user which database to use as master
echo -e "\nWhich database should be cloned from as master?"
echo "1) db-primary"
echo "2) db-replica"
read -p "Enter choice (1 or 2): " master_choice

if [ "$master_choice" = "1" ]; then
    MASTER="db-primary"
    SLAVE="db-replica"
elif [ "$master_choice" = "2" ]; then
    MASTER="db-replica"
    SLAVE="db-primary"
else
    echo "Invalid choice. Exiting."
    exit 1
fi

echo -e "\nUsing $MASTER as master and $SLAVE as slave"

# Show current GTID positions
master_gtid_current_pos=$(docker exec $MASTER mariadb -u root -p"$ROOT_PASS" -e "SELECT @@gtid_current_pos;" -s --skip-column-names)
master_gtid_binlog_pos=$(docker exec $MASTER mariadb -u root -p"$ROOT_PASS" -e "SELECT @@gtid_binlog_pos;" -s --skip-column-names)
slave_gtid=$(docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "SELECT @@gtid_current_pos;" -s --skip-column-names)

# Print the current GTID positions
echo -e "\nCurrent GTID positions:"
echo "Master (GTID Current Pos): $master_gtid_current_pos"
echo "Master (GTID Binlog Pos): $master_gtid_binlog_pos"
echo "Slave: $slave_gtid"

# Compare the GTID positions on the master server
if [ "$master_gtid_current_pos" != "$master_gtid_binlog_pos" ]; then
  echo -e "\nGTID positions on the master do not match. The script will be stopped."

  # Suggest corrective actions
  echo -e "\nSuggested steps:"
  echo "1. Stop the replica server."
  echo "2. On the master, run: FLUSH BINARY LOGS;"
  echo "3. Restart the master server."
  echo "4. Once the above steps are done, re-run this script."

  # Exit the script with an error code
  exit 1
fi

# Generate new replication password
REPL_PASS=$(generate_password)

# Stop slave and reset
echo -e "\nStopping replication and resetting slave..."
docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "STOP SLAVE; RESET SLAVE ALL;"

# Create backup from master
echo -e "\nCreating backup from master..."
docker exec $MASTER mariadb-dump -u root -p"$ROOT_PASS" --all-databases --master-data=2 --single-transaction > /tmp/dump.sql

# # Extract GTID from the gtid_slave_pos table in the dump
# numbers=$(awk '/INSERT INTO `gtid_slave_pos` VALUES/ {getline; print}' /tmp/dump.sql | grep -oP '\(\K[^)]+')

# # Use awk to extract the 3rd and 4th numbers
# num3=$(echo "$numbers" | awk -F, '{print $3}')
# num4=$(echo "$numbers" | awk -F, '{print $4}')

# # Combine the numbers into a string in the format "num3-num4"
# GTID="${num3}-${num4}"

GTID=$(grep -oP "gtid_slave_pos='\K[0-9\-]+" /tmp/dump.sql)

# Print the extracted GTID
echo "Extracted GTID: $GTID"

if  check_gtid "$gtid" && [[ -n "$gtid" ]]; then
#if [[ "$gtid" =~ ^[0-9\-]+$ && -n "$gtid" ]]; then
  echo "GTID is valid."
else
  echo "GTID is invalid. Check the dump file in /tmp/dump.sql for the string SET GLOBAL gtid_slave_pos. If not present:"
  echo "1. Stop the replica server."
  echo "2. On the master, run: FLUSH BINARY LOGS;"
  echo "3. Restart the master server."
  echo "4. Once the above steps are done, re-run this script."
  exit 1
fi

# Copy dump to slave container
echo -e "\nCopying backup to slave..."
docker cp /tmp/dump.sql $SLAVE:/tmp/dump.sql

# Import dump on slave
echo -e "\nImporting backup on slave..."
docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "RESET MASTER;"
docker exec $SLAVE sh -c "mariadb -u root -p'$ROOT_PASS' < /tmp/dump.sql"

# Create replication user on both servers
echo -e "\nConfiguring replication user on both servers..."

# On master
docker exec $MASTER mariadb -u root -p"$ROOT_PASS" -e "
DROP USER IF EXISTS 'replication'@'%';
CREATE USER 'replication'@'%' IDENTIFIED BY '$REPL_PASS';
GRANT REPLICATION SLAVE, SLAVE MONITOR ON *.* TO 'replication'@'%';
FLUSH PRIVILEGES;"

# On slave
docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "
DROP USER IF EXISTS 'replication'@'%';
CREATE USER 'replication'@'%' IDENTIFIED BY '$REPL_PASS';
GRANT REPLICATION SLAVE, SLAVE MONITOR ON *.* TO 'replication'@'%';
FLUSH PRIVILEGES;"

# Configure slave with GTID
echo -e "\nConfiguring slave..."
docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "
STOP SLAVE;
SET GLOBAL gtid_slave_pos='$GTID';
RESET SLAVE ALL;
CHANGE MASTER TO
MASTER_HOST='$MASTER',
MASTER_USER='replication',
MASTER_PASSWORD='$REPL_PASS',
MASTER_USE_GTID=slave_pos;
START SLAVE;"

#SET GLOBAL gtid_slave_pos='0-$GTID';

# Wait for slave to start
sleep 5

# Show final GTID positions
echo -e "\nFinal GTID positions:"
echo "Master:"
docker exec $MASTER mariadb -u root -p"$ROOT_PASS" -e "SELECT @@gtid_current_pos;"
echo "Slave:"
docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "SELECT @@gtid_current_pos;"

# Check slave status
echo -e "\nChecking slave status..."
SLAVE_STATUS=$(docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "SHOW SLAVE STATUS\G")
if echo "$SLAVE_STATUS" | grep -q "Slave_IO_Running: Yes" && echo "$SLAVE_STATUS" | grep -q "Slave_SQL_Running: Yes"; then
    echo -e "\nSuccess! Replication is running properly."
    echo "Replication credentials:"
    echo "User: replication"
    echo "Password: $REPL_PASS"
else
    echo -e "\nError: Replication not running properly. Please check slave status:"
    docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "SHOW SLAVE STATUS\G"
fi

# Cleanup
rm -f /tmp/dump.sql
docker exec $SLAVE rm -f /tmp/dump.sql
