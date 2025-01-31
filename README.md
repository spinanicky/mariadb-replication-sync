### `README.md`

```markdown
# MariaDB Master-Slave Resynchronization Script

This script automates the process of resynchronizing a MariaDB master-slave replication setup. It is designed to work with Docker containers named `db-primary` and `db-replica`. The script ensures that the slave database is synchronized with the master database using GTID (Global Transaction ID).

## Prerequisites

1. **Docker**: Ensure Docker is installed and running.
2. **MariaDB Containers**: Two MariaDB containers named `db-primary` and `db-replica` must be running.
3. **Root Password**: You will need the root password for the MariaDB instances.

## Usage

1. **Clone the repository** or download the script (`mariadb-resync.sh`).
2. **Make the script executable**:
   ```bash
   chmod +x mariadb-resync.sh
   ```
3. **Run the script**:
   ```bash
   ./mariadb-resync.sh
   ```

## Features

- **GTID Extraction**: Automatically extracts the GTID from the master database dump.
- **Replication Setup**: Configures the slave database to replicate from the master using GTID.
- **Replication User**: Creates a dedicated replication user with a randomly generated password.
- **Container Check**: Verifies that the required Docker containers (`db-primary` and `db-replica`) are running.
- **Backup and Restore**: Creates a backup from the master and restores it on the slave.

## Steps Performed by the Script

1. **Container Check**: Verifies that the required Docker containers (`db-primary` and `db-replica`) are running.
2. **Master Selection**: Prompts the user to select which database should act as the master.
3. **GTID Extraction**: Extracts the GTID from the master database dump.
4. **Backup and Restore**: Creates a backup from the master and restores it on the slave.
5. **Replication Configuration**: Configures the slave to replicate from the master using GTID.
6. **Status Check**: Verifies that replication is running correctly.

## Example

```bash
$ ./mariadb-resync.sh
MariaDB Master-Slave Resynchronization Script
-------------------------------------------
Enter MariaDB root password: 

Which database should be the master?
1) db-primary
2) db-replica
Enter choice (1 or 2): 1

Using db-primary as master and db-replica as slave

Current GTID positions:
Master:
+------------------+
| @@gtid_current_pos |
+------------------+
| 0-1-100          |
+------------------+
Slave:
+------------------+
| @@gtid_current_pos |
+------------------+
| 0-1-90           |
+------------------+

Extracted GTID: 100-365266

Success! Replication is running properly.
Replication credentials:
User: replication
Password: R4nd0mP@ssw0rd
```

## Cleanup

The script automatically cleans up temporary files (e.g., database dumps) after execution.

## Troubleshooting

- **Slave Not Running**: If the slave fails to start replication, check the slave status using the output provided by the script.
- **Container Issues**: Ensure the Docker containers are running and accessible.

## License

This script is provided under the MIT License. Feel free to modify and distribute it as needed.
```
