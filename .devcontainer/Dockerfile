# syntax=docker/dockerfile:1
FROM hexpm/elixir:1.18.1-erlang-27.2-debian-bookworm-20241016

ARG USER=vscode
ARG UID=1000
ARG GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates locales sudo build-essential inotify-tools \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && groupadd -g ${GID} ${USER} \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USER} \
    && echo "${USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER ${USER}
WORKDIR /workspaces/tau

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ELIXIR_ERL_OPTIONS="+fnu"
