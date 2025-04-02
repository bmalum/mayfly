FROM amazonlinux:2023-minimal

# Install dependencies and build Erlang/Elixir in a single layer
RUN yum install -y openssl openssl-devel ncurses ncurses-devel wget git tar unzip && \
    yum -y groupinstall "Development Tools" && \
    # Build Erlang
    wget https://github.com/erlang/otp/releases/download/OTP-26.1.2/otp_src_26.1.2.tar.gz && \
    tar -zxf otp_src_26.1.2.tar.gz && \
    cd otp_src_26.1.2 && ERL_TOP=`pwd` ./configure && LANG=C make && make install && \
    # Build Elixir
    cd && wget https://github.com/elixir-lang/elixir/archive/v1.15.7.zip && \
    unzip v1.15.7.zip && cd elixir-1.15.7 && make clean compile && make install && \
    # Cleanup to reduce image size (optional, can be commented out if build speed is more important)
    cd && rm -rf otp_src_26.1.2* elixir-1.15.7* v1.15.7.zip && \
    yum clean all

# Set up environment for building Lambda packages
ENV MIX_ENV lambda
RUN mkdir /mnt/code
RUN mix local.rebar --force && \
    mix local.hex --force
WORKDIR /mnt/code
