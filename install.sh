#!/bin/bash

NGINX_AVAILABLE='/etc/nginx/sites-available'
NGINX_ENABLED='/etc/nginx/sites-enabled'
NGINX_ROOT='/var/www'
NGINX_TEMPLATE="`dirname $0`/nginx.template.conf"
WP_TEMPLATE="`dirname $0`/wp.config.template.php"
ETC_HOSTS='/etc/hosts'
PACKAGES="unzip php5-common php5-mysql php5-xmlrpc php5-cgi php5-curl php5-gd php5-cli php5-fpm php-apc php-pear php5-dev php5-imap php5-mcrypt mysql-server mysql-client nginx"


function warning()
{
    echo "$*" >&2
}

function error()
{
    echo "$*" >&2
    exit 1
}

function yesno()
{
    local ok=0
    local ans
    while [[ ok -eq 0 ]]
    do
        read -p "$*" ans
        ans=$(tr '[:upper:]' '[:lower:]' <<<$ans)
        if [[ $ans == 'y' || $ans == 'yes' || $ans == 'n' || $ans == 'no' ]]; then
            ok=1
        fi
    done
    [[ $ans == 'y' || $ans == 'yes' ]]
}

function installppa()
{
    echo "Installing PPA $1."
    add-apt-repository $1
    if [[ $? -ne 0 ]]; then
        error "Error adding PPA."
    fi
}

function installpackage()
{
    local package=$1
    dpkg -s $package > /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo "$package present..."
    else
        echo "$package not present. installing..."
        apt-get -y install $package
        if [[ $? -ne 0 ]]; then
            error "error installing $package. exiting..."
        fi
        echo "$package installed..."
    fi
}

function installpackages()
{
    for package in $1
    do
        installpackage $package
    done 
}

function upgradephp()
{
    PHP_VER=`php5 -r "echo PHP_VERSION_ID;"`
    if (( PHP_VER < 50400 )); then
        echo "Upgrading packages."
        apt-get -y upgrade
    fi
    PHP_VER=`php5 -r "echo PHP_VERSION_ID;"`
    if (( PHP_VER < 50400 )); then
        error "Unable to upgrade php5."
    fi
}

function disableapache()
{
    echo "Checking for apache2."
    ps ax | grep /usr/sbin/apache2 | grep -v grep > /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        yesno "apache2 running would you like to stop it? (yes/no) : "
        if [[ $? -eq 0 ]]; then
            echo "Stoping apache2."
            service apache2 stop > /dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                error "Error stopping apache2."
            fi
        fi
        yesno "do you want to remove apache2 from startup? (yes/no) : "
        if [[ $? -eq 0 ]]; then
            echo "Removing apache2 from startup."
            update-rc.d -f apache2 remove > /dev/null 2>&1
        fi
    fi
}

function startservices()
{
    echo "(Re)starting nginx service."
    service nginx restart > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        error "Failed to (re)start nginx service."
    fi
    echo "(Re)starting php-fpm service."
    service php5-fpm restart > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        error "Failed to (re)start php-fpm service."
    fi
}

function addhost()
{
    echo Adding Host $2 to /etc/hosts
    grep -qE "^$1.*[[:space:]]+$2[[:space:]]*" $ETC_HOSTS
    if [[ $? -ne 0 ]]; then
        sed -i "s/^\($1.*\)$/\1 $2/" $ETC_HOSTS
    fi
}

function createvirtualhost()
{
    local HOSTNAME=$1
    local NGINX_CONFIG=$NGINX_AVAILABLE/$HOSTNAME

    if [[ -f $NGINX_CONFIG ]]; then
        yesno "Virtual Host $HOSTNAME already exists, delete previous? (Yes/No) : "
        if [[ $? -ne 0 ]]; then
            error "Aborting..."
        fi
        rm -rf $NGINX_ROOT/$HOSTNAME
        rm $NGINX_ENABLED/$HOSTNAME
        rm $NGINX_AVAILABLE/$HOSTNAME
    fi

    echo Creating Virtual Host $HOSTNAME
    
    #Create config
    cp $NGINX_TEMPLATE $NGINX_CONFIG
    if [[ $? -ne 0 ]]; then
        error "Error copying nginx config."
    fi
    sed -i "s/HOSTNAME/$HOSTNAME/g" $NGINX_CONFIG
    if [[ $? -ne 0 ]]; then
        error "Error writting config parameter."
    fi
    sed -i "s!SITEROOT!$NGINX_ROOT/$HOSTNAME!g" $NGINX_CONFIG
    if [[ $? -ne 0 ]]; then
        error "Error writting config parameter."
    fi
    chmod 600 $NGINX_CONFIG
    if [[ $? -ne 0 ]]; then
        error "Error setting file permission."
    fi

    #Setup root
    mkdir $NGINX_ROOT/$HOSTNAME
    if [[ $? -ne 0 ]]; then
        error "Error creating siteroot."
    fi

    #Enable site
    ln -s $NGINX_CONFIG $NGINX_ENABLED/$HOSTNAME
    if [[ $? -ne 0 ]]; then
        error "Error enabling virtual host."
    fi

    #reload Nginx
    /etc/init.d/nginx reload
}

