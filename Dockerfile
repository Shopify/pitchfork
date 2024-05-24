FROM mcr.microsoft.com/devcontainers/ruby:3.3-bookworm
RUN apt-get update -y && apt-get install -y ragel socat netcat-traditional smem apache2-utils
WORKDIR /app
CMD [ "bash" ]
