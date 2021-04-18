#!/bin/bash

##异常处理
function error_exit {
  echo "$1" 1>&2
  exit 1
}
read -p "请输入Nextcloud的域名(不要添加https/https): " SERVERNAME
SERVERNAME=${SERVERNAME:-www.nextcloud.com}
read -p "是否自动申请证书（1-申请；2-我有证书）:  " GETCERT

if [ "$GETCERT" = "1" ]; then
	read -p "服务器是否处于公网（1-是；2-否）:  " INTERNET
	if [ "$INTERNET" = "2" ]; then
		read -p "请输入Ali_Key： " ALI_KEY
		export Ali_Key=$ALI_KEY
		read -p "请输入Ali_Secret： " ALI_SECRET;
		export Ali_Secret=$ALI_SECRET
	fi
elif [ "$GETCERT" = "2" ]; then
	echo -p "请将证书文件保存在 /etc/ssl/website/域名 目录下，并重命令为：certificate.crt private.key ca_bundle.crt"
	read -p "设置完毕请按回车继续" READY
else
	echo -p "输入错误，程序退出"
	exit
fi

PHP_V="7.4"
NC_DOWNLOAD_URL="https://download.nextcloud.com/server/releases/nextcloud-21.0.1.zip"
MYSQL_ROOT_PASSWD=$(head -c 100 /dev/urandom | tr -dc a-z0-9A-Z |head -c 8)
NC_ADMIN=${NC_ADMIN:-admin}
NC_ADMIN_PASSWD=$(head -c 100 /dev/urandom | tr -dc a-z0-9A-Z |head -c 8)
NC_DBNAME=${NC_DBNAME:-nextcloud}
NC_DATA_DIR="/mnt/ncdata"

##更新源
mv /etc/apt/sources.list /etc/apt/sources.list.bak  || error_exit "备份sources.list文件错误"
cat > /etc/apt/sources.list <<EOF
# 默认注释了源码镜像以提高 apt update 速度，如有需要可自行取消注释
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal-updates main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal-backports main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal-security main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal-security main restricted universe multiverse
EOF
sudo apt-get -qq update || error_exit "apt-get update 错误"

##安装软件
sudo apt-get -qq install -y unzip || error_exit "安装unzip错误"
sudo apt-get -qq install -y apache2 || error_exit "安装apache2错误"
sudo systemctl start apache2 || error_exit "启动apache2错误"
sudo apt-get -qq install -y php${PHP_V}-fpm php${PHP_V}-{bcmath,bz2,intl,gd,mbstring,mysql,zip,curl,json,opcache,dba,xml,odbc,gmp} || error_exit "安装php及其扩展错误"
sudo apt-get -qq install -y php-imagick php-redis php-apcu libmagickcore-6.q16-6-extra || error_exit "安装php扩展错误"
sudo a2enmod proxy_fcgi setenvif || error_exit "启用proxy_fcgi和setenvif错误"
sudo a2enconf php${PHP_V}-fpm || error_exit "使用php-fpm错误"
a2dismod mpm_prefork mpm_worker || error_exit "禁用mpm_prefork和mpm_worker错误"
a2enmod mpm_event || error_exit "启用mpm_event错误"
sudo systemctl restart apache2 || error_exit "重启apache2错误"

##修改php.ini
sudo sed 's/^;\?\(memory_limit\).*/\1 = 512M/' -i /etc/php/${PHP_V}/fpm/php.ini || error_exit "修改php.ini错误"
sudo sed 's/^;\?\(output_buffering\).*/\1 = Off/' -i /etc/php/${PHP_V}/fpm/php.ini || error_exit "修改php.ini错误"
sudo sed 's/^;\?\(max_execution_time\).*/\1 = 0/' -i /etc/php/${PHP_V}/fpm/php.ini || error_exit "修改php.ini错误"
sudo sed 's/^;\?\(post_max_size\).*/\1 = 10240M/' -i /etc/php/${PHP_V}/fpm/php.ini || error_exit "修改php.ini错误"
sudo sed 's/^;\?\(upload_max_filesize\).*/\1 = 10240M/' -i /etc/php/${PHP_V}/fpm/php.ini || error_exit "修改php.ini错误"
sudo systemctl restart php${PHP_V}-fpm || error_exit "重启php-fpm错误"
sudo systemctl restart apache2 || error_exit "重启apache2错误"

##启用ssl和headers
sudo a2enmod ssl headers http2 rewrite || error_exit "启用apahce2 Module错误"
sudo systemctl restart apache2 || error_exit "重启apache2错误"

##开启重定向
sudo sed '/<Directory \/var\/www\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride all/' -i /etc/apache2/apache2.conf || error_exit "修改apache2.conf错误"
sudo systemctl restart apache2 || error_exit "重启apache2错误"

