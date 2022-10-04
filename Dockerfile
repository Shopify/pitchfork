FROM ruby:3.1
RUN apt-get update -y && apt-get install -y ragel socat netcat smem
WORKDIR /app
CMD [ "bash" ]
