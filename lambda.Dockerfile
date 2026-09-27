# Build image for `mix lambda.build --docker` and source of the Mayfly ERTS layer.
#
# Amazon Linux 2023 matches the Lambda `provided.al2023` runtime, so the ERTS
# links against the same glibc. No prebuilt OTP for AL2023 exists (hexpm/bob
# and hexpm/elixir only cover Debian/Ubuntu/Alpine), so OTP is compiled once
# and cached per project. Elixir is installed from the official precompiled
# archive.
#
# Targets:
#   build  (default) – full toolchain: `docker build -t mayfly-build .`
#   layer            – /opt/erlang only, used by layer/build.sh
#
# `mix lambda.build --docker --arch x86_64|arm64` passes --platform; keep this
# file architecture-neutral. Override by placing a `lambda.Dockerfile` in your
# own project root.
ARG AL_TAG=2023
FROM amazonlinux:${AL_TAG} AS otp

ARG OTP_VERSION=27.3.4
# Lambda's provided.al2023 image ships libcrypto.so.3 / libssl.so.3 and
# ncurses, so OpenSSL is linked dynamically (AL2023 has no static libcrypto;
# --disable-dynamic-ssl-lib would silently drop the crypto application).
RUN set -eux; \
    dnf install -y openssl openssl-devel ncurses ncurses-devel tar gzip \
      gcc gcc-c++ make automake autoconf; \
    curl -fsSL -o /tmp/otp.tar.gz \
      "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz"; \
    mkdir -p /tmp/otp && tar -xzf /tmp/otp.tar.gz -C /tmp/otp --strip-components=1; \
    cd /tmp/otp; \
    ./configure --prefix=/opt/erlang \
      --without-javac --without-wx --without-debugger --without-observer \
      --without-et --without-megaco --without-odbc --without-jinterface \
      --without-diameter --without-eldap --without-ftp --without-tftp \
      --without-snmp; \
    make -j"$(nproc)"; \
    make install; \
    # Fail loudly if crypto did not build (missing OpenSSL headers).
    /opt/erlang/bin/erl -noshell -eval 'ok = application:ensure_started(crypto), halt().'; \
    # Trim what a Lambda function never needs.
    rm -rf /opt/erlang/lib/erlang/lib/*/src /opt/erlang/lib/erlang/lib/*/examples \
           /opt/erlang/lib/erlang/lib/*/doc /opt/erlang/lib/erlang/man \
           /opt/erlang/lib/erlang/misc; \
    find /opt/erlang -name "*.a" -delete; \
    rm -rf /tmp/otp /tmp/otp.tar.gz

# ---------------------------------------------------------------------------
FROM amazonlinux:${AL_TAG} AS layer
COPY --from=otp /opt/erlang /opt/erlang
# The layer zip is created from /opt by layer/build.sh.

# ---------------------------------------------------------------------------
FROM amazonlinux:${AL_TAG} AS build

ARG ELIXIR_VERSION=1.18.4
ARG ELIXIR_OTP_MAJOR=27
COPY --from=otp /opt/erlang /opt/erlang

RUN set -eux; \
    dnf install -y git unzip tar gzip gcc gcc-c++ make openssl ncurses; \
    curl -fsSL -o /tmp/elixir.zip \
      "https://builds.hex.pm/builds/elixir/v${ELIXIR_VERSION}-otp-${ELIXIR_OTP_MAJOR}.zip"; \
    mkdir -p /opt/elixir && unzip -q /tmp/elixir.zip -d /opt/elixir; \
    rm -f /tmp/elixir.zip; \
    dnf clean all; rm -rf /var/cache/dnf

ENV PATH="/opt/elixir/bin:/opt/erlang/bin:${PATH}" \
    LANG=C.UTF-8 \
    MIX_ENV=prod

RUN mix local.rebar --force && mix local.hex --force

WORKDIR /mnt/code
