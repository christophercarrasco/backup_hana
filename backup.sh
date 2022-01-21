#!/bin/bash
# HANA Backup Service
# Version: 1.0.8
# Developer: Christopher Carrasco Cartagena

#
#if [ ! -f `dirname $0`/backup.version ]; then
#    echo -e "\nVersion file does not exists... Aborting.\n"
#    exit 4
#fi

if [ ! -f `dirname $0`/backup.conf ]; then
    echo -e "\nConfiguration file does not exists... Aborting.\n"
    exit 4
fi

URL=none
#VERSION=$(<`dirname $0`/backup.version)
VERSION="1.0.8"

function version_gt()
{
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1";
}

version_check()
{
    echo -ne "*** Version Control ***\n"
    echo -ne "Current version is: ${VERSION}\n"
    echo -ne "Checking newer versions..."
    wget -U "Mozilla" --no-check-certificate --server-response -o wgetOut -O backup.version.tmp "${URL}"backup.version >/dev/null 2>&1 #&
    _wgetHttpCode=`cat wgetOut | gawk '/HTTP[/]/{ print $2 }'`
    rm wgetOut
    if [ "${_wgetHttpCode}" != "200" ]; then
        echo "[Error] Can't reach the update server..."
        sh `dirname $0`/backup.sh --version-check
        exit 99
    fi
    VERSION_CHECK=$(<backup.version.tmp)
    if version_gt "${VERSION_CHECK}" "${VERSION}"; then
        echo -ne " Found version ${VERSION_CHECK}. Upgrading...\n"
        #wget -U "Mozilla" --no-check-certificate --no-verbose -O backup.conf.tmp "${URL}"backup.conf >/dev/null 2>&1 #&
        wget -U "Mozilla" --no-check-certificate --no-verbose -O backup.sh.tmp "${URL}"backup.sh >/dev/null 2>&1 #&
        rm `dirname $0`/backup.sh
        mv backup.sh.tmp `dirname $0`/backup.sh
        #rm `dirname $0`/backup.conf
        #mv `dirname $0`/backup.conf.tmp `dirname $0`/backup.conf
        rm `dirname $0`/backup.version
        mv backup.version.tmp `dirname $0`/backup.version
        chmod +x `dirname $0`/backup.sh
        echo -ne "Upgrade succesful.\n"
        sh `dirname $0`/backup.sh --version-check
        exit 99
    else
        echo -ne " No newer version found.\n"
        rm backup.version.tmp
    fi
}

optspec=":-:"

CHECK=0

while getopts "$optspec" optchar; do
    case "${optchar}" in
        -)
            case "${OPTARG}" in
                version-check)
                    CHECK=1
                    ;;
                *)
                    echo -ne "Wrong parameter\n"
                    exit 6
                    ;;
            esac;;
        *)
            echo -ne "Wrong parameter\n"
            exit 6
            ;;
    esac
done

if [ "${CHECK}" == 1 ]; then
    version_check
fi

clear
source `dirname $0`/backup.conf

spinner()
{
    local pid=$1
    local delay=0.5
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
    echo ""
}

createdirs()
{
    mkdir -p "${BACKUP_DESTINATION}"data
    mkdir -p "${BACKUP_DESTINATION}"log
    mkdir -p "${BACKUP_DESTINATION}"exports
}

checkrole()
{
    echo -ne "\nChecking system role: "
    MODE=$(grep -oP "mode:\s+\K\w+" <<< $(su - "${LOW_USER}" -c "hdbnsutil -sr_state"))
    echo "${MODE}"
    if [ "${MODE}" != "primary" ]; then
    echo -ne "\n*** This system is not primary. Aborting. ***\n\n"
        exit 7
    fi
}

tarfile()
{
    echo -ne "Creating TAR GZIP file...\n"
    tar -czf "${BACKUP_DESTINATION}exports/$3_$2.tar.gz" -C $1 . #&
    #spinner $!
}

deletefile()
{
    echo -ne "Deleting original export..."
    rm -fR $1 #&
    #spinner $!
}

backuphana()
{
    echo -ne "\nStarting HANA instance backup...\n"
    echo -ne "Performing data backup as ${BACKUP_PREFIX}\n"
    #spinner $!

    su - "${LOW_USER}" -c ". ${HANA_PATH}hdbenv.sh"
    su - "${LOW_USER}" -c "hdbsql -U $BACKUP_KEY \"backup data using file ('$BACKUP_PREFIX')\"" #&
}

