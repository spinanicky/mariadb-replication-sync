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

# Main script
echo "MariaDB Master-Slave Resynchronization Script"
echo "-------------------------------------------"

# Check if containers exist
check_containers

# Get root password
read -sp "Enter MariaDB root password: " ROOT_PASS
echo

# Ask user which database to use as master
echo -e "\nWhich database should be the master?"
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
echo -e "\nCurrent GTID positions:"
echo "Master:"
docker exec $MASTER mariadb -u root -p"$ROOT_PASS" -e "SELECT @@gtid_current_pos;"
echo "Slave:"
docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "SELECT @@gtid_current_pos;"

# Generate new replication password
REPL_PASS=$(generate_password)

# Stop slave and reset
echo -e "\nStopping replication and resetting slave..."
docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "STOP SLAVE; RESET SLAVE ALL;"

# Create backup from master
echo -e "\nCreating backup from master..."
docker exec $MASTER mariadb-dump -u root -p"$ROOT_PASS" --all-databases --master-data=2 --single-transaction > /tmp/dump.sql

# Extract GTID from the gtid_slave_pos table in the dump
numbers=$(awk '/INSERT INTO `gtid_slave_pos` VALUES/ {getline; print}' /tmp/dump.sql | grep -oP '\(\K[^)]+')

# Use awk to extract the 3rd and 4th numbers
num3=$(echo "$numbers" | awk -F, '{print $3}')
num4=$(echo "$numbers" | awk -F, '{print $4}')

# Combine the numbers into a string in the format "num3-num4"
GTID="${num3}-${num4}"

# Print the extracted GTID
echo "Extracted GTID: $GTID"

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
GRANT REPLICATION SLAVE ON *.* TO 'replication'@'%';
FLUSH PRIVILEGES;"

# On slave
docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "
DROP USER IF EXISTS 'replication'@'%';
CREATE USER 'replication'@'%' IDENTIFIED BY '$REPL_PASS';
GRANT REPLICATION SLAVE ON *.* TO 'replication'@'%';
FLUSH PRIVILEGES;"

# Configure slave with GTID
echo -e "\nConfiguring slave..."
docker exec $SLAVE mariadb -u root -p"$ROOT_PASS" -e "
STOP SLAVE;
SET GLOBAL gtid_slave_pos='0-$GTID';
CHANGE MASTER TO
MASTER_HOST='$MASTER',
MASTER_USER='replication',
MASTER_PASSWORD='$REPL_PASS',
MASTER_USE_GTID=slave_pos;
START SLAVE;"

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