##安装数据库
sudo apt-get -qq install -y mysql-server || error_exit "安装mysql-server错误"
sudo mysql -uroot mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWD}';" || error_exit "设置mysql密码错误"

##下载nextcloud, 创建数据目录
cd /var/www
sudo wget -qO nextcloud.zip ${NC_DOWNLOAD_URL} || error_exit "获取nextcloud.zip错误"
sudo unzip -q nextcloud.zip || error_exit "解压nextcloud.zip错误"
sudo chown -R www-data nextcloud || error_exit "设置nextcloud目录权限错误"
sudo chmod -R 755 nextcloud || error_exit "设置nextcloud目录权限错误"
sudo mkdir ${NC_DATA_DIR} || error_exit "创建nextcloud数据目录错误"
sudo chown www-data.www-data ${NC_DATA_DIR} || error_exit "设置nextcloud数据目录权限错误"

if [ "$GETCERT" = "1" ]; then
	SSLDIR="/etc/ssl/website/${SERVERNAME}"
	if [ ! -d $SSLDIR  ];then
	  mkdir $SSLDIR || error_exit "创建证书目录错误"
	else
	  echo dir exist
	fi
	sudo curl  https://get.acme.sh | sh || error_exit "安装acme.sh错误"
	case $INTERNET in
		#公网服务器
		1) ~/.acme.sh/acme.sh --issue -d ${SERVERNAME} --apache || error_exit "获取证书错误";;
		#内网服务器
		2) ~/.acme.sh/acme.sh --issue -d ${SERVERNAME} --dns dns_ali || error_exit "获取证书错误";;
	esac
	~/.acme.sh/acme.sh --install-cert -d ${SERVERNAME} --cert-file ${SSLDIR}/certificate.crt --key-file ${SSLDIR}/private.key --fullchain-file ${SSLDIR}/ca_bundle.crt --reloadcmd "service apache2 force-reload" || error_exit "复制证书错误"
fi

##启用nextcloud虚拟主机
cat > /etc/apache2/sites-available/nextcloud-ssl.conf <<EOF
<IfModule mod_ssl.c>
	<VirtualHost *:443>
		Protocols h2 http/1.1
		ServerAdmin webmaster@localhost
		ServerName $SERVERNAME
		DocumentRoot /var/www/nextcloud
		<IfModule mod_headers.c>
		  Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
		</IfModule>
		ErrorLog \${APACHE_LOG_DIR}/error.log
		CustomLog \${APACHE_LOG_DIR}/access.log combined
		SSLEngine on
		SSLCertificateFile	/etc/ssl/website/certificate.crt
		SSLCertificateKeyFile /etc/ssl/website/private.key
		SSLCertificateChainFile /etc/ssl/website/ca_bundle.crt
		<FilesMatch "\.(cgi|shtml|phtml|php)$">
				SSLOptions +StdEnvVars
		</FilesMatch>
		<Directory /usr/lib/cgi-bin>
				SSLOptions +StdEnvVars
		</Directory>
	</VirtualHost>
</IfModule>
# vim: syntax=apache ts=4 sw=4 sts=4 sr noet
EOF

a2ensite nextcloud-ssl || error_exit "启用虚拟主机错误"
sudo systemctl restart apache2 || error_exit "重启apache2错误"

##安装redis内存缓存
sudo apt-get -qq install -y redis-server || error_exit "安装redis-server错误"
sudo usermod -a -G redis www-data || error_exit "将www-data添加到redis用户组错误"
sudo systemctl restart apache2 || error_exit "重启apache2错误"

##安装并进行配置
sudo -u www-data php /var/www/nextcloud/occ maintenance:install --database "mysql" --database-name "${NC_DBNAME}" --database-user "root" --database-pass "${MYSQL_ROOT_PASSWD}" --admin-user "${NC_ADMIN}" --admin-pass "${NC_ADMIN_PASSWD}" --data-dir "${NC_DATA_DIR}" || error_exit "安装nextcloud错误"
sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_domains 0 --value="${SERVERNAME}" || error_exit "设置trusted_domains错误"
sudo -u www-data php /var/www/nextcloud/occ config:system:set default_phone_region --value="CN" || error_exit "设置default_phone_region错误"
sudo -u www-data php /var/www/nextcloud/occ config:system:set memcache.locking --value="\OC\Memcache\Redis" || error_exit "设置memcache.locking错误"
sudo -u www-data php /var/www/nextcloud/occ config:system:set memcache.local --value="\OC\Memcache\APCu" || error_exit "设置memcache.local错误"

echo "nextcloud安装成功！地址：https://${SERVERNAME} 用户名：${NC_ADMIN}  密码：${NC_ADMIN_PASSWD}  数据库密码：${MYSQL_ROOT_PASSWD}。请尽快修改密码！"

echo "source <(kubectl completion zsh)" >> ~/.zshrc
