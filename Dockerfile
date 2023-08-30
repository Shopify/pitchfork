FROM mcr.microsoft.com/devcontainers/ruby:1-3.2-bookworm
RUN apt-get update -y && apt-get install -y ragel socat netcat-traditional smem apache2-utils
WORKDIR /app
CMD [ "bash" ]
