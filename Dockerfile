FROM ruby:3.2
RUN apt-get update -y && apt-get install -y ragel socat netcat-traditional smem apache2-utils
WORKDIR /app
CMD [ "bash" ]