function createdatabase()
{
    local muser
    local mpass
    read -p "Enter MySQL root username : " muser
    read -p "Enter MySQL root password : " mpass
    #Check for authentication
    mysqladmin -u "$muser" --password="$mpass" status > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        error "MySQL Authentication Failed... "
    fi
    #Create database
    mysqladmin -u "$muser" --password="$mpass" create "$1" > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        error "MySQL Create Database Failed... "
    fi
    echo "Database $1 created."
    mysql -u "$muser" --password="$mpass" -e "GRANT ALL ON \`$1\`.* TO \`$2\`@localhost IDENTIFIED BY '${3}';"
    if [[ $? -ne 0 ]]; then
        error "MySQL Grant Failed... "
    fi
    echo "User $2 granted all access to database $1."
    mysql -u "$muser" --password="$mpass" -e "FLUSH PRIVILEGES;"
    if [[ $? -ne 0 ]]; then
        error "MySQL Flush Privileges... "
    fi
    echo "MySQL Privileges Reloaded."
}

function installwordpress()
{
    #Download
    wget http://wordpress.org/latest.zip
    if [[ $? -ne 0 ]]; then
        error "Unable to download wordpress."
    fi
    #Extract
    unzip latest.zip -d ./
    if [[ $? -ne 0 ]]; then
        error "Error extracting wordpress zip."
    fi
    #Copy
    mv -f ./wordpress/* $1
    if [[ $? -ne 0 ]]; then
        error "Error copying wordpress files."
    fi
    #Remove temp
    rm -rf ./wordpress
    if [[ $? -ne 0 ]]; then
        error "Error removing temp dir."
    fi
    rm latest.zip
    if [[ $? -ne 0 ]]; then
        error "Error deleting temp file."
    fi
}

function wpconfig()
{
    local WP_CONFIG=$1/wp-config.php
    echo "Copying WP config."
    cp $WP_TEMPLATE $WP_CONFIG
    if [[ $? -ne 0 ]]; then
        error "Error copying WordPress config."
    fi
    echo "Writting config parameters."
    sed -i "s/database_name_here/$2/g" $WP_CONFIG
    if [[ $? -ne 0 ]]; then
        error "Error writting config parameter."
    fi
    sed -i "s/username_here/$3/g" $WP_CONFIG
    if [[ $? -ne 0 ]]; then
        error "Error writting config parameter."
    fi
    sed -i "s/password_here/$4/g" $WP_CONFIG
    if [[ $? -ne 0 ]]; then
        error "Error writting config parameter."
    fi
    wget https://api.wordpress.org/secret-key/1.1/salt/
    if [[ $? -ne 0 ]]; then
        error "Error downloading wordpress salts."
    fi
    sed -i -e '\_#SALTS_{
        r index.html
        d
    }' $WP_CONFIG
    if [[ $? -ne 0 ]]; then
        error "Error pasting wordpress salts."
    fi
    rm index.html
    if [[ $? -ne 0 ]]; then
        error "Error deleting temp file, index.html."
    fi
}

if [[ $EUID -ne 0 ]]; then
    error "Please run as root"
fi

installpackage "python-software-properties"

installppa ppa:ondrej/php5
installppa ppa:nginx/stable

installpackages "$PACKAGES"

upgradephp

read -p 'Enter Domain : ' DOMAIN

SQL_PASS=`openssl passwd "$RANDOM"`

createvirtualhost $DOMAIN
addhost 127.0.0.1 $DOMAIN
installwordpress $NGINX_ROOT/$DOMAIN
createdatabase "${DOMAIN}_db" "${DOMAIN}_user" "$SQL_PASS"
wpconfig $NGINX_ROOT/$DOMAIN "${DOMAIN}_db" "${DOMAIN}_user" "$SQL_PASS"

disableapache
startservices

echo "Installation successful. Please navigate to http://$DOMAIN/ in your browser"
