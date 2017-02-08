#!/bin/sh
set -e


GITLAB_VERSION=8.16.3
RUBY_VERSION=2.3
GITLAB_SHELL_VERSION=4.1.1
GITLAB_WORKHORSE_VERSION=1.3.0
GITLAB_USER="git"
GITLAB_HOME="/home/git"
GITLAB_LOG_DIR="/var/log/gitlab"
GITLAB_CACHE_DIR="/etc/docker-gitlab"
RAILS_ENV=production

GITLAB_INSTALL_DIR="${GITLAB_HOME}/gitlab"
GITLAB_SHELL_INSTALL_DIR="${GITLAB_HOME}/gitlab-shell"
GITLAB_WORKHORSE_INSTALL_DIR="${GITLAB_HOME}/gitlab-workhorse"
GITLAB_DATA_DIR="${GITLAB_HOME}/data"
GITLAB_BUILD_DIR="${GITLAB_CACHE_DIR}/build"
GITLAB_RUNTIME_DIR="${GITLAB_CACHE_DIR}/runtime"

echo " $(whoami) == ${GITLAB_USER}"
## Execute a command as GITLAB_USER
exec_as_git() {
  if [[ $(whoami) == ${GITLAB_USER} ]]; then
    $@
  else
    sudo -u ${GITLAB_USER} -H "$@"
    #sudo -HEu ${GITLAB_USER} "$@"
  fi
}


##https://gitlab.com/gitlab-org/gitlab-ce.git
GITLAB_CE_URL=https://gitlab.com/gitlab-org/gitlab-ce/repository/archive.tar.gz
GITLAB_SHELL_URL=https://gitlab.com/gitlab-org/gitlab-shell/repository/archive.tar.gz
GITLAB_WORKHORSE_URL=https://gitlab.com/gitlab-org/gitlab-workhorse/repository/archive.tar.gz
GEM_CACHE_DIR="${GITLAB_BUILD_DIR}/cache"


echo "Compiling assets. Please be patient, this could take a while..."
exec_as_git bundle exec rake assets:clean assets:precompile USE_DB=false SKIP_STORAGE_VALIDATION=true >/dev/null 2>&1

# remove auto generated ${GITLAB_DATA_DIR}/config/secrets.yml
rm -rf ${GITLAB_DATA_DIR}/config/secrets.yml

exec_as_git mkdir -p ${GITLAB_INSTALL_DIR}/tmp/pids/ ${GITLAB_INSTALL_DIR}/tmp/sockets/
chmod -R u+rwX ${GITLAB_INSTALL_DIR}/tmp

# symlink ${GITLAB_HOME}/.ssh -> ${GITLAB_LOG_DIR}/gitlab
rm -rf ${GITLAB_HOME}/.ssh
exec_as_git ln -sf ${GITLAB_DATA_DIR}/.ssh ${GITLAB_HOME}/.ssh

# symlink ${GITLAB_INSTALL_DIR}/log -> ${GITLAB_LOG_DIR}/gitlab
rm -rf ${GITLAB_INSTALL_DIR}/log
ln -sf ${GITLAB_LOG_DIR}/gitlab ${GITLAB_INSTALL_DIR}/log

# symlink ${GITLAB_INSTALL_DIR}/public/uploads -> ${GITLAB_DATA_DIR}/uploads
rm -rf ${GITLAB_INSTALL_DIR}/public/uploads
exec_as_git ln -sf ${GITLAB_DATA_DIR}/uploads ${GITLAB_INSTALL_DIR}/public/uploads

# symlink ${GITLAB_INSTALL_DIR}/.secret -> ${GITLAB_DATA_DIR}/.secret
rm -rf ${GITLAB_INSTALL_DIR}/.secret
exec_as_git ln -sf ${GITLAB_DATA_DIR}/.secret ${GITLAB_INSTALL_DIR}/.secret

# WORKAROUND for https://github.com/sameersbn/docker-gitlab/issues/509
rm -rf ${GITLAB_INSTALL_DIR}/builds
rm -rf ${GITLAB_INSTALL_DIR}/shared

# install gitlab bootscript, to silence gitlab:check warnings
cp ${GITLAB_INSTALL_DIR}/lib/support/init.d/gitlab /etc/init.d/gitlab
chmod +x /etc/init.d/gitlab

# disable default nginx configuration and enable gitlab's nginx configuration
rm -rf /etc/nginx/sites-enabled/default

# configure sshd
sed -i \
  -e "s|^[#]*UsePAM yes|UsePAM no|" \
  -e "s|^[#]*UsePrivilegeSeparation yes|UsePrivilegeSeparation no|" \
  -e "s|^[#]*PasswordAuthentication yes|PasswordAuthentication no|" \
  -e "s|^[#]*LogLevel INFO|LogLevel VERBOSE|" \
  /etc/ssh/sshd_config
