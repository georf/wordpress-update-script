#!/bin/bash
 
# WordPress core upgrade script (plugins will still have to be updated separately).
 
# (c) Copyright (c) 2012, Anthony Bouch (tony@58bits.com). All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
 
# Based on a script written by Liz Quilty ( liz@rimuhosting.com )
# Run as root
# sudo sh wp-upgrade.sh
 
# version 1.4 - refactored to use functions, curl and tar and removed WordPress MU 
# support (AB).
# version 1.3 - keeping the permissions so that the web user can write to things OK (LQ)
# version 1.2 - Patched for better portability by http://twitter.com/valthonis (LQ)
 
#Set exit on any error.
set -e
 
# Source our configuration file.
# NOTE - this is easily broken by path discoverable script sources, symlinks etc. 
# So be sure to only call the upgrade script with this in mind.
# http://mywiki.wooledge.org/BashFAQ/028
script_source=$([[ $0 == /* ]] && echo "$0" || echo "${PWD}/${0#./}")
config_source=${script_source%".sh"}".conf"
source $config_source
 
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
#
# FUNCTION: get_owner_group
# Get the ownership and group values for a directory or a filename 
# and returns a value that can be used for chown.
# Params: $1 = fully qualified directory or filename.
# NOTE: May not work for symlinked directories.
#
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
get_owner_group() {
  if [ -d "$1" ]; then
    echo $(ls -lah $1 |  awk '{print $3,$4}'| sed -n -e 's/\ /:/' -e '2p')
  elif [ -f "$1" ]; then
    echo $(ls -lah $1 |  awk '{print $3,$4}'| sed 's/\ /:/')
  else
    echo "get_owner_group requires a valid directory or filename as an argument." >&2
    exit 1
  fi
}
 
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
#
# FUNCTION: get_wp_root
# Get the installation directory for WordPress
# Params: $1 = fully qualified filename for version.php
#
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
get_wp_root() {
  if [ -z "$1" -o ! -s "$1" ]; then
    echo "get_wp_root requires a valid filename as an argument." >&2
    exit 1
  fi
  echo "$1" | sed s@wp-includes/version.php@@
}
 
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
#
# FUNCTION: get_installed_version
# Get the installed version of WordPress
# Params: $1 = fully qualified filename for version.php
#
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
get_installed_version() {
  if [ -z "$1" -o ! -s "$1" ]; then
    echo "get_installed_version requires a valid filename as an argument." >&2
    exit 1
  fi
  # Fixed for version 3.5 (which is not 5 characters long)
  # echo grep wp_version "$1" | grep -v global | cut -c16-20
  echo $(grep '^\$wp_version' "$1" | cut -d "'" -f 2)
}
 
 
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
#
# FUNCTION: get_database_settings
# Get the database settings for this installation
# Params: $1 = the root directory of the WordPress installation
#
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
get_database_settings() {
  if [ -z "$1" -o ! -d "$1" ]; then
    echo "get_database_settings requires a valid directory as an argument." >&2
    exit 1
  fi
 
  db_name=$(grep DB_NAME "${1}/wp-config.php" |cut -d "'" -f 4)
  db_user=$(grep DB_USER "${1}/wp-config.php" | cut -d "'" -f 4)
  db_pass=$(grep DB_PASSWORD "${1}/wp-config.php" | cut -d "'" -f 4)
  table_prefix=$(grep '$table_prefix' "${1}/wp-config.php" | cut -d "'" -f 2) 
 
  echo $db_name $db_user $db_pass $table_prefix
}
 
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
#
# FUNCTION: get_latest_wp
# Download the latest version of WordPress
# Params: None
# Notes: Needs better error handling
#
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
get_latest_wp() {
  mkdir -p $WP_SOURCE_DIR
  cd $WP_SOURCE_DIR
  echo 'Getting latest version of WordPress... (removing previous download if any).'
  rm -rf ${WP_SOURCE_DIR}/latest.tar.gz
  rm -rf ${WP_SOURCE_DIR}/wordpress
  curl -O $WP_URL && tar -xmzf latest.tar.gz && chown -R $(get_owner_group $WP_SOURCE_DIR) ${WP_SOURCE_DIR}/wordpress/
  if [ $? -ne 0 ]; then
    echo "Download of the latest version of WordPress failed."
    exit 1
  fi
  cd - > /dev/null
  echo 'Done.'
}
 
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
#
# FUNCTION: do_upgrade
# Perform the core WordPress upgrade on a discovered WordPress installation
# Params: $1 = target directory
#
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
do_upgrade() {
  if [ -z "$1" -o ! -d "$1" ]; then
    echo "do_upgrade requires a valid directory as an argument."
    exit 1
  fi
 
  wp_root=$1
  echo "Upgrading $wp_root"
 
  settings=$(get_database_settings $wp_root)
 
  db_name=$(echo "$settings" | awk '{print $1}')
  db_user=$(echo "$settings" | awk '{print $2}')
  db_pass=$(echo "$settings" | awk '{print $3}')
  table_prefix=$(echo "$settings" | awk '{print $4}')
 
  echo Checking connection to the database.
  db_test=$($MYSQL_ADMIN -u${db_user} -p${db_pass} ping)
 
  if [ "$db_test" == "mysqld is alive" ]; then
    echo Database connects fine.
    # 1. Get clean url and sitename for site.
    siteurl=$(echo SELECT option_value FROM ${table_prefix}options WHERE option_name=\'siteurl\' LIMIT 1 | $MYSQL -u ${db_user} -p${db_pass} ${db_name} | sed s/option_value//)
    echo Site URL is $siteurl
    clean_url=$(echo $siteurl| sed s@http://@@g)
    sitename=$(echo SELECT option_value FROM ${table_prefix}options WHERE option_name=\'blogname\' LIMIT 1 | $MYSQL -u ${db_user} -p${db_pass} ${db_name} | sed s/option_value//)
    echo Site name is $sitename
    clean_sitename=${sitename///}
 
    # 2. Backup the database for the site.
    echo Making backup at /var/wp_upgrade/${clean_sitename}.sql and /var/wp_upgrade/${clean_sitename}.tar.gz \(you can delete these later\)
    mkdir -p /var/wp_upgrade/${clean_sitename}
    $MYSQL_DUMP -u ${db_user} -p${db_pass} ${db_name} > /var/wp_upgrade/${clean_sitename}/${clean_sitename}.sql &&
 
    # 3. Take a complete backup of the WordPress site directory.
    tar -czf /var/wp_upgrade/${clean_sitename}/${clean_sitename}.tar.gz ${wp_root}
 
    # 4. Copying core files into site, getting the original owner permissions
    orig_perm=$(get_owner_group ${wp_root}/wp-content)
    alias cp=cp #some distros have cp aliased to cp -i which asks before each overwrite
    echo "Setting up maintenance mode ..."
    touch $wp_root/.mainenance
    echo Copying files over ...
 
    # http://codex.wordpress.org/Updating_WordPress
    rm -r ${wp_root}/wp-includes
    rm -r ${wp_root}/wp-admin
    cp -a ${WP_SOURCE_DIR}/wordpress/* $wp_root/
 
    echo Changing ownership back to $orig_perm
    chown -R $orig_perm $wp_root
 
    #echo You may need to go to $siteurl/wp-admin/upgrade.php to complete the upgrade
    echo Triggering database upgrade with curl --silent $siteurl/wp-admin/upgrade.php?step=1 > /dev/null 2>&1
    curl --silent $siteurl/wp-admin/upgrade.php?step=1 >/dev/null 2>&1
 
    echo "Going back to normal mode..."
    rm $wp_root/.mainenance
    echo "Upgrade at $wp_root complete."
  else
    echo "Unable to connect to the database for this site. Please upgrade manually."   
  fi
}
 
###~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~##
# Let's start...
if [ $(whoami) != "root" ]
  then
  echo "You need to run this script as root (preferably via sudo)."
  exit 1
fi
 
# Download and extract the latest version of WordPress
get_latest_wp
 
# Find all of our target WordPress installations
wplist=$(find $FIND_DIR -wholename "*wp-includes/version.php")
 
for file in $wplist ; do
  wp_root=$(get_wp_root $file)
  installed_ver=$(get_installed_version $file)
 
  if [ ${installed_ver} !=  ${WP_CURRENT_VER} ];then
    echo "You have version $installed_ver located at $wp_root that needs upgrading to $WP_CURRENT_VER"
    echo -n "Would you like to upgrade it? [y/N] "
    read ans
    if [ ! -z "$ans" -a "$ans" == "y" ];then #Fixed: Default non key entry now correctly equivalent to No.
      do_upgrade $wp_root
    else
      echo "Skipping ${wp_root}."
    fi
  else
    echo "Located WordPress at $wp_root. This installation is up-to-date."
  fi
done