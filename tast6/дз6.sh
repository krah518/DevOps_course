#!/bin/bash
#Скрипт для автоматизації озгортання wordpres з json конфіга
#тествувася тільки на дебіані
#запускати від рута, або з sudo

#Перевірка OS, якщо не дебіан виходим з скрипта
OS_NAME=$(lsb_release -d | grep -i Debian)

if [ -n "$OS_NAME" ];then
	echo "check os - ok"
else
	echo "Not Debian"
	echo "check os - failed"
	exit 1
fi

#Перевірка встановлених пакетів, якщо відсутні то встановлюєм, в разі помилки завершуєм скрипт
echo "check requirements"

APPS_LIST=(apache2 default-mysql-server php php-mysql wget rsync curl jq)

for aps in ${APPS_LIST[*]}
do
	aps_status=$(dpkg -s $aps | grep Status);
	if [[ "$aps_status" = "Status: install ok installed" ]]; then
		echo "$aps is already installed"
	else
		apt-get install $aps -y
		if [ $? -eq 0 ]; then
			echo "$aps is installed"
		else
			echo "error, $aps failed to install"
			exit 1
		fi
	fi
done

# Парсим конфіг wp з json
echo "parsing json start"

#Перевірка чи існує файл і чи є права на читання
JSON_FILE="wordpres.json"

if ! [[ -r $JSON_FILE ]]; then
	echo "the $JSON_FILE does not exist or is not readable"
	exit 1
fi

#Лічильник помилок
error_counter=0

SITENAME=($(jq -re '.sitename[]' $JSON_FILE ))
error_counter=$(($error_counter+$?))

SITEROOT_DIR=($(jq -re '.siteroot_dir[]' $JSON_FILE ))
error_counter=$(($error_counter+$?))

DB_NAME=($(jq -re '.db.name[]' $JSON_FILE ))
error_counter=$(($error_counter+$?))

DB_USERNAME=($(jq -re '.db.username[]' $JSON_FILE ))
error_counter=$(($error_counter+$?))

DB_PASSWORD=($(jq -re '.db.password[]' $JSON_FILE ))
error_counter=$(($error_counter+$?))

BK_DIR=$(jq -re '.backup.bk_dir' $JSON_FILE )
error_counter=$(($error_counter+$?))

BK_FREQUENCY=$(jq -re '.backup.frequency' $JSON_FILE )
error_counter=$(($error_counter+$?))

BK_TTL=$(jq -re '.backup.ttl' $JSON_FILE )
error_counter=$(($error_counter+$?))


#Перевірка чи були помилки
if [ $error_counter -eq 0 ]; then
	echo "parsing json - ok"
else
	echo "parsing json - failed"
	exit 1
fi

#Створення VirtualHost
i=0
while true
do
	if  [[ -n ${SITENAME[$i]}  ]]; then
		if [[ -d ${SITEROOT_DIR[$i]}/${SITENAME[$i]} ]]; then
			echo "dir ${SITEROOT_DIR[$i]}/${SITENAME[$i]} already exists"
		else
			sudo mkdir -p ${SITEROOT_DIR[$i]}/${SITENAME[$i]}
			if ! [ $? -eq 0 ]; then
				echo "error create ${SITEROOT_DIR[$i]}/${SITENAME[$i]}"
				exit 1
			fi
		fi
		if [[ -w /etc/apache2/sites-available/${SITENAME[$i]}.conf ]]; then
			echo "file /etc/apache2/sites-available/${SITENAME[$i]}.conf already exists"
		else
			sudo touch /etc/apache2/sites-available/${SITENAME[$i]}.conf
			if ! [ $? -eq 0 ]; then
				echo "error create file /etc/apache2/sites-available/${SITENAME[$i]}.conf"
				exit 1
			fi			
			sudo echo "<VirtualHost *:80>
				ServerName ${SITENAME[$i]}
				ServerAlias www.${SITENAME[$i]}
				ServerAdmin webmaster@localhost
				DocumentRoot ${SITEROOT_DIR[$i]}/${SITENAME[$i]}
				<Directory ${SITEROOT_DIR[$i]}/${SITENAME[$i]}>
				Options -Indexes +FollowSymLinks
				AllowOverride All
				</Directory>
				ErrorLog ${APACHE_LOG_DIR}/${SITENAME[$i]}-error.log
				CustomLog ${APACHE_LOG_DIR}/${SITENAME[$i]}-access.log combined
				</VirtualHost>" > /etc/apache2/sites-available/${SITENAME[$i]}.conf
			
			if ! [ $? -eq 0 ]; then
				echo "error write conf to /etc/apache2/sites-available/${SITENAME[$i]}.conf"
				exit 1
			fi	
			
		fi
		i=$(($i+1))
	else
		break
	fi	
done

sudo a2enmod php*
if [ $? -eq 0 ]; then
	echo "apache2 php* mod enable - ok"
	sudo systemctl restart apache2
else
	echo "apache2 php* mod enable - failed"
	exit 1
fi

#Включення сайту
i=0
while true
do
	if  [[ -n ${SITENAME[$i]}  ]]; then
		sudo a2ensite ${SITENAME[$i]}
		i=$(($i+1))
	else
		break
	fi	