createhanafile()
{
    echo -ne "Creating TAR GZIP file from ${BACKUP_PREFIX}\n"

    HANA_BACKUP_PATH="${BACKUP_PATH}data/"

    tar -czf "${BACKUP_DESTINATION}"data/${BACKUP_PREFIX}.tar.gz "${HANA_BACKUP_PATH}${BACKUP_PREFIX}"* >/dev/null 2>&1 #&
    #tar -czvf "${BACKUP_DESTINATION}"data/${BACKUP_PREFIX}.tar.gz "${HANA_BACKUP_PATH}${BACKUP_PREFIX}"* >"${BACKUP_DESTINATION}"data/${BACKUP_PREFIX}.log &
    #spinner $!
}

backuplogs()
{
    echo -ne "Creating TAR GZIP file from logs as ${LOG_PREFIX}\n"
    HANA_LOG_BACKUP_PATH="${BACKUP_PATH}log/"
    tar -czf "${BACKUP_DESTINATION}"log/"${LOG_PREFIX}".tar.gz "${HANA_LOG_BACKUP_PATH}"* >/dev/null 2>&1 #&
    #tar -czvf "${BACKUP_DESTINATION}"log/"${LOG_PREFIX}".tar.gz "${HANA_LOG_BACKUP_PATH}"* >"${BACKUP_DESTINATION}"log/"${LOG_PREFIX}".log &
    #spinner $!
}

deleteoldbackups()
{
	if [ "${DELETE_OLD_BACKUPS}" == "yes" ]; then
		echo -ne "Deleting old backups\n"

		HANA_LOG_PATH="${BACKUP_PATH}log/"

		#find ${HANA_LOG_PATH}* -mtime +${RETENTION} -exec rm {} \; &
		SQL_EXE=$(su - ${LOW_USER} -c "hdbsql -U ${BACKUP_KEY} \"SELECT TOP 1 min(to_bigint(BACKUP_ID)) FROM SYS.M_BACKUP_CATALOG where SYS_START_TIME >= ADD_DAYS(CURRENT_TIMESTAMP, -${RETENTION}) and ENTRY_TYPE_NAME = 'complete data backup' and STATE_NAME = 'successful'\"")
		BACKUP_ID=$(echo -e "${SQL_EXE}" | awk 'NR==2')
		SQL_EXE=$(su - ${LOW_USER} -c "hdbsql -U ${BACKUP_KEY} \"BACKUP CATALOG DELETE ALL BEFORE BACKUP_ID $BACKUP_ID COMPLETE\"") #&
		#spinner $!
	else
		echo -ne "Old backups will not be deleted\n"
	fi
	
    if [ "${RECLAIM_LOG_SPACE}" == "yes" ]; then
        echo -ne "Reclaiming un-needed log space\n"
        SQL_EXE=$(su - ${LOW_USER} -c "hdbsql -U ${BACKUP_KEY} \"ALTER SYSTEM RECLAIM LOG\"") #&
        #spinner $!
    fi
}

verifybackup()
{
    echo -ne "Verifying backup integrity for: ${BACKUP_PREFIX}\n\n"
    find "${BACKUP_PATH}data/" -name "${BACKUP_PREFIX}*" -print0 | sort -z | while IFS= read -r -d $'\0' line; do
    #find "${BACKUP_PATH}data/" -name "${BACKUP_NAME}*" -print0 | sort -z | while IFS= read -r -d $'\0' line; do
        SHELL_EXE=$(su - ${LOW_USER} -c "hdbbackupcheck -v ${line}")

        if [ $? == 0 ]; then
            BACKUP_STATUS="OK"
        else
            BACKUP_STATUS="FAILED"
            MAIL_STATUS=1
        fi

        SERVICE_NAME=$(echo "${SHELL_EXE}" | grep "ServiceName" | awk '{print $2}')
        SOURCE_TYPE_NUM=$(echo "${SHELL_EXE}" | grep -m 1 "SrcType" | awk '{print $2}')

        if [ -z ${SERVICE_NAME} ]; then
            SERVICE_NAME="ERROR   "
            SOURCE_TYPE="ERROR   "
        else
            if [ "${SOURCE_TYPE_NUM}" == 4 ]; then
                SOURCE_TYPE="Topology"
            else
                SOURCE_TYPE="Volume"
            fi
        fi

        echo -ne "Service: ${SERVICE_NAME}\t Type: ${SOURCE_TYPE}\t\t Status: ${BACKUP_STATUS}\n"

        if [ "${MAIL_STATUS}" == 1 ]; then
            echo "One or more backup files are corrupted in ${BACKUP_PREFIX}. Please check the backup files and run the Backup Service Tool again." | mail -s "Backup Failed on ${MACHINE_NAME} - ${MACHINE_DESCRIPTION}" "${NOTIFICATION_EMAIL}"
            break
        fi
    done

    echo -ne "\n* Backup integrity verification ended *\n\n"
}

