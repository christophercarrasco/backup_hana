#!/bin/bash

BACKUP_FILE=`dirname $0`"/backup.conf"
VERSION="1.2"

# Changelog
# 1.2
# Moved reclaim before compress log

if [ ! -f "${BACKUP_FILE}" ]; then
	echo "Configuration file does not exist"
	exit 4
else
	#source `dirname $0`/backup.conf
	C=$(sed -nr "/^\[GENERAL\]/ { :l /^\s*[^#].*/ p; n; /^\[/ q; b l; }" "${BACKUP_FILE}")
	eval $(sed -n '1!p' <<<"${C}")
	if [ "${HANA_VERSION}" != 1 ] && [ "${HANA_VERSION}" != 2 ]; then
		echo "Wrong HANA version"
		exit 777
		#Wrong HANA version
	fi

	if [ "${HANA_VERSION}" == 1 ]; then
		C=$(sed -nr "/^\[HANA1_CONFIG\]/ { :l /^\s*[^#].*/ p; n; /^\[/ q; b l; }" "${BACKUP_FILE}")
		eval $(sed -n '1!p' <<<"${C}")
	fi
	if [ "${HANA_VERSION}" == 2 ]; then
		C=$(sed -nr "/^\[HANA2_CONFIG\]/ { :l /^\s*[^#].*/ p; n; /^\[/ q; b l; }" "${BACKUP_FILE}")
		eval $(sed -n '1!p' <<<"${C}")
		C=$(sed -nr "/^\[HANA2_KEYS\]/ { :l /^\s*[^#].*/ p; n; /^\[/ q; b l; }" "${BACKUP_FILE}")
		eval $(sed -n '1!p' <<<"${C}")
	fi
fi

FAIL=0
HOSTNAME=$(hostname)

mark()
{
	case $1 in
		0)
			echo -ne "\u2718\n"
			;;
		1)
			echo -ne "\u2714\n"
			;;
		2)	echo -ne "Skipped\n"
			;;
		3)
			echo -ne "Default\n"
			;;
		*)
			;;
	esac
}

precheck()
{
	echo -ne "\nChecking requirements for SID $1:\n\n"

	#Backup path
	echo -ne "Backup path\t\t"
	if [ -d "${BACKUP_PATH}/$1" ]; then
		mark 1
	else
		mark 0
		FAIL=$((FAIL + 1))
		#Backup path was not found
	fi

	#Service user
	echo -ne "Service user\t\t"
	if [ "${HANA_VERSION}" == 2 ]; then
		USER="${SAPSYSTEMNAME,,}adm"
		if getent passwd "${USER}" > /dev/null 2>&1; then
			mark 2
		else
			mark 0
			FAIL=$((FAIL + 2))
			#Service user does not exist
		fi
	elif [ "${HANA_VERSION}" == 1 ]; then
		USER=$(echo "${1}" | tr "[:upper:]" "[:lower:]")"adm"
		if getent passwd "${USER}" > /dev/null 2>&1; then
			mark 1
		else
			mark 0
			FAIL=$((FAIL + 2))
			#Service user does not exist
		fi
	fi

	#Backup KEY
	echo -ne "Backup KEY\t\t"
	if [ "${FAIL}" == 2 ] || [ "${FAIL}" == 3 ]; then
		mark 2
	else
		#Get hdbuserstore KEY
		if [ "${HANA_VERSION}" == 2 ]; then
			KEY_EXE=$(su - "${USER}" -c "hdbuserstore LIST ${!1}")
		elif [ "${HANA_VERSION}" == 1 ]; then
			KEY_EXE=$(su - "${USER}" -c "hdbuserstore LIST ${BACKUP_KEY}")
		fi
		if [ "${KEY_EXE}" != "KEY BACKUP NOT FOUND" ]; then
			mark 1
		else
			mark 0
			FAIL=$((FAIL + 4))
			#Backup key is not configured
		fi
	fi
	
	echo -ne "INI file\t\t"
	if [ "${FAIL}" == 2 ] || [ "${FAIL}" == 3 ]; then
		mark 2
	else
		if [ ${HANA_VERSION} == 2 ]; then
			#INI_FILE=$(su - "${USER}" -c "echo \$DIR_INSTANCE/../global/hdb/custom/config/DB_${1}/global.ini")
			INI_FILE=$(su - "${USER}" -c "echo \$DIR_INSTANCE/../global/hdb/custom/config/global.ini")
		else
			INI_FILE=$(su - "${USER}" -c "echo \$DIR_INSTANCE/../global/hdb/custom/config/global.ini")
		fi
		
		if [ ! -f "${INI_FILE}" ]; then
			FAIL=$((FAIL + 8))
			mark 0
			#INI file does not exist
		else
			BPDV=$(sed -nr "/^\[persistence\]/ { :l /^basepath_databackup[ ]*=/ { s/.*=[ ]*//; p; q;}; n; b l;}" ${INI_FILE})
			BPLV=$(sed -nr "/^\[persistence\]/ { :l /^basepath_logbackup[ ]*=/ { s/.*=[ ]*//; p; q;}; n; b l;}" ${INI_FILE})
			
			if [ -z ${BPDV} ] || [ -z ${BPLV} ]; then
				mark 3
				BPDV=$(su - "${USER}" -c "echo \$DIR_INSTANCE/backup/data")
				BPLV=$(su - "${USER}" -c "echo \$DIR_INSTANCE/backup/log")
			else
				mark 1
			fi
		fi
	fi
	
	if [ ${HANA_VERSION} == 2 ]; then
		BPDV="${BPDV}/DB_${1}"
		BPLV="${BPLV}/DB_${1}"
	fi

	if [ ${FAIL} -gt 0 ]; then
		echo -ne "\nSome requirements were not met. Please fix them and try again\n"
		exit "${FAIL}"
	else
		backup $1
		compress_data $1
		compress_log $1
		reclaim $1
		delete $1
	fi

}

