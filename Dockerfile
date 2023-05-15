FROM alpine:3.17 AS build-env
ARG V
RUN apk update && \
    apk upgrade && \
    apk --no-cache add \
        build-base \
        patch \
        wget \
        openssl-dev \
        openssl \
        perl-dev \
        zlib-dev
COPY logsender-${V}.tar.gz /
RUN tar -xzf logsender-${V}.tar.gz && \
    cd logsender-${V} && \
    ./configure --prefix=/app && \
    make
RUN cd logsender-${V} && \
    make install

FROM alpine:3.17
RUN apk update && \
    apk upgrade && \
    apk --no-cache add \
    perl \
    openssh-client \
    curl \
    openssl
EXPOSE 3000/tcp
COPY --from=build-env /app /app
RUN perl -c /app/bin/logsender.pl
ENV MOJO_LOG_LEVEL=trace
ENV MOJO_MODE=production
ENV MOJO_CLIENT_DEBUG=0
ENV MOJO_SERVER_DEBUG=0
ENTRYPOINT ["/app/bin/logsender.pl"]