#BEGIN

MACHINE_EXPORT="${MACHINE_IP}_${SAP_HANA_PORT}"
WORK_PATH="${EXPORT_PATH}${MACHINE_EXPORT}/${INSTANCE_NAME}/"

echo "==========================="
echo "HANA Backup Tool Ver. ${VERSION}"
echo "==========================="

echo -e "\nUsing backup export origin path: \t${BACKUP_PATH}"
echo -e "Using backup export destination path: \t${BACKUP_DESTINATION}"
echo -e "Local backup retention: \t\t${RETENTION} day(s)"

if [ "${AS_SERVICE}" != "yes" ]; then
    echo -ne "\nAttention:"
    echo -ne "\n\nThis script tool will delete files in the backup destination path. If you want to continue press any key, otherwise press Ctrl + C"
    read -n 1
fi

if [ "${HA_SUPPORT}" == "yes" ]; then
    checkrole
fi

createdirs

if [ "${PROCESS_EXPORTS}" == "yes" ]; then
	if [ -d "${WORK_PATH}" ]; then
		for DB in "${WORK_PATH}"*; do
			DB_NAME="${DB##*/}"
			if [ "${DB_NAME}" != "_instanceBackup" ]; then
				for BCK in ${DB}/*; do
					BCK_NAME="${BCK##*/}"
					if [ "${BCK_NAME}" != "bck_actual" ]; then
						BCK_DATETIME="${BCK_NAME:4:14}"
						BCK_DATE="${BCK_DATETIME:0:8}"
						BCK_TIME="${BCK_DATETIME:8:6}"
						echo -e "\nProcessing export: (${DB_NAME}) ${BCK_NAME}"
						tarfile "${BCK}" "${BCK_DATETIME}" "${DB_NAME}"
						deletefile "${BCK}"
					fi
				done
			fi
		done
	fi
fi

backuphana

if [ "${VERIFY_BACKUP}" == "yes" ]; then
    verifybackup
fi

if [ "${EXPORT_BACKUP}" == "yes" ]; then
    createhanafile
    backuplogs
fi

deleteoldbackups

FILE_RETENTION=(${RETENTION} - 1)

echo -ne "Processing Data...\n"
file_num=$(ls -1 --file-type "${BACKUP_DESTINATION}"data/ | grep -v '/$' | wc -l)
if [ file_num == 0 ]; then
    find "${BACKUP_DESTINATION}"data/* -mtime +"${FILE_RETENTION}" -exec rm {} \; #&
    #spinner $!
fi

if [ "${PROCESS_EXPORTS}" == "yes" ]; then
	echo -ne "Processing Exports...\n"
	file_num=$(ls -1 --file-type "${BACKUP_DESTINATION}"exports/ | grep -v '/$' | wc -l)
	if [ file_num == 0 ]; then
		find "${BACKUP_DESTINATION}"exports/* -mtime +"${FILE_RETENTION}" -exec rm {} \; #&
		#spinner $!
	fi
fi

echo -ne "Processing Logs...\n"
file_num=$(ls -1 --file-type "${BACKUP_DESTINATION}"log/ | grep -v '/$' | wc -l)
if [ file_num == 0 ]; then
    find "${BACKUP_DESTINATION}"log/* -mtime +"${FILE_RETENTION}" -exec rm {} \; #&
    #spinner $!
fi

echo -ne "\nHANA Backup Tool ended\n"
exit 0

#END