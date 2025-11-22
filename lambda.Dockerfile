FROM amazonlinux:2023

# Install dependencies and build Erlang/Elixir
RUN yum install -y \
    openssl openssl-devel \
    ncurses ncurses-devel \
    wget git tar unzip \
    gcc gcc-c++ make automake autoconf && \
    # Build Erlang with optimizations for Lambda
    wget https://github.com/erlang/otp/releases/download/OTP-27.2/otp_src_27.2.tar.gz && \
    tar -zxf otp_src_27.2.tar.gz && \
    cd otp_src_27.2 && \
    ./configure \
        --without-javac \
        --without-wx \
        --without-debugger \
        --without-observer \
        --without-et && \
    make -j$(nproc) && \
    make install && \
    # Build Elixir
    cd / && \
    wget https://github.com/elixir-lang/elixir/archive/v1.19.3.tar.gz && \
    tar -zxf v1.19.3.tar.gz && \
    cd elixir-1.19.3 && \
    make clean compile && \
    make install && \
    # Cleanup to reduce image size
    cd / && \
    rm -rf otp_src_27.2* elixir-1.19.3* v1.19.3.tar.gz && \
    yum clean all && \
    rm -rf /var/cache/yum

# Set up environment for building Lambda packages
ENV MIX_ENV=lambda
WORKDIR /mnt/code

# Install Mix dependencies (separate layer for better caching)
RUN mix local.rebar --force && \
    mix local.hex --force
