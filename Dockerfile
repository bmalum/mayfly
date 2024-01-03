FROM amazonlinux:2023 as substrate

RUN yum install -y openssl openssl-devel ncurses ncurses-devel wget git tar && yum -y groupinstall "Development Tools" && \
    wget https://github.com/erlang/otp/releases/download/OTP-26.1.2/otp_src_26.1.2.tar.gz && tar -zxf otp_src_26.1.2.tar.gz && \
    cd otp_src_26.1.2 && ERL_TOP=`pwd` ./configure && LANG=C make && make install && \
    cd && wget https://github.com/elixir-lang/elixir/archive/v1.15.7.zip && \
    unzip v1.15.7.zip && cd elixir-1.15.7 && make clean compile && make install 
    # && \
    # yum groupremove -y "Development Tools" && \
    # yum remove -y openssl openssl-devel ncurses ncurses-devel wget git tar && \
    # cd && rm -rf * 

FROM amazonlinux:2023
COPY --from=substrate /usr/local /usr/local
