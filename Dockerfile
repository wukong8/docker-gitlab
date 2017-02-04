FROM alpine
MAINTAINER sameer@damagehead.com

ENV GITLAB_VERSION=8.16.3 \
    RUBY_VERSION=2.3 \
    GOLANG_VERSION=1.6.3 \
    GITLAB_SHELL_VERSION=4.1.1 \
    GITLAB_WORKHORSE_VERSION=1.3.0 \
    GITLAB_USER="git" \
    GITLAB_HOME="/home/git" \
    GITLAB_LOG_DIR="/var/log/gitlab" \
    GITLAB_CACHE_DIR="/etc/docker-gitlab" \
    RAILS_ENV=production

ENV GITLAB_INSTALL_DIR="${GITLAB_HOME}/gitlab" \
    GITLAB_SHELL_INSTALL_DIR="${GITLAB_HOME}/gitlab-shell" \
    GITLAB_WORKHORSE_INSTALL_DIR="${GITLAB_HOME}/gitlab-workhorse" \
    GITLAB_DATA_DIR="${GITLAB_HOME}/data" \
    GITLAB_BUILD_DIR="${GITLAB_CACHE_DIR}/build" \
    GITLAB_RUNTIME_DIR="${GITLAB_CACHE_DIR}/runtime"

RUN sed -i '1i\http://mirrors.ustc.edu.cn/alpine/v3.5/main\nhttp://mirrors.ustc.edu.cn/alpine/v3.5/community' /etc/apk/repositories \
&& apk update \
&& apk add --no-cache --virtual .build-deps "wget curl gcc g++ make patch cmake linux-headers \
                                              tzdata python2 supervisor git gettext go nodejs autoconf bison coreutils procps sudo \
                                              yaml-dev gdbm-dev zlib-dev readline-dev libc-dev ncurses-dev libffi-dev libxml2-dev \
                                              libxslt-dev icu-dev maridb-dev ruby-dev ruby-irb ruby-bundler ruby-bigdecimal" \

&& gem sources --add https://gems.ruby-china.org/ --remove https://rubygems.org/ \
&& gem update --system \
&& gem install --no-document bundler
COPY assets/build/ ${GITLAB_BUILD_DIR}/
RUN bash ${GITLAB_BUILD_DIR}/install.sh

COPY assets/runtime/ ${GITLAB_RUNTIME_DIR}/
COPY entrypoint.sh /sbin/entrypoint.sh
RUN chmod 755 /sbin/entrypoint.sh

EXPOSE 22/tcp 80/tcp 443/tcp

VOLUME ["${GITLAB_DATA_DIR}", "${GITLAB_LOG_DIR}"]
WORKDIR ${GITLAB_INSTALL_DIR}
ENTRYPOINT ["/sbin/entrypoint.sh"]
CMD ["app:start"]