backup()
{
	if [ ${HANA_VERSION} == 2 ]; then
		BACKUP_KEY_EXE="${!1}"
	elif [ ${HANA_VERSION} == 1 ]; then
		BACKUP_KEY_EXE="${BACKUP_KEY}"
	fi
	DIR_INSTANCE=$(su - "${USER}" -c "echo \$DIR_INSTANCE")
	echo -e "\nBacking up SID $1"
	su - "${USER}" -c ". ${DIR_INSTANCE}/hdbenv.sh"
	su - "${USER}" -c "hdbsql -U ${BACKUP_KEY_EXE} \"backup data using file ('${BACKUP_PREFIX}')\""
}

compress_data()
{
	mkdir -p "${BACKUP_PATH}/${1}/${HOSTNAME}/data"

	echo -ne "Compressing DATA backups\n"
	tar czf "${BACKUP_PATH}/${1}/${HOSTNAME}/data/${BACKUP_PREFIX}.tar.gz" "${BPDV}/${BACKUP_PREFIX}"* >/dev/null 2>&1
}

compress_log()
{
	mkdir -p "${BACKUP_PATH}/${1}/${HOSTNAME}/log"

	echo -ne "Compresing LOG backups\n"
	tar czf "${BACKUP_PATH}/${1}/${HOSTNAME}/log/${BACKUP_PREFIX}.tar.gz" "${BPLV}/"* >/dev/null 2>&1
}

reclaim()
{
	echo -ne "Deleting old backups\n"
	SQL_EXE=$(su - ${USER} -c "hdbsql -U ${BACKUP_KEY_EXE} \"SELECT TOP 1 min(to_bigint(BACKUP_ID)) FROM SYS.M_BACKUP_CATALOG where SYS_START_TIME >= ADD_DAYS(CURRENT_TIMESTAMP, -${LOCAL_RETENTION}) and ENTRY_TYPE_NAME = 'complete data backup' and STATE_NAME = 'successful'\"")
	BACKUP_ID=$(echo -e "${SQL_EXE}" | awk 'NR==2')
	SQL_EXE=$(su - ${USER} -c "hdbsql -U ${BACKUP_KEY_EXE} \"BACKUP CATALOG DELETE ALL BEFORE BACKUP_ID $BACKUP_ID COMPLETE\"")
}

delete()
{
	FILE_RETENTION=$((RETENTION - 1))
	echo -ne "Processing Data...\n"
	FILE_NUM=$(ls -1 --file-type "${BACKUP_PATH}/${1}/${HOSTNAME}/data/" | grep -v '/$' | wc -l)
	if [ ${FILE_NUM} -gt 0 ]; then
		find "${BACKUP_PATH}/${1}/${HOSTNAME}/data/"* -mtime +"${FILE_RETENTION}" -exec rm {} \;
	fi
	
	echo -ne "Processing Logs...\n"
	FILE_NUM=$(ls -1 --file-type "${BACKUP_PATH}/${1}/${HOSTNAME}/log/" | grep -v '/$' | wc -l)
	if [ ${FILE_NUM} -gt 0 ]; then
		find "${BACKUP_PATH}/${1}/${HOSTNAME}/log/"* -mtime +"${FILE_RETENTION}" -exec rm {} \;
	fi
}

#Start
if [ -z $1 ]; then
	echo "You must specify the HANA System ID"
else
	#clear
	echo -ne "Start time: $(date)\n"
	echo -ne "Backup tool for HANA - Ver. ${VERSION}\n"
	precheck $1
	echo -ne "End time: $(date)\n"
	echo -ne "--------------------------------------\n"
fi
