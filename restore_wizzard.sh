#!/bin/bash

# Directories for base and incremental backups
BASE_DIR="/var/backup/mariadb_incremental/base"
INCR_DIR="/var/backup/mariadb_incremental/incr"
RESTORE_DIR="/var/backup/mariadb_incremental/restore"
MYSQL_DATA_DIR="/var/lib/mysql"


INSUFFICIENT_SPACE_THRESHOLD=500


if [ ! -d "$RESTORE_DIR" ]; then
    mkdir -p "$RESTORE_DIR"
elif [ "$(ls -A $RESTORE_DIR)" ]; then
    read -p "Das Verzeichnis $RESTORE_DIR ist nicht leer. Möchten Sie es löschen? (j/n) " answer
    if [ "$answer" = "j" ]; then
        rm -rf "$RESTORE_DIR"
        mkdir -p "$RESTORE_DIR"
        echo "Das Verzeichnis $RESTORE_DIR wurde gelöscht und neu erstellt."
    else
        echo "Fehler: Das Verzeichnis $RESTORE_DIR ist nicht leer."
        exit 1
    fi
fi

# Check if more than INSUFFICIENT_SPACE_THRESHOLD is available
available_space=$(df $RESTORE_DIR | tail -1 | awk '{print $4}')
if [ $available_space -lt $INSUFFICIENT_SPACE_THRESHOLD ]; then
    echo "Less than $INSUFFICIENT_SPACE_THRESHOLD GB of storage space is available. Extracting and preparing the backup may fail."
    read -p "Do you want to proceed anyway? (y/n) " answer
    if [ "$answer" != "y" ]; then
        echo "Operation cancelled."
        exit 1
    fi
fi



# List all available base backups
echo "Available base backups:"
BASE_BACKUPS=($(ls $BASE_DIR))
for i in "${!BASE_BACKUPS[@]}"; do
  echo "$i: ${BASE_BACKUPS[$i]}"
done

# Let the user select the desired base backup
read -p "Select the number of the base backup: " base_number
base_date=${BASE_BACKUPS[$base_number]}
# Check if the directory has write permissions
if [ ! -w "$BASE_DIR/$base_date" ]; then
  echo "Error: The base directory $BASE_DIR/$base_date does not have write permissions."
  exit 1
fi

# List all related incremental backups
echo "Available incremental backups for the selected base backup:"
INCR_BACKUPS=($(find $INCR_DIR/$base_date -mindepth 1 -maxdepth 1 -type d -exec test -e '{}/backup.stream.gz' ';' -print))
for i in "${!INCR_BACKUPS[@]}"; do
  echo "$i: ${INCR_BACKUPS[$i]}"

    # Check if the directory has write permissions
    if [ ! -w "${INCR_BACKUPS[$i]}" ]; then
      echo "Error: The incremental directory ${INCR_BACKUPS[$i]} does not have write permissions."
      exit 1
    fi
done



# Let the user select the desired incremental backup
read -p "Select the number of the incremental backup: " incr_number

# Unpack the base backup
echo "Unpacking base backup..."
SECONDS=0
cd $BASE_DIR/$base_date

cd $RESTORE_DIR
gunzip -c $BASE_DIR/$base_date/backup.stream.gz | mbstream -x

# Prepare the base backup
echo "Preparing base backup... (Unzip: $SECONDS seconds)"
SECONDS=0
mariabackup --export --prepare --target-dir=$RESTORE_DIR
echo "Base backup prepared in $SECONDS seconds."

# Prepare the incremental backups
for i in $(seq 0 $incr_number); do
  # Unpack the incremental backup
  echo "Unpacking incremental backup ${INCR_BACKUPS[$i]}..."
  SECONDS=0
  cd ${INCR_BACKUPS[$i]}
  mkdir unzip
  if [ ! -w "${INCR_BACKUPS[$i]}/unzip" ]; then
    echo "Error: Could not create a writeable directory for unzipping the incremental backup."
    exit 1
  fi
  cd unzip
  gunzip -c ${INCR_BACKUPS[$i]}/backup.stream.gz | mbstream -x

  echo "Preparing incremental backup ${INCR_BACKUPS[$i]}... (Unzip: $SECONDS seconds)"
  SECONDS=0
  mariabackup --export --prepare --target-dir=$RESTORE_DIR --incremental-dir=${INCR_BACKUPS[$i]}/unzip
  echo "Incremental backup ${INCR_BACKUPS[$i]} prepared in $SECONDS seconds."
done
echo ""
echo "You can now restore the backup from the directory $RESTORE_DIR"
echo ""
echo "The following steps can be used to restore the whole backup. Be careful:"
echo "Detailed documentation can be found at https://mariadb.com/kb/en/full-backup-and-restore-with-mariabackup/"
echo "1. Stop the MariaDB Server process."
echo "   systemctl stop mariadb"
echo "2. Ensure that the datadir ($MYSQL_DATA_DIR) is empty (backing it up)"
echo "   mv $MYSQL_DATA_DIR ${MYSQL_DATA_DIR}_BACKUP"
echo "   mkdir $MYSQL_DATA_DIR"
echo "3. Copy the backup files to the datadir."
echo "   mariabackup --copy-back --target-dir=$RESTORE_DIR"
echo "4. Change the ownership of the files to the mysql user."
echo "   chown -R mysql:mysql $MYSQL_DATA_DIR"
echo "5. Start the MariaDB Server process."
echo "   systemctl start mariadb"

echo ""
echo " ! ! ! ! ! "
echo "Do the steps above with caution. The restore process will overwrite the current database with the backup."
echo " ! ! ! ! ! "

echo ""
echo ""


############################################################################################################
# Restore a specific table #################################################################################
############################################################################################################
# User query whether a specific table should be restored
read -p "Do you want to restore a specific table?This script will only print all necessary commands and will NOT run anything! (y/n) " answer
if [ "$answer" = "y" ]; then
    read -p "Enter the name of the database and table to be restored (in format [database].[table_name]): " db_and_table_name
    # New table name is suffixed with _RECOVER
    table_name=$(echo $db_and_table_name | cut -d'.' -f2)
    table_name_backup=$table_name"_RECOVER"
    database_name=$(echo $db_and_table_name | cut -d'.' -f1)
    # Get DDL for the table
    echo "Follow these steps to restore the table $table_name into table $table_name_backup in database $database_name:"
    echo "1. Create a table with same structure as the original table with the following statements:"
    echo ""
    echo "   USE $database_name;"
    echo "   $(sudo mysqldump --no-data --compact ${database_name} ${table_name} | sed "s/$table_name/$table_name_backup/")"
    echo ""
    echo "2. Copy the the IBD and CFG files for the table from the backup directory to the data directory of the database."
    # Copy the IBD and CFG files for the table into current DB directory and rename it to suffixed files
    echo ""
    echo "   cp  $RESTORE_DIR/${database_name}/${table_name}.ibd $MYSQL_DATA_DIR/${database_name}/${table_name_backup}.ibd"
    echo "   cp  $RESTORE_DIR/${database_name}/${table_name}.cfg $MYSQL_DATA_DIR/${database_name}/${table_name_backup}.cfg"
    echo ""
    echo "3. Modify Ownership of the files"
    echo ""
    echo "   chown mysql:mysql $MYSQL_DATA_DIR/$database_name/$table_name_backup.{ibd,cfg}"
    echo ""
    echo "4. Restart the MariaDB Server process."
    echo "That's it. The table $table_name_backup in database $database_name should now be restored."
fi