echo "UseDNS no" >> /etc/ssh/sshd_config

# move supervisord.log file to ${GITLAB_LOG_DIR}/supervisor/
sed -i "s|^[#]*logfile=.*|logfile=${GITLAB_LOG_DIR}/supervisor/supervisord.log ;|" /etc/supervisor/supervisord.conf

# move nginx logs to ${GITLAB_LOG_DIR}/nginx
sed -i \
  -e "s|access_log /var/log/nginx/access.log;|access_log ${GITLAB_LOG_DIR}/nginx/access.log;|" \
  -e "s|error_log /var/log/nginx/error.log;|error_log ${GITLAB_LOG_DIR}/nginx/error.log;|" \
  /etc/nginx/nginx.conf

mkdir -p /etc/logrotate.d

# configure supervisord log rotation
cat > /etc/logrotate.d/supervisord <<EOF
${GITLAB_LOG_DIR}/supervisor/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure gitlab log rotation
cat > /etc/logrotate.d/gitlab <<EOF
${GITLAB_LOG_DIR}/gitlab/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure gitlab-shell log rotation
cat > /etc/logrotate.d/gitlab-shell <<EOF
${GITLAB_LOG_DIR}/gitlab-shell/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure gitlab vhost log rotation
cat > /etc/logrotate.d/gitlab-nginx <<EOF
${GITLAB_LOG_DIR}/nginx/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

mkdir -p /etc/supervisor.d

# configure supervisord to start unicorn
cat > /etc/supervisor.d/unicorn.conf <<EOF
[program:unicorn]
priority=10
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=bundle exec unicorn_rails -c ${GITLAB_INSTALL_DIR}/config/unicorn.rb -E ${RAILS_ENV}
user=git
autostart=true
autorestart=true
stopsignal=QUIT
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start sidekiq
cat > /etc/supervisor.d/sidekiq.conf <<EOF
[program:sidekiq]
priority=10
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=bundle exec sidekiq -c {{SIDEKIQ_CONCURRENCY}}
  -C ${GITLAB_INSTALL_DIR}/config/sidekiq_queues.yml
  -e ${RAILS_ENV}
  -t {{SIDEKIQ_SHUTDOWN_TIMEOUT}}
  -P ${GITLAB_INSTALL_DIR}/tmp/pids/sidekiq.pid
  -L ${GITLAB_INSTALL_DIR}/log/sidekiq.log
user=git
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start gitlab-workhorse
cat > /etc/supervisor.d/gitlab-workhorse.conf <<EOF
[program:gitlab-workhorse]
priority=20
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=/usr/local/bin/gitlab-workhorse
  -listenUmask 0
  -listenNetwork tcp
  -listenAddr ":8181"
  -authBackend http://127.0.0.1:8080{{GITLAB_RELATIVE_URL_ROOT}}
  -authSocket ${GITLAB_INSTALL_DIR}/tmp/sockets/gitlab.socket
  -documentRoot ${GITLAB_INSTALL_DIR}/public
  -proxyHeadersTimeout {{GITLAB_WORKHORSE_TIMEOUT}}
user=git
autostart=true
autorestart=true
stdout_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
stderr_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
EOF

# configure supervisord to start mail_room
cat > /etc/supervisor.d/mail_room.conf <<EOF
[program:mail_room]
priority=20
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=bundle exec mail_room -c ${GITLAB_INSTALL_DIR}/config/mail_room.yml
user=git
autostart={{GITLAB_INCOMING_EMAIL_ENABLED}}
autorestart=true
stdout_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
stderr_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
EOF

# configure supervisor to start sshd
mkdir -p /var/run/sshd
cat > /etc/supervisor.d/sshd.conf <<EOF
[program:sshd]
directory=/
command=/usr/sbin/sshd -D -E ${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
user=root
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start nginx
cat > /etc/supervisor.d/nginx.conf <<EOF
[program:nginx]
priority=20
directory=/tmp
command=/usr/sbin/nginx -g "daemon off;"
user=root
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start crond
cat > /etc/supervisor.d/cron.conf <<EOF
[program:cron]
priority=20
directory=/tmp
command=/usr/sbin/cron -f
user=root
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# purge build dependencies and cleanup apt
###DEBIAN_FRONTEND=noninteractive apt-get purge -y --auto-remove ${BUILD_DEPENDENCIES}
###rm -rf /var/lib/apt/lists/*

cp -r /data/docker-gitlab/assets/runtime/ ${GITLAB_RUNTIME_DIR}/
cp entrypoint.sh /sbin/entrypoint.sh
chmod 755 /sbin/entrypoint.sh
rm -rf /var/cache/apk/*