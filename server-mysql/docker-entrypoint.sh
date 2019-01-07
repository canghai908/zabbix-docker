#!/bin/bash

set -eo pipefail

set +e

# Script trace mode
if [ "${DEBUG_MODE}" == "true" ]; then
    set -o xtrace
fi

# Type of Zabbix component
# Possible values: [server, proxy, agent, frontend, java-gateway, appliance]
zbx_type=${ZBX_TYPE}
# Type of Zabbix database
# Possible values: [mysql, postgresql]
zbx_db_type=${ZBX_DB_TYPE}



# Default Zabbix installation name
# Used only by Zabbix web-interface
ZBX_SERVER_NAME=${ZBX_SERVER_NAME:-"Zabbix docker"}
# Default Zabbix server host
ZBX_SERVER_HOST=${ZBX_SERVER_HOST:-"zabbix-server"}
# Default Zabbix server port number
ZBX_SERVER_PORT=${ZBX_SERVER_PORT:-"10051"}


# Default directories
# User 'zabbix' home directory
ZABBIX_USER_HOME_DIR="/var/lib/zabbix"
# Configuration files directory
ZABBIX_ETC_DIR="/etc/zabbix"



escape_spec_char() {
    local var_value=$1

    var_value="${var_value//\\/\\\\}"
    var_value="${var_value//[$'\n']/}"
    var_value="${var_value//\//\\/}"
    var_value="${var_value//./\\.}"
    var_value="${var_value//\*/\\*}"
    var_value="${var_value//^/\\^}"
    var_value="${var_value//\$/\\\$}"
    var_value="${var_value//\&/\\\&}"
    var_value="${var_value//\[/\\[}"
    var_value="${var_value//\]/\\]}"

    echo $var_value
}