done

sudo systemctl reload apache2


#Перевірка чи запущений апач на 80 порту
if ss -tulpn | grep -P ":80|:443" | grep -q apache2; then
	echo "apache2 runing"
elif ss -tulpn | grep -q apache2; then
	echo "apache2 running on a non-standard port"
else
	echo "apache2 not runing"
fi

#Перевірка чи запущена база
if ss -tulpn | grep -q mysql; then
	echo "mysql runing"
else
	echo "mysql not runing"
fi
#Додавання апача в автозапуск
sudo systemctl enable apache2
if [ $? -eq 0 ]; then
	echo "apache2 add autostart - ok"
else
	echo "apache2 add autostart - failed"
fi
#Додавання BD в автозапуск
sudo systemctl enable mysql
if [ $? -eq 0 ]; then
	echo "mysql add autostart - ok"
else
	echo "mysql add autostart - failed"
fi

#Створення бази, і користувача
i=0
while true
do
	if  [[ -n ${SITENAME[$i]}  ]]; then
		echo "CREATE DATABASE ${DB_NAME[$i]} DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;" | sudo mysql -u root
		if ! [ $? -eq 0 ]; then
			echo "error create database"
		fi
		echo "GRANT ALL ON ${DB_NAME[$i]}.* TO '${DB_USERNAME[$i]}'@'localhost' IDENTIFIED BY '${DB_PASSWORD[$i]}';" | sudo mysql -u root
		if ! [ $? -eq 0 ]; then
			echo "error create user"
		fi
		echo "FLUSH PRIVILEGES;" | sudo mysql -u root
		if ! [ $? -eq 0 ]; then
			echo "error flush privileges"
		fi
		i=$[ $i + 1 ]
	else
		break
	fi	
done

cd /tmp

if [[ -f latest-ru_RU.tar.gz ]]; then
	echo "latest-ru_RU.tar.gz - already exists"
else
	wget https://ru.wordpress.org/latest-ru_RU.tar.gz
	if ! [ $? -eq 0 ]; then
		echo "download wordpress - failed"
		exit 1
	fi
fi

tar  -xzvf latest-ru_RU.tar.gz
if [[ -d /tmp/wordpress/ ]]; then
	echo "unzip file - ok"
else
	echo "unzip file - failed"
	exit 1
fi

i=0
while true
do
	if  [[ -n ${SITENAME[$i]}  ]]; then

		sudo cp -a /tmp/wordpress/. ${SITEROOT_DIR[$i]}/${SITENAME[$i]}

		cd ${SITEROOT_DIR[$i]}/${SITENAME[$i]}
		echo "cd ${SITEROOT_DIR[$i]}/${SITENAME[$i]}"
		sudo cp wp-config-sample.php wp-config.php
		echo "cp wp-config-sample.php wp-config.php"

		sed -i "s/database_name_here/${DB_NAME[$i]}/;s/username_here/${DB_USERNAME[$i]}/;s/password_here/${DB_PASSWORD[$i]}/" wp-config.php
		echo "replace DB date in wp-config.php"
		i=$[ $i + 1 ]
	else
		break
	fi
done

sudo mkdir /etc/scripts
sudo mkdir /etc/scripts
sudo touch /etc/scripts/backup.sh
sudo chmod +x /etc/scripts/backup.sh
sudo mkdir -p $BK_DIR/web-server
sudo mkdir -p $BK_DIR/db
sudo mkdir -p $BK_DIR/logs/apache2

echo "
	#!/bin/bash

	DATE=\$(date +%Y-%m-%d)

	rsync -az /etc/apache2/ $BK_DIR/web-server/apache2-\$DATE" > /etc/scripts/backup.sh

i=0
while true
do
	if  [[ -n ${SITENAME[$i]}  ]]; then
		echo "
		mysqldump -u ${DB_USERNAME[$i]} -p${DB_PASSWORD[$i]} ${DB_NAME[$i]} > $BK_DIR/db/${SITENAME[$i]}.${DB_NAME[$i]}-\$DATE.sql
		tar -czf $BK_DIR/logs/apache2/${SITENAME[$i]}-logs-\$DATE.tar.gz /log/apache2/${SITENAME[$i]}-error.log /log/apache2/${SITENAME[$i]}-access.log
		" >> /etc/scripts/backup.sh
		i=$[ $i + 1 ]
	else
		break
	fi
done

echo "
	find $BK_DIR/web-server/ -type d -ctime +$(($BK_TTL*$BK_FREQUENCY)) -exec rm -rf {} \;
	find $BK_DIR/db/ -type f -ctime +$(($BK_TTL*$BK_FREQUENCY)) -exec rm -rf {} \;
	find $BK_DIR/logs/apache2/ -type f -ctime +$(($BK_TTL*$BK_FREQUENCY)) -exec rm -rf {} \;
	" >> /etc/scripts/backup.sh
	
echo -e "
# BACKUP
0 6 */$BK_FREQUENCY * * root /etc/scripts/backup.sh >/dev/null 2>&1\n
" >> /etc/crontab