update_config_var() {
    local config_path=$1
    local var_name=$2
    local var_value=$3
    local is_multiple=$4

    if [ ! -f "$config_path" ]; then
        echo "**** Configuration file '$config_path' does not exist"
        return
    fi

    echo -n "** Updating '$config_path' parameter \"$var_name\": '$var_value'... "

    # Remove configuration parameter definition in case of unset parameter value
    if [ -z "$var_value" ]; then
        sed -i -e "/^$var_name=/d" "$config_path"
        echo "removed"
        return
    fi

    # Remove value from configuration parameter in case of double quoted parameter value
    if [ "$var_value" == '""' ]; then
        sed -i -e "/^$var_name=/s/=.*/=/" "$config_path"
        echo "undefined"
        return
    fi

    # Use full path to a file for TLS related configuration parameters
    if [[ $var_name =~ ^TLS.*File$ ]]; then
        var_value=$ZABBIX_USER_HOME_DIR/enc/$var_value
    fi

    # Escaping characters in parameter value
    var_value=$(escape_spec_char "$var_value")

    if [ "$(grep -E "^$var_name=" $config_path)" ] && [ "$is_multiple" != "true" ]; then
        sed -i -e "/^$var_name=/s/=.*/=$var_value/" "$config_path"
        echo "updated"
    elif [ "$(grep -Ec "^# $var_name=" $config_path)" -gt 1 ]; then
        sed -i -e  "/^[#;] $var_name=$/i\\$var_name=$var_value" "$config_path"
        echo "added first occurrence"
    else
        sed -i -e "/^[#;] $var_name=/s/.*/&\n$var_name=$var_value/" "$config_path"
        echo "added"
    fi

}

update_config_multiple_var() {
    local config_path=$1
    local var_name=$2
    local var_value=$3

    var_value="${var_value%\"}"
    var_value="${var_value#\"}"

    local IFS=,
    local OPT_LIST=($var_value)

    for value in "${OPT_LIST[@]}"; do
        update_config_var $config_path $var_name $value true
    done
}

# Check prerequisites for MySQL database
check_variables_mysql() {
    local type=$1

    DB_SERVER_HOST=${DB_SERVER_HOST:-"mysql-server"}
    DB_SERVER_PORT=${DB_SERVER_PORT:-"3306"}
    USE_DB_ROOT_USER=false
    CREATE_ZBX_DB_USER=false

    if [ ! -n "${MYSQL_USER}" ] && [ "${MYSQL_RANDOM_ROOT_PASSWORD}" == "true" ]; then
        echo "**** Impossible to use MySQL server because of unknown Zabbix user and random 'root' password"
        exit 1
    fi

    if [ ! -n "${MYSQL_USER}" ] && [ ! -n "${MYSQL_ROOT_PASSWORD}" ] && [ "${MYSQL_ALLOW_EMPTY_PASSWORD}" != "true" ]; then
        echo "*** Impossible to use MySQL server because 'root' password is not defined and it is not empty"
        exit 1
    fi

    if [ "${MYSQL_ALLOW_EMPTY_PASSWORD}" == "true" ] || [ -n "${MYSQL_ROOT_PASSWORD}" ]; then
        USE_DB_ROOT_USER=true
        DB_SERVER_ROOT_USER="root"
        DB_SERVER_ROOT_PASS=${MYSQL_ROOT_PASSWORD:-""}
    fi

    [ -n "${MYSQL_USER}" ] && CREATE_ZBX_DB_USER=true

    # If root password is not specified use provided credentials
    DB_SERVER_ROOT_USER=${DB_SERVER_ROOT_USER:-${MYSQL_USER}}
    [ "${MYSQL_ALLOW_EMPTY_PASSWORD}" == "true" ] || DB_SERVER_ROOT_PASS=${DB_SERVER_ROOT_PASS:-${MYSQL_PASSWORD}}
    DB_SERVER_ZBX_USER=${MYSQL_USER:-"zabbix"}
    DB_SERVER_ZBX_PASS=${MYSQL_PASSWORD:-"zabbix"}

    if [ "$type" == "proxy" ]; then
        DB_SERVER_DBNAME=${MYSQL_DATABASE:-"zabbix_proxy"}
    else
        DB_SERVER_DBNAME=${MYSQL_DATABASE:-"zabbix"}
    fi
}

check_db_connect_mysql() {
    echo "********************"
    echo "* DB_SERVER_HOST: ${DB_SERVER_HOST}"
    echo "* DB_SERVER_PORT: ${DB_SERVER_PORT}"
    echo "* DB_SERVER_DBNAME: ${DB_SERVER_DBNAME}"
    if [ "${USE_DB_ROOT_USER}" == "true" ]; then
        echo "* DB_SERVER_ROOT_USER: ${DB_SERVER_ROOT_USER}"
        echo "* DB_SERVER_ROOT_PASS: ${DB_SERVER_ROOT_PASS}"
    fi
    echo "* DB_SERVER_ZBX_USER: ${DB_SERVER_ZBX_USER}"
    echo "* DB_SERVER_ZBX_PASS: ${DB_SERVER_ZBX_PASS}"
    echo "********************"

    WAIT_TIMEOUT=5

    while [ ! "$(mysqladmin ping -h ${DB_SERVER_HOST} -P ${DB_SERVER_PORT} -u ${DB_SERVER_ROOT_USER} \
                --password="${DB_SERVER_ROOT_PASS}" --silent --connect_timeout=10)" ]; do
        echo "**** MySQL server is not available. Waiting $WAIT_TIMEOUT seconds..."
        sleep $WAIT_TIMEOUT
    done
}

mysql_query() {
    query=$1
    local result=""

    result=$(mysql --silent --skip-column-names -h ${DB_SERVER_HOST} -P ${DB_SERVER_PORT} \
             -u ${DB_SERVER_ROOT_USER} --password="${DB_SERVER_ROOT_PASS}" -e "$query")

    echo $result
}

update_zbx_config() {
    local type=$1
    local db_type=$2

    echo "** Preparing Zabbix $type configuration file"

    ZBX_CONFIG=$ZABBIX_ETC_DIR/zabbix_$type.conf

   
    if [ $type == "server" ]; then
        update_config_var $ZBX_CONFIG "HistoryStorageURL" "${ZBX_HISTORYSTORAGEURL}"
        update_config_var $ZBX_CONFIG "HistoryStorageTypes" "${ZBX_HISTORYSTORAGETYPES}"
        update_config_var $ZBX_CONFIG "HistoryStorageDateIndex" "${ZBX_HISTORYSTORAGEDATEINDEX}"
    fi

    update_config_var $ZBX_CONFIG "DBSocket" "${DB_SERVER_SOCKET}"

    if [ "$type" == "server" ]; then
        update_config_var $ZBX_CONFIG "StartPreprocessors" "${ZBX_STARTPREPROCESSORS}"
        update_config_var $ZBX_CONFIG "StartTimers" "${ZBX_STARTTIMERS}"
        update_config_var $ZBX_CONFIG "StartEscalators" "${ZBX_STARTESCALATORS}"
        update_config_var $ZBX_CONFIG "StartAlerters" "${ZBX_STARTALERTERS}"
    fi

    ZBX_JAVAGATEWAY_ENABLE=${ZBX_JAVAGATEWAY_ENABLE:-"false"}
    if [ "${ZBX_JAVAGATEWAY_ENABLE}" == "true" ]; then
        update_config_var $ZBX_CONFIG "JavaGateway" "${ZBX_JAVAGATEWAY:-"zabbix-java-gateway"}"
        update_config_var $ZBX_CONFIG "JavaGatewayPort" "${ZBX_JAVAGATEWAYPORT}"
        update_config_var $ZBX_CONFIG "StartJavaPollers" "${ZBX_STARTJAVAPOLLERS:-"5"}"
    else
        update_config_var $ZBX_CONFIG "JavaGateway"
        update_config_var $ZBX_CONFIG "JavaGatewayPort"
        update_config_var $ZBX_CONFIG "StartJavaPollers"
    fi

    update_config_var $ZBX_CONFIG "StartVMwareCollectors" "${ZBX_STARTVMWARECOLLECTORS}"
    update_config_var $ZBX_CONFIG "VMwareFrequency" "${ZBX_VMWAREFREQUENCY}"
    update_config_var $ZBX_CONFIG "VMwarePerfFrequency" "${ZBX_VMWAREPERFFREQUENCY}"
    update_config_var $ZBX_CONFIG "VMwareCacheSize" "${ZBX_VMWARECACHESIZE}"
    update_config_var $ZBX_CONFIG "VMwareTimeout" "${ZBX_VMWARETIMEOUT}"

    update_config_var $ZBX_CONFIG "SNMPTrapperFile"
    update_config_var $ZBX_CONFIG "StartSNMPTrapper"

    update_config_var $ZBX_CONFIG "HousekeepingFrequency" "${ZBX_HOUSEKEEPINGFREQUENCY}"
    if [ "$type" == "server" ]; then
        update_config_var $ZBX_CONFIG "MaxHousekeeperDelete" "${ZBX_MAXHOUSEKEEPERDELETE}"
        update_config_var $ZBX_CONFIG "SenderFrequency" "${ZBX_SENDERFREQUENCY}"
    fi

    update_config_var $ZBX_CONFIG "CacheSize" "${ZBX_CACHESIZE}"

    if [ "$type" == "server" ]; then
        update_config_var $ZBX_CONFIG "CacheUpdateFrequency" "${ZBX_CACHEUPDATEFREQUENCY}"
    fi

    update_config_var $ZBX_CONFIG "StartDBSyncers" "${ZBX_STARTDBSYNCERS}"
    update_config_var $ZBX_CONFIG "HistoryCacheSize" "${ZBX_HISTORYCACHESIZE}"
    update_config_var $ZBX_CONFIG "HistoryIndexCacheSize" "${ZBX_HISTORYINDEXCACHESIZE}"

    if [ "$type" == "server" ]; then 
        update_config_var $ZBX_CONFIG "TrendCacheSize" "${ZBX_TRENDCACHESIZE}"
        update_config_var $ZBX_CONFIG "ValueCacheSize" "${ZBX_VALUECACHESIZE}"
    fi

    update_config_var $ZBX_CONFIG "Timeout" "${ZBX_TIMEOUT}"
    update_config_var $ZBX_CONFIG "TrapperTimeout" "${ZBX_TRAPPERIMEOUT}"
    update_config_var $ZBX_CONFIG "UnreachablePeriod" "${ZBX_UNREACHABLEPERIOD}"
    update_config_var $ZBX_CONFIG "UnavailableDelay" "${ZBX_UNAVAILABLEDELAY}"
    update_config_var $ZBX_CONFIG "UnreachableDelay" "${ZBX_UNREACHABLEDELAY}"

    update_config_var $ZBX_CONFIG "AlertScriptsPath" "/usr/lib/zabbix/alertscripts"
    update_config_var $ZBX_CONFIG "ExternalScripts" "/usr/lib/zabbix/externalscripts"

    # Possible few fping locations
    if [ -f "/usr/bin/fping" ]; then
        update_config_var $ZBX_CONFIG "FpingLocation" "/usr/bin/fping"
    else
        update_config_var $ZBX_CONFIG "FpingLocation" "/usr/sbin/fping"
    fi
    if [ -f "/usr/bin/fping6" ]; then
        update_config_var $ZBX_CONFIG "Fping6Location" "/usr/bin/fping6"
    else
        update_config_var $ZBX_CONFIG "Fping6Location" "/usr/sbin/fping6"
    fi

    update_config_var $ZBX_CONFIG "SSHKeyLocation" "$ZABBIX_USER_HOME_DIR/ssh_keys"
    update_config_var $ZBX_CONFIG "LogSlowQueries" "${ZBX_LOGSLOWQUERIES}"

    if [ "$type" == "server" ]; then 
        update_config_var $ZBX_CONFIG "StartProxyPollers" "${ZBX_STARTPROXYPOLLERS}"
        update_config_var $ZBX_CONFIG "ProxyConfigFrequency" "${ZBX_PROXYCONFIGFREQUENCY}"
        update_config_var $ZBX_CONFIG "ProxyDataFrequency" "${ZBX_PROXYDATAFREQUENCY}"
    fi

    update_config_var $ZBX_CONFIG "SSLCertLocation" "$ZABBIX_USER_HOME_DIR/ssl/certs/"
    update_config_var $ZBX_CONFIG "SSLKeyLocation" "$ZABBIX_USER_HOME_DIR/ssl/keys/"
    update_config_var $ZBX_CONFIG "SSLCALocation" "$ZABBIX_USER_HOME_DIR/ssl/ssl_ca/"
    update_config_var $ZBX_CONFIG "LoadModulePath" "$ZABBIX_USER_HOME_DIR/modules/"
    update_config_multiple_var $ZBX_CONFIG "LoadModule" "${ZBX_LOADMODULE}"

}

prepare_server() {
    local db_type=$1

    echo "** Preparing Zabbix server"

    check_variables_$db_type "server"
    check_db_connect_$db_type
    update_zbx_config "server" "$db_type"
}

#################################################

if [ ! -n "$zbx_type" ]; then
    echo "**** Type of Zabbix component is not specified"
    exit 1
elif [ "$zbx_type" == "dev" ]; then
    echo "** Deploying Zabbix installation from SVN"
else
    if [ ! -n "$zbx_db_type" ]; then
        echo "**** Database type of Zabbix $zbx_type is not specified"
        exit 1
    fi

    if [ "$zbx_db_type" != "none" ]; then
        if [ "$zbx_opt_type" != "none" ]; then
            echo "** Deploying Zabbix $zbx_type ($zbx_opt_type) with $zbx_db_type database"
        else
            echo "** Deploying Zabbix $zbx_type with $zbx_db_type database"
        fi
    else
        echo "** Deploying Zabbix $zbx_type"
    fi
fi

[ "$zbx_type" == "server" ] && prepare_server $zbx_db_type
[ "${ZBX_ADD_SERVER}" == "true" ] && prepare_server ${ZBX_MAIN_DB}

echo "########################################################"

if [ "$1" != "" ]; then
    echo "** Executing '$@'"
    exec "$@"
elif [ "$zbx_type" == "server" ]; then
    echo "** Starting Zabbix server"
    exec su zabbix -s "/bin/bash" -c "/usr/sbin/zabbix_server --foreground -c /etc/zabbix/zabbix_server.conf"
else
    echo "Unknown instructions. Exiting..."
    exit 1
fi

#################################